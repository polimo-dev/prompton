defmodule PromptOnWeb.OrganizationPermissionsLiveTest do
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Accounts
  alias PromptOn.Accounts.Permissions
  alias PromptOn.Fixtures
  alias PromptOn.Projects

  setup do
    owner = Fixtures.user_fixture()
    organization = Fixtures.team_org_fixture(%{user: owner}) |> Fixtures.set_plan(:pro)
    member = Fixtures.user_fixture()
    admin = Fixtures.user_fixture()

    for {user, role} <- [{member, :member}, {admin, :admin}] do
      Accounts.add_member!(
        %{organization_id: organization.id, user_id: user.id, role: role},
        actor: Fixtures.system_actor()
      )
    end

    project = Fixtures.project_fixture(%{user: member, organization: organization})
    %{owner: owner, organization: organization, member: member, admin: admin, project: project}
  end

  test "member can edit their project but cannot open or forge deletion", %{
    conn: conn,
    member: member,
    organization: organization,
    project: project
  } do
    {:ok, view, _html} =
      conn
      |> log_in_user(member)
      |> live(~p"/#{organization.slug}/#{project.slug}/settings?delete=1")

    assert has_element?(view, "#save-project")
    refute has_element?(view, "#delete-project")
    refute has_element?(view, "#delete-project-modal")
    render_submit(view, "archive_project", %{"confirm" => %{"slug" => project.slug}})
    assert is_nil(Projects.get_project!(project.id, actor: member).archived_at)
  end

  test "admin can delete projects but has no ownership controls", %{
    conn: conn,
    admin: admin,
    organization: organization,
    project: project
  } do
    conn = log_in_user(conn, admin)
    {:ok, settings, _html} = live(conn, ~p"/#{organization.slug}/#{project.slug}/settings")
    assert has_element?(settings, "#delete-project")

    {:ok, organization_settings, _html} = live(conn, ~p"/#{organization.slug}/settings")
    assert has_element?(organization_settings, "#save-org-name")
    refute has_element?(organization_settings, "#transfer-organization-owner")
    refute has_element?(organization_settings, "#delete-organization")
  end

  test "member sees organization settings as read only and forged writes are denied", %{
    conn: conn,
    member: member,
    organization: organization
  } do
    organization =
      organization
      |> Accounts.set_organization_judge_model!(%{judge_model: "openai/gpt-4.1-mini"},
        actor: Fixtures.system_actor()
      )
      |> Accounts.set_organization_draft_model!(%{draft_model: "anthropic/claude-sonnet-4"},
        actor: Fixtures.system_actor()
      )

    {:ok, view, _html} = conn |> log_in_user(member) |> live(~p"/#{organization.slug}/settings")

    assert has_element?(view, "#evaluation-model-selection", "openai/gpt-4.1-mini")
    assert has_element?(view, "#draft-model-selection", "anthropic/claude-sonnet-4")
    refute has_element?(view, "#open-evaluation-model-picker")
    refute has_element?(view, "#open-draft-model-picker")
    refute has_element?(view, "#clear-evaluation-model")
    refute has_element?(view, "#clear-draft-model")

    for target <- ["evaluation", "draft"] do
      render_click(view, "select_org_model", %{
        "target" => target,
        "model-id" => "unauthorized/model"
      })

      render_click(view, "clear_org_model", %{"target" => target})
    end

    unchanged = Ash.get!(Accounts.Organization, organization.id, actor: member)
    assert unchanged.draft_model == organization.draft_model
    assert unchanged.judge_model == organization.judge_model
    assert has_element?(view, "#org-name[readonly]")
    refute has_element?(view, "#save-org-name")
    render_submit(view, "save_name", %{"organization" => %{"name" => "Forbidden rename"}})

    assert Accounts.get_organization_by_slug!(organization.slug, actor: member).name ==
             organization.name
  end

  test "owner explicitly transfers ownership to an existing member", %{
    conn: conn,
    owner: owner,
    member: member,
    organization: organization
  } do
    {:ok, view, _html} =
      conn |> log_in_user(owner) |> live(~p"/#{organization.slug}/settings?transfer-owner=1")

    view
    |> form("#transfer-ownership-form", transfer: %{"user_id" => member.id})
    |> render_submit()

    assert_redirect(view, ~p"/#{organization.slug}/settings?tab=general")
    assert Permissions.role(member, organization.id) == :owner
    assert Permissions.role(owner, organization.id) == :admin
  end

  test "owner deletion requires the organization name and deletes its projects", %{
    conn: conn,
    owner: owner,
    organization: organization,
    project: project
  } do
    {:ok, view, _html} =
      conn |> log_in_user(owner) |> live(~p"/#{organization.slug}/settings?delete-org=1")

    view |> form("#delete-organization-form", confirm: %{"name" => "wrong"}) |> render_submit()
    assert Accounts.get_organization_by_slug!(organization.slug, actor: owner)

    view
    |> form("#delete-organization-form", confirm: %{"name" => organization.name})
    |> render_submit()

    assert_redirect(view, ~p"/personal")
    assert is_nil(Accounts.get_organization_by_slug!(organization.slug, actor: owner))
    assert is_nil(Projects.get_project!(project.id, actor: Fixtures.system_actor()))
  end
end
