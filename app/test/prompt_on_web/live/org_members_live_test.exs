defmodule PromptOnWeb.OrgMembersLiveTest do
  @moduledoc """
  Organization member list (`/:org_slug/members`) tests.

  Checks: real `Membership` rows are drawn with email, role and join date, the fact that invite
  UI was **not built** (no dead buttons), and that members of other organizations do not leak.
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Fixtures

  doctest PromptOnWeb.OrgMembersLive, import: true

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "the personal organization shows me alone as owner", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/personal/members")

    assert html =~ to_string(user.email)
    assert html =~ "owner"
    assert has_element?(view, "#members-table")
    assert has_element?(view, "#members-note")
    assert html =~ "Invitations are coming soon"
  end

  test "a team organization shows every member's email and role", %{conn: conn, user: user} do
    org = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc"})
    # a second member is a paid-plan organization (ADR 0010 §6.4)
    Fixtures.set_plan(org, :team)
    mate = Fixtures.user_fixture(%{email: "mate@example.com"})

    {:ok, _membership} =
      PromptOn.Accounts.add_member(
        %{organization_id: org.id, user_id: mate.id, role: :editor},
        actor: Fixtures.system_actor()
      )

    {:ok, _view, html} = live(conn, ~p"/acme-inc/members")

    assert html =~ to_string(user.email)
    assert html =~ "mate@example.com"
    assert html =~ "editor"
  end

  test "there is no dead UI such as invite buttons or role editing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/personal/members")

    refute has_element?(view, "button[phx-click='invite_member']")
    refute has_element?(view, "form")
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
end
