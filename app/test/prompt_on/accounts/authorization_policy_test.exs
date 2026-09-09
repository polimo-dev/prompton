defmodule PromptOn.Accounts.AuthorizationPolicyTest do
  use PromptOn.DataCase, async: false

  import PromptOn.Fixtures

  alias PromptOn.Accounts
  alias PromptOn.Accounts.{Membership, Permissions}
  alias PromptOn.Projects

  require Ash.Query

  describe "project access" do
    test "members access only assigned projects and stale grants do not survive organization removal" do
      %{owner: owner, org: org, member: member} = team_with_member()
      project = project_fixture(%{user: owner, organization: org})

      assert {:ok, []} = Projects.list_projects(actor: member)

      assert {:ok, _grant} =
               Projects.grant_project_membership(%{project_id: project.id, user_id: member.id},
                 actor: owner
               )

      assert {:ok, [%{id: project_id}]} = Projects.list_projects(actor: member)
      assert project_id == project.id

      membership = membership!(org, member)
      assert :ok = Ash.destroy(membership, action: :remove, actor: owner)

      assert {:ok, []} = Projects.list_projects(actor: member)
      assert {:ok, []} = project_memberships_for(member, owner)
    end

    test "project creators receive access automatically and may grant their own project" do
      %{owner: owner, org: org, member: member} = team_with_member()
      teammate = add_member!(org, :member)
      owner_project = project_fixture(%{user: owner, organization: org})

      assert {:ok, created} =
               Projects.create_project(
                 %{organization_id: org.id, name: "Member App", slug: "member-app"},
                 actor: member
               )

      assert created.creator_id == member.id

      assert {:ok, [%{id: created_id}]} = Projects.list_projects(actor: member)
      assert created_id == created.id

      assert {:ok, _grant} =
               Projects.grant_project_membership(%{project_id: created.id, user_id: teammate.id},
                 actor: member
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Projects.grant_project_membership(
                 %{project_id: owner_project.id, user_id: teammate.id},
                 actor: member
               )
    end

    test "project creators cannot grant after their own project access is revoked" do
      %{owner: owner, org: org, member: member} = team_with_member()
      teammate = add_member!(org, :member)

      project =
        project_fixture(%{
          user: member,
          organization: org,
          slug: "revoked-creator-grant"
        })

      assert {:ok, [grant]} = project_memberships_for(member, owner)
      assert grant.project_id == project.id
      assert :ok = Ash.destroy(grant, action: :revoke, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Projects.grant_project_membership(
                 %{project_id: project.id, user_id: teammate.id},
                 actor: member
               )
    end

    test "members cannot archive assigned projects but admins can archive any project" do
      %{org: org, member: member} = team_with_member()
      admin = add_member!(org, :admin)
      project = project_fixture(%{user: admin, organization: org})

      assert {:ok, _grant} =
               Projects.grant_project_membership(%{project_id: project.id, user_id: member.id},
                 actor: admin
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Projects.archive_project(project, actor: member)

      assert {:ok, archived} = Projects.archive_project(project, actor: admin)
      assert %DateTime{} = archived.archived_at
    end

    test "project grants reject users from another organization" do
      %{owner: owner, org: org} = team_with_member()
      other_user = user_fixture()
      project = project_fixture(%{user: owner, organization: org})

      assert {:error, %Ash.Error.Invalid{}} =
               Projects.grant_project_membership(
                 %{project_id: project.id, user_id: other_user.id},
                 actor: owner
               )
    end

    test "project assignment is idempotent and keeps retained grants" do
      %{owner: owner, org: org, member: member} = team_with_member()
      first = project_fixture(%{user: owner, organization: org, slug: "first-retained"})
      second = project_fixture(%{user: owner, organization: org, slug: "second-retained"})
      membership = membership!(org, member)

      assert {:ok, _updated} =
               membership
               |> Ash.Changeset.for_update(:assign_projects, %{project_ids: [first.id]},
                 actor: owner
               )
               |> Ash.update()

      assert {:ok, _updated} =
               membership
               |> Ash.Changeset.for_update(:assign_projects, %{project_ids: [first.id]},
                 actor: owner
               )
               |> Ash.update()

      assert {:ok, first_grants} = project_memberships_for(member, owner)
      assert Enum.map(first_grants, & &1.project_id) == [first.id]

      assert {:ok, _updated} =
               membership
               |> Ash.Changeset.for_update(
                 :assign_projects,
                 %{project_ids: [first.id, second.id]},
                 actor: owner
               )
               |> Ash.update()

      assert {:ok, grants} = project_memberships_for(member, owner)

      assert grants |> Enum.map(& &1.project_id) |> Enum.sort() ==
               Enum.sort([first.id, second.id])
    end
  end

  describe "organization roles" do
    test "permissions helper normalizes legacy editor and viewer rows to member" do
      %{org: org} = team_with_member()
      editor = add_member!(org, :editor)
      viewer = add_member!(org, :viewer)

      assert Permissions.role(editor, org.id) == :member
      assert Permissions.role(viewer, org.id) == :member
      refute Permissions.manage?(editor, org.id)
      refute Permissions.owner?(viewer, org.id)
    end

    test "public membership writes reject legacy and forged owner role changes" do
      %{owner: owner, org: org, member: member} = team_with_member()

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.add_member(
                 %{organization_id: org.id, user_id: user_fixture().id, role: :editor},
                 actor: PromptOn.SystemActor.new()
               )

      assert {:error, %Ash.Error.Invalid{}} =
               membership!(org, member)
               |> Ash.Changeset.for_update(:change_role, %{role: :owner}, actor: owner)
               |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} =
               membership!(org, owner)
               |> Ash.Changeset.for_update(:change_role, %{role: :member}, actor: owner)
               |> Ash.update()
    end

    test "admins can promote members but cannot demote or remove another admin" do
      %{org: org, member: member} = team_with_member()
      admin = add_member!(org, :admin)
      other_admin = add_member!(org, :admin)

      assert {:ok, promoted} =
               membership!(org, member)
               |> Ash.Changeset.for_update(:change_role, %{role: :admin}, actor: admin)
               |> Ash.update()

      assert promoted.role == :admin

      assert {:error, %Ash.Error.Forbidden{}} =
               membership!(org, other_admin)
               |> Ash.Changeset.for_update(:change_role, %{role: :member}, actor: admin)
               |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(membership!(org, other_admin), action: :remove, actor: admin)
    end

    test "membership mutations re-check the target role after locking the organization" do
      %{org: org, member: member} = team_with_member()
      admin = add_member!(org, :admin)
      stale_target = membership!(org, member)

      PromptOn.Repo.query!(
        "UPDATE memberships SET role = 'admin' WHERE id = $1",
        [Ecto.UUID.dump!(stale_target.id)]
      )

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(stale_target, action: :remove, actor: admin)
    end

    test "owner transfers ownership atomically and can destroy only team organizations" do
      %{owner: owner, org: org, member: member} = team_with_member()

      assert {:ok, _org} =
               org
               |> Ash.Changeset.for_update(:transfer_ownership, %{user_id: member.id},
                 actor: owner
               )
               |> Ash.update()

      assert Permissions.role(member, org.id) == :owner
      assert Permissions.role(owner, org.id) == :admin

      personal = organization_for(owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               personal
               |> Ash.Changeset.for_update(:transfer_ownership, %{user_id: member.id},
                 actor: owner
               )
               |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(personal, action: :destroy, actor: owner)

      assert :ok = Ash.destroy(org, action: :destroy, actor: member)
    end

    test "organization destroy re-checks current owner after locking the organization" do
      %{owner: owner, org: org, member: member} = team_with_member()

      changeset =
        org
        |> Ash.Changeset.for_destroy(:destroy, %{}, actor: owner)
        |> Ash.Changeset.before_transaction(fn changeset ->
          assert {:ok, _org} =
                   org
                   |> Ash.Changeset.for_update(:transfer_ownership, %{user_id: member.id},
                     actor: owner
                   )
                   |> Ash.update()

          changeset
        end)

      assert {:error, %Ash.Error.Invalid{}} = Ash.destroy(changeset)
      assert Permissions.role(member, org.id) == :owner
      assert Permissions.role(owner, org.id) == :admin

      org_id = org.id

      assert {:ok, %{id: ^org_id}} =
               Ash.get(PromptOn.Accounts.Organization, org.id, actor: PromptOn.SystemActor.new())
    end
  end

  defp team_with_member do
    owner = user_fixture()
    org = team_org_fixture(%{user: owner})
    set_plan(org, :team)
    member = add_member!(org, :member)
    %{owner: owner, org: org, member: member}
  end

  defp add_member!(org, role) do
    user = user_fixture()

    {:ok, _membership} =
      Accounts.add_member(
        %{organization_id: org.id, user_id: user.id, role: writable_role(role)},
        actor: PromptOn.SystemActor.new(),
        authorize?: false
      )

    if role in [:editor, :viewer] do
      PromptOn.Repo.query!(
        "UPDATE memberships SET role = $1 WHERE organization_id = $2 AND user_id = $3",
        [Atom.to_string(role), Ecto.UUID.dump!(org.id), Ecto.UUID.dump!(user.id)]
      )
    end

    user
  end

  defp writable_role(role) when role in [:editor, :viewer], do: :member
  defp writable_role(role), do: role

  defp membership!(org, user) do
    Membership
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
    |> Ash.read_one!(actor: PromptOn.SystemActor.new())
  end

  defp project_memberships_for(user, actor) do
    PromptOn.Projects.ProjectMembership
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read(actor: actor)
  end
end
