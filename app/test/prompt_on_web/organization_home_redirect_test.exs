defmodule PromptOnWeb.OrganizationHomeRedirectTest do
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Accounts
  alias PromptOn.Fixtures
  alias PromptOn.Repo
  alias PromptOnWeb.LiveProjectScope

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "a personal organization takes precedence over newer team organizations", %{
    conn: conn,
    user: user
  } do
    personal = Fixtures.organization_for(user)
    newest = Fixtures.team_org_fixture(%{user: user})
    created_at(personal, ~N[2020-01-01 00:00:00])
    created_at(newest, ~N[2021-01-01 00:00:00])

    assert {:ok, %{id: id}} = Accounts.default_organization_for(user.id, actor: user)
    assert id == personal.id
    assert LiveProjectScope.home_path(user) == "/personal"
    assert redirected_to(get(conn, ~p"/")) == "/personal"
    assert redirected_to(get(conn, ~p"/sign-in")) == "/personal"
  end

  test "root and every signed-in sign-in endpoint use the newest organization after conversion",
       %{
         conn: conn,
         user: user
       } do
    converted = convert_personal(user)
    latest = Fixtures.team_org_fixture(%{user: user})
    created_at(converted, ~N[2020-01-01 00:00:00])
    created_at(latest, ~N[2021-01-01 00:00:00])
    expected = "/#{latest.slug}"

    assert redirected_to(get(conn, ~p"/")) == expected
    assert redirected_to(get(conn, ~p"/sign-in")) == expected

    for path <- ["/sign-in", "/sign-in/verify", "/sign-in/resend", "/sign-in/reset"] do
      assert redirected_to(post(conn, path, %{})) == expected
    end

    assert {:ok, view, _html} = live(conn, expected)
    assert has_element?(view, "#org-home-screen")
    assert has_element?(view, "#switch-org-#{latest.slug}.is-current")
    assert {:ok, nil} = Accounts.personal_organization_for(user.id, actor: user)
  end

  test "missing personal and inaccessible organization paths recover to a reachable organization",
       %{
         conn: conn,
         user: user
       } do
    organization = convert_personal(user)
    hidden = Fixtures.team_org_fixture()
    expected = "/#{organization.slug}"

    for path <- [
          "/personal",
          "/personal/settings",
          "/personal/old-project/use-cases",
          "/no-such-organization",
          "/#{hidden.slug}",
          "/#{hidden.slug}/settings"
        ] do
      assert {:error, {:redirect, %{to: ^expected}}} = live(conn, path)
      assert {:ok, view, _html} = live(conn, expected)
      assert has_element?(view, "#org-home-screen")
      refute has_element?(view, "#switch-org-#{hidden.slug}")
    end

    assert {:ok, nil} = Accounts.personal_organization_for(user.id, actor: user)
  end

  test "account navigation uses the selected team organization's real slug", %{
    conn: conn,
    user: user
  } do
    converted = convert_personal(user)
    latest = Fixtures.team_org_fixture(%{user: user})
    created_at(converted, ~N[2020-01-01 00:00:00])
    created_at(latest, ~N[2021-01-01 00:00:00])

    assert {:ok, view, _html} = live(conn, ~p"/account")
    assert has_element?(view, "#account-screen")
    assert has_element?(view, "#current-org", latest.name)
    assert has_element?(view, "#org-menu-projects[href='/#{latest.slug}']")
    assert has_element?(view, "#org-projects[href='/#{latest.slug}']")
    assert has_element?(view, "#switch-org-#{latest.slug}.is-current")
    refute has_element?(view, "a[href^='/personal']")
  end

  test "with no memberships redirects terminate at an account screen without invented organization links",
       %{conn: conn, user: user} do
    organization = convert_personal(user)
    Accounts.destroy_organization!(organization, actor: user)
    Fixtures.team_org_fixture()

    assert {:ok, nil} = Accounts.default_organization_for(user.id, actor: user)
    assert LiveProjectScope.home_path(user) == "/account"
    assert redirected_to(get(conn, ~p"/")) == "/account"
    assert redirected_to(get(conn, ~p"/sign-in")) == "/account"

    for path <- ["/personal", "/personal/settings", "/no-such-organization"] do
      assert {:error, {:redirect, %{to: "/account"}}} = live(conn, path)
    end

    assert {:ok, view, _html} = live(conn, ~p"/account")
    assert has_element?(view, "#account-screen")
    assert has_element?(view, "#account-email[readonly]")
    assert has_element?(view, "#account-sign-out[href='/sign-out']")
    refute has_element?(view, "#org-menu")
    refute has_element?(view, "#organization-nav")
    refute has_element?(view, "#new-organization")
    refute has_element?(view, "a[href^='/personal']")
    assert {:ok, nil} = Accounts.personal_organization_for(user.id, actor: user)
  end

  test "default organization follows creation time rather than name, edits, membership age or other users",
       %{user: user} do
    converted = convert_personal(user)
    latest = Fixtures.team_org_fixture(%{user: user, name: "Z latest accessible"})
    joined_later = Fixtures.team_org_fixture() |> Fixtures.set_plan(:team)
    unrelated = Fixtures.team_org_fixture()

    created_at(converted, ~N[2020-01-01 00:00:00])
    created_at(joined_later, ~N[2021-01-01 00:00:00])
    created_at(latest, ~N[2022-01-01 00:00:00])
    created_at(unrelated, ~N[2024-01-01 00:00:00])

    Accounts.add_member!(
      %{organization_id: joined_later.id, user_id: user.id, role: :member},
      actor: Fixtures.system_actor()
    )

    Accounts.claim_organization_slug!(converted, %{slug: converted.slug, name: "A renamed"},
      actor: user
    )

    assert {:ok, %{id: id}} = Accounts.default_organization_for(user.id, actor: user)
    assert id == latest.id
    assert LiveProjectScope.home_path(user) == "/#{latest.slug}"

    stranger = Fixtures.user_fixture()
    assert {:ok, nil} = Accounts.default_organization_for(user.id, actor: stranger)
  end

  test "equal creation timestamps are broken deterministically by descending organization id", %{
    user: user
  } do
    converted = convert_personal(user)
    other = Fixtures.team_org_fixture(%{user: user})
    created_at(converted, ~N[2020-01-01 00:00:00])
    created_at(other, ~N[2020-01-01 00:00:00])
    expected_id = Enum.max([converted.id, other.id])

    assert {:ok, %{id: ^expected_id}} = Accounts.default_organization_for(user.id, actor: user)
  end

  test "deleting the only converted organization returns to a reachable account screen", %{
    conn: conn,
    user: user
  } do
    organization = convert_personal(user)

    assert {:ok, view, _html} =
             live(conn, ~p"/#{organization.slug}/settings?delete-org=1")

    view
    |> form("#delete-organization-form", confirm: %{"name" => organization.name})
    |> render_submit()

    assert_redirect(view, ~p"/account")
    assert {:ok, account, _html} = live(conn, ~p"/account")
    assert has_element?(account, "#account-screen")
    assert {:ok, nil} = Accounts.personal_organization_for(user.id, actor: user)
  end

  defp convert_personal(user) do
    Accounts.claim_organization_slug!(
      Fixtures.organization_for(user),
      %{slug: "converted-#{System.unique_integer([:positive])}", name: "Converted organization"},
      actor: user
    )
  end

  defp created_at(organization, timestamp) do
    Repo.query!("UPDATE organizations SET inserted_at = $1 WHERE id = $2", [
      timestamp,
      Ecto.UUID.dump!(organization.id)
    ])
  end
end
