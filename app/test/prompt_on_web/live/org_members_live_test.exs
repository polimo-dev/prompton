defmodule PromptOnWeb.OrgMembersLiveTest do
  @moduledoc "Organization member management screen tests."

  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Accounts
  alias PromptOn.Fixtures

  doctest PromptOnWeb.OrgMembersLive, import: true

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "the personal organization shows members without team invitation controls", %{
    conn: conn,
    user: user
  } do
    {:ok, view, html} = live(conn, ~p"/personal/members")

    assert html =~ to_string(user.email)
    assert has_element?(view, "#members-heading", "Members")
    assert has_element?(view, "#members-table")

    labels = table_labels(view, "#members-table")
    assert labels =~ "email"
    refute labels =~ "member"

    refute has_element?(view, "#invite-member-card")
    refute html =~ "Invitations are coming soon"
  end

  test "an owner can invite a member and sees the pending invitation", %{conn: conn, user: owner} do
    {org, project} = team_with_project(owner)

    {:ok, view, _html} = live(conn, ~p"/#{org.slug}/members")

    assert has_element?(view, "#invite-member-form")
    assert has_element?(view, "#invite-role option[value='admin']")
    assert has_element?(view, "#invite-project-#{project.id}")

    invited = Fixtures.unique_email()

    html =
      render_submit(view, "invite_member", %{
        "invitation" => %{
          "email" => invited,
          "role" => "member",
          "project_ids" => [project.id]
        }
      })

    assert_receive {:email, %Swoosh.Email{text_body: text}}, 500
    assert text =~ "/invitations/"
    assert html =~ "Invitation sent"
    assert html =~ invited
    assert has_element?(view, "#pending-invitations-heading", "Pending invitations")
    assert has_element?(view, "#pending-invitations-table")
  end

  test "an admin can promote members but cannot edit another admin", %{conn: _conn} do
    owner = Fixtures.user_fixture()
    {org, _project} = team_with_project(owner)
    admin = member!(org, "admin@example.com", :admin)
    other_admin = member!(org, "other-admin@example.com", :admin)
    member = member!(org, "member@example.com", :member)

    {:ok, view, _html} = live(log_in_user(build_conn(), admin.user), ~p"/#{org.slug}/members")

    assert has_element?(view, "#member-role-form-#{member.membership.id}")
    assert has_element?(view, "#member-role-#{member.membership.id} option[value='admin']")
    refute has_element?(view, "#member-role-form-#{other_admin.membership.id}")
  end

  test "an owner can edit a member's assigned projects", %{conn: conn, user: owner} do
    {org, first_project} = team_with_project(owner)
    second_project = Fixtures.project_fixture(%{user: owner, organization: org})
    member = member!(org, "project-member@example.com", :member)

    {:ok, view, _html} = live(conn, ~p"/#{org.slug}/members")

    view
    |> element("#edit-projects-#{member.membership.id}")
    |> render_click()

    assert_patch(view, ~p"/#{org.slug}/members?projects=#{member.membership.id}")
    assert has_element?(view, "#member-projects-modal")
    assert has_element?(view, "#member-project-#{first_project.id}")
    assert has_element?(view, "#member-project-#{second_project.id}")

    html =
      render_submit(view, "assign_projects", %{
        "id" => member.membership.id,
        "membership" => %{"project_ids" => [second_project.id]}
      })

    assert_patch(view, ~p"/#{org.slug}/members")
    assert html =~ "Project access saved"
    assert html =~ second_project.slug
    refute html =~ "No projects"
  end

  test "accepted and revoked invitations are not listed as pending", %{conn: conn, user: owner} do
    {org, project} = team_with_project(owner)
    accepted_user = Fixtures.user_fixture(%{email: "accepted-invite@example.com"})

    {:ok, accepted} =
      Accounts.invite_member(
        %{
          organization_id: org.id,
          email: accepted_user.email,
          role: :member,
          project_ids: [project.id]
        },
        actor: owner
      )

    assert_receive {:email, %Swoosh.Email{}}, 500

    {:ok, _membership} =
      Accounts.accept_invitation(Ash.Resource.get_metadata(accepted, :token),
        actor: accepted_user
      )

    {:ok, revoked} =
      Accounts.invite_member(
        %{
          organization_id: org.id,
          email: "revoked-invite@example.com",
          role: :member,
          project_ids: [project.id]
        },
        actor: owner
      )

    assert_receive {:email, %Swoosh.Email{}}, 500
    {:ok, _revoked} = Accounts.revoke_invitation(revoked, actor: owner)

    {:ok, view, html} = live(conn, ~p"/#{org.slug}/members")

    refute has_element?(view, "#pending-invitations-table")
    assert html =~ "accepted-invite@example.com"
    refute html =~ "revoked-invite@example.com"
  end

  test "members cannot revoke invitations outside their invite scope", %{user: owner} do
    {org, project} = team_with_project(owner)
    member = member!(org, "read-only-member@example.com", :member)

    {:ok, invitation} =
      Accounts.invite_member(
        %{
          organization_id: org.id,
          email: "pending-owner-project@example.com",
          role: :member,
          project_ids: [project.id]
        },
        actor: owner
      )

    assert_receive {:email, %Swoosh.Email{}}, 500

    {:ok, view, html} = live(log_in_user(build_conn(), member.user), ~p"/#{org.slug}/members")

    assert html =~ "pending-owner-project@example.com"
    refute has_element?(view, "#revoke-invitation-#{invitation.id}")
  end

  test "a member can invite only to projects they created and cannot grant admin", %{conn: _conn} do
    owner = Fixtures.user_fixture()
    {org, owner_project} = team_with_project(owner)
    member = member!(org, "creator@example.com", :member)
    member_project = Fixtures.project_fixture(%{user: member.user, organization: org})

    {:ok, view, _html} = live(log_in_user(build_conn(), member.user), ~p"/#{org.slug}/members")

    assert has_element?(view, "#invite-member-card")
    assert has_element?(view, "#invite-project-#{member_project.id}")
    refute has_element?(view, "#invite-project-#{owner_project.id}")
    refute has_element?(view, "#invite-role option[value='admin']")
  end

  test "users from other organizations are not in the list", %{conn: conn, user: user} do
    _mine = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc"})
    stranger = Fixtures.user_fixture(%{email: "stranger@example.com"})
    _theirs = Fixtures.team_org_fixture(%{user: stranger, slug: "other-co"})

    {:ok, _view, html} = live(conn, ~p"/acme-inc/members")

    refute html =~ "stranger@example.com"
  end

  test "a non-member cannot open another organization's member list", %{conn: conn} do
    stranger = Fixtures.user_fixture()
    _closed = Fixtures.team_org_fixture(%{user: stranger, slug: "closed-doors"})

    assert {:error, {:redirect, %{to: "/personal"}}} = live(conn, ~p"/closed-doors/members")
  end

  defp table_labels(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".mono-label")
    |> LazyHTML.text()
  end

  defp team_with_project(owner) do
    Fixtures.set_plan(Fixtures.organization_for(owner), :team)

    org =
      Fixtures.team_org_fixture(%{
        user: owner,
        slug: "team-#{System.unique_integer([:positive])}"
      })

    Fixtures.set_plan(org, :team)

    project = Fixtures.project_fixture(%{user: owner, organization: org})
    {org, project}
  end

  defp member!(org, email, role) do
    user = Fixtures.user_fixture(%{email: email})

    {:ok, membership} =
      Accounts.add_member(
        %{organization_id: org.id, user_id: user.id, role: role},
        actor: Fixtures.system_actor()
      )

    %{user: user, membership: membership}
  end
end
