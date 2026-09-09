defmodule PromptOn.Accounts.InvitationTest do
  use PromptOn.DataCase, async: false

  alias PromptOn.Accounts
  alias PromptOn.Accounts.Invitation
  alias PromptOn.Fixtures
  alias PromptOn.Projects.ProjectMembership
  alias PromptOnWeb.ErrorText

  require Ash.Query

  defp invite(actor, attrs) do
    Invitation
    |> Ash.Changeset.for_create(:invite, attrs, actor: actor)
    |> Ash.create()
  end

  defp preview(actor, token) do
    Invitation
    |> Ash.ActionInput.for_action(:preview, %{token: token}, actor: actor)
    |> Ash.run_action()
  end

  defp accept(actor, token) do
    Invitation
    |> Ash.ActionInput.for_action(:accept, %{token: token}, actor: actor)
    |> Ash.run_action()
  end

  defp team_context do
    owner = Fixtures.user_fixture()
    Fixtures.set_plan(Fixtures.organization_for(owner), :team)

    {:ok, organization} =
      Accounts.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    project = project_fixture(owner, organization)
    %{owner: owner, organization: organization, project: project}
  end

  defp project_fixture(user, organization) do
    now = DateTime.utc_now()
    n = System.unique_integer([:positive])
    slug = "project-#{n}"

    {1, [%{id: project_id}]} =
      PromptOn.Repo.insert_all(
        "projects",
        [
          %{
            organization_id: Ecto.UUID.dump!(organization.id),
            creator_id: Ecto.UUID.dump!(user.id),
            name: "Project #{n}",
            slug: slug,
            timezone: "Etc/UTC",
            payload_policy:
              PromptOn.Observability.PayloadPolicy.to_map(
                PromptOn.Observability.PayloadPolicy.default()
              ),
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    {1, _rows} =
      PromptOn.Repo.insert_all("project_memberships", [
        %{
          project_id: project_id,
          user_id: Ecto.UUID.dump!(user.id),
          inserted_at: now,
          updated_at: now
        }
      ])

    Ash.get!(PromptOn.Projects.Project, Ecto.UUID.load!(project_id),
      actor: Fixtures.system_actor()
    )
  end

  defp invitation_attrs(organization, invited, role, project_ids) do
    %{
      organization_id: organization.id,
      email: invited.email,
      role: role,
      project_ids: project_ids
    }
  end

  test "invite stores only a token hash and sends the raw token in the trusted-origin email" do
    %{owner: owner, organization: organization, project: project} = team_context()
    invited = Fixtures.user_fixture(%{email: "Invited.User@example.com"})

    assert {:ok, invitation} =
             invite(owner, invitation_attrs(organization, invited, :member, [project.id]))

    token = Ash.Resource.get_metadata(invitation, :token)
    assert is_binary(token)
    assert String.length(token) > 32

    assert_receive {:email, %Swoosh.Email{text_body: text, html_body: html}}, 500
    assert text =~ "/invitations/#{token}"
    assert html =~ "/invitations/#{token}"
    assert text =~ PromptOnWeb.Endpoint.url()

    reloaded = Ash.get!(Invitation, invitation.id, actor: Fixtures.system_actor())
    assert reloaded.token_hash == Invitation.hash(token)
    refute reloaded.token_hash == token
    refute Ash.Resource.get_metadata(reloaded, :token)
  end

  test "preview returns organization and project summaries only for the invited email" do
    %{owner: owner, organization: organization, project: project} = team_context()
    invited = Fixtures.user_fixture(%{email: "invitee@example.com"})
    stranger = Fixtures.user_fixture()

    {:ok, invitation} =
      invite(owner, invitation_attrs(organization, invited, :member, [project.id]))

    token = Ash.Resource.get_metadata(invitation, :token)

    assert {:ok, preview} = preview(%{invited | email: "INVITEE@example.com"}, token)
    assert preview.organization.id == organization.id

    assert Ash.Resource.get_metadata(preview, :projects) == [
             %{id: project.id, name: project.name, slug: project.slug}
           ]

    assert {:error, error} = preview(stranger, token)
    assert ErrorText.message(error) =~ "email: does not match this invitation"
  end

  test "accept creates membership and selected project grants only after Join" do
    %{owner: owner, organization: organization, project: project} = team_context()
    invited = Fixtures.user_fixture()

    {:ok, invitation} =
      invite(owner, invitation_attrs(organization, invited, :member, [project.id]))

    token = Ash.Resource.get_metadata(invitation, :token)

    assert {:ok, []} = memberships(organization, invited)

    assert {:ok, accepted} = accept(invited, token)
    assert accepted.accepted_by_id == invited.id
    assert accepted.accepted_at

    assert {:ok, [%{role: :member}]} = memberships(organization, invited)
    assert project_granted?(project.id, invited.id)
  end

  test "accept is single-use and revoked or expired invitations are rejected" do
    %{owner: owner, organization: organization, project: project} = team_context()
    invited = Fixtures.user_fixture()

    {:ok, invitation} =
      invite(owner, invitation_attrs(organization, invited, :member, [project.id]))

    token = Ash.Resource.get_metadata(invitation, :token)
    assert {:ok, _accepted} = accept(invited, token)
    assert {:error, replay_error} = accept(invited, token)
    assert ErrorText.message(replay_error) =~ "token: is expired, revoked, or already used"

    {:ok, revoked} = invite(owner, invitation_attrs(organization, invited, :member, [project.id]))
    revoked_token = Ash.Resource.get_metadata(revoked, :token)

    assert {:ok, _revoked} =
             Ash.update(Ash.Changeset.for_update(revoked, :revoke, %{}, actor: owner))

    assert {:error, revoked_error} = accept(invited, revoked_token)
    assert ErrorText.message(revoked_error) =~ "token: is expired, revoked, or already used"

    other = Fixtures.user_fixture()
    {:ok, expired} = invite(owner, invitation_attrs(organization, other, :member, [project.id]))
    expired_token = Ash.Resource.get_metadata(expired, :token)
    expire!(expired)
    assert {:error, expired_error} = accept(other, expired_token)
    assert ErrorText.message(expired_error) =~ "token: is expired, revoked, or already used"
  end

  test "concurrent accepts only allow one Join to win" do
    %{owner: owner, organization: organization, project: project} = team_context()
    invited = Fixtures.user_fixture()

    {:ok, invitation} =
      invite(owner, invitation_attrs(organization, invited, :member, [project.id]))

    token = Ash.Resource.get_metadata(invitation, :token)

    results =
      [Task.async(fn -> accept(invited, token) end), Task.async(fn -> accept(invited, token) end)]
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert {:ok, [%{role: :member}]} = memberships(organization, invited)
    assert project_granted?(project.id, invited.id)
  end

  test "personal organization invites are rejected with the team conversion hint" do
    owner = Fixtures.user_fixture()
    personal = Fixtures.organization_for(owner)
    invited = Fixtures.user_fixture()

    assert {:error, error} = invite(owner, invitation_attrs(personal, invited, :member, []))

    assert ErrorText.message(error) ==
             "organization_id: personal organizations cannot invite members. " <>
               "Convert it to a team organization first."
  end

  test "a member can invite members only to projects they created" do
    %{organization: organization, project: owner_project} = team_context()
    member = Fixtures.user_fixture()

    assert {:ok, _membership} =
             Accounts.add_member(
               %{organization_id: organization.id, user_id: member.id, role: :member},
               actor: Fixtures.system_actor()
             )

    member_project = project_fixture(member, organization)
    invited = Fixtures.user_fixture()

    assert {:ok, _invitation} =
             invite(member, invitation_attrs(organization, invited, :member, [member_project.id]))

    assert {:error, admin_error} =
             invite(member, invitation_attrs(organization, invited, :admin, [member_project.id]))

    assert ErrorText.message(admin_error) =~ "role: cannot be invited by this user"

    assert {:error, project_error} =
             invite(member, invitation_attrs(organization, invited, :member, [owner_project.id]))

    assert ErrorText.message(project_error) =~
             "project_ids: must include only projects created by this member"
  end

  test "a project creator cannot invite after their own project access is revoked" do
    %{owner: owner, organization: organization} = team_context()
    member = Fixtures.user_fixture()

    assert {:ok, _membership} =
             Accounts.add_member(
               %{organization_id: organization.id, user_id: member.id, role: :member},
               actor: Fixtures.system_actor()
             )

    project = project_fixture(member, organization)
    invited = Fixtures.user_fixture()

    assert [%{id: project_id}] = Accounts.Permissions.invitable_projects(member, organization.id)
    assert project_id == project.id

    grant =
      ProjectMembership
      |> Ash.Query.filter(project_id == ^project.id and user_id == ^member.id)
      |> Ash.read_one!(actor: Fixtures.system_actor())

    assert :ok = Ash.destroy(grant, action: :revoke, actor: owner)
    assert [] = Accounts.Permissions.invitable_projects(member, organization.id)

    assert {:error, error} =
             invite(member, invitation_attrs(organization, invited, :member, [project.id]))

    assert ErrorText.message(error) =~
             "project_ids: must include only projects created by this member"
  end

  test "accept re-checks inviter permissions and keeps an existing member role unchanged" do
    %{owner: owner, organization: organization, project: project} = team_context()
    admin = Fixtures.user_fixture()
    invited = Fixtures.user_fixture()

    assert {:ok, admin_membership} =
             Accounts.add_member(
               %{organization_id: organization.id, user_id: admin.id, role: :admin},
               actor: Fixtures.system_actor()
             )

    assert {:ok, invitation} =
             invite(admin, invitation_attrs(organization, invited, :admin, [project.id]))

    token = Ash.Resource.get_metadata(invitation, :token)

    assert {:ok, _demoted} =
             Ash.update(
               Ash.Changeset.for_update(admin_membership, :change_role, %{role: :member},
                 actor: owner
               )
             )

    assert {:error, error} = accept(invited, token)
    assert ErrorText.message(error) =~ "role: cannot be invited by this user"

    existing = Fixtures.user_fixture()

    assert {:ok, _membership} =
             Accounts.add_member(
               %{organization_id: organization.id, user_id: existing.id, role: :member},
               actor: Fixtures.system_actor()
             )

    assert {:ok, existing_invitation} =
             invite(owner, invitation_attrs(organization, existing, :admin, [project.id]))

    existing_token = Ash.Resource.get_metadata(existing_invitation, :token)
    assert {:ok, _accepted} = accept(existing, existing_token)
    assert {:ok, [%{role: :member}]} = memberships(organization, existing)
    assert project_granted?(project.id, existing.id)
  end

  test "revoke re-checks the current row and actor permissions" do
    %{owner: owner, organization: organization, project: project} = team_context()
    invited = Fixtures.user_fixture()

    {:ok, invitation} =
      invite(owner, invitation_attrs(organization, invited, :member, [project.id]))

    token = Ash.Resource.get_metadata(invitation, :token)
    assert {:ok, _accepted} = accept(invited, token)

    assert {:error, stale_error} =
             Ash.update(Ash.Changeset.for_update(invitation, :revoke, %{}, actor: owner))

    assert ErrorText.message(stale_error) =~ "revoked_at: invitation is no longer pending"

    member = Fixtures.user_fixture()

    assert {:ok, member_membership} =
             Accounts.add_member(
               %{organization_id: organization.id, user_id: member.id, role: :member},
               actor: Fixtures.system_actor()
             )

    member_project = project_fixture(member, organization)
    other = Fixtures.user_fixture()

    {:ok, member_invitation} =
      invite(member, invitation_attrs(organization, other, :member, [member_project.id]))

    assert :ok =
             Ash.destroy(Ash.Changeset.for_destroy(member_membership, :remove, %{}, actor: owner))

    assert {:error, removed_error} =
             Ash.update(Ash.Changeset.for_update(member_invitation, :revoke, %{}, actor: member))

    assert ErrorText.message(removed_error) =~ "organization_id: is not accessible"
  end

  test "concurrent accept and revoke leave one meaningful outcome" do
    %{owner: owner, organization: organization, project: project} = team_context()
    invited = Fixtures.user_fixture()

    {:ok, invitation} =
      invite(owner, invitation_attrs(organization, invited, :member, [project.id]))

    token = Ash.Resource.get_metadata(invitation, :token)

    accept_task = Task.async(fn -> accept(invited, token) end)

    revoke_task =
      Task.async(fn ->
        Ash.update(Ash.Changeset.for_update(invitation, :revoke, %{}, actor: owner))
      end)

    results = [Task.await(accept_task), Task.await(revoke_task)]
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1

    reloaded = Ash.get!(Invitation, invitation.id, actor: Fixtures.system_actor())

    assert (is_nil(reloaded.accepted_at) && reloaded.revoked_at) ||
             (reloaded.accepted_at && is_nil(reloaded.revoked_at))
  end

  defp memberships(organization, user) do
    with {:ok, memberships} <- Accounts.list_memberships(actor: Fixtures.system_actor()) do
      {:ok,
       Enum.filter(
         memberships,
         &(&1.organization_id == organization.id and &1.user_id == user.id)
       )}
    end
  end

  defp project_granted?(project_id, user_id) do
    ProjectMembership
    |> Ash.Query.filter(project_id == ^project_id and user_id == ^user_id)
    |> Ash.exists?(actor: Fixtures.system_actor())
  end

  defp expire!(invitation) do
    Repo.update_all(
      from(i in "invitations", where: i.id == type(^invitation.id, :binary_id)),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end
end
