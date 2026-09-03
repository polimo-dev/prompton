defmodule PromptOnWeb.AdminRouteTest do
  @moduledoc """
  This app has no built-in admin UI; `/admin` is not a route. Sign-up is open (sign-up = sign-in),
  so there must be no resource CRUD screens on a path that any signed-in user can reach.
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Fixtures

  test "the router has no path under /admin" do
    admin_routes =
      PromptOnWeb.Router.__routes__()
      |> Enum.map(& &1.path)
      |> Enum.filter(&(&1 == "/admin" or String.starts_with?(&1, "/admin/")))

    assert admin_routes == []
  end

  test "signed-in GET /admin is the organization catch-all, not an admin screen (a reserved slug)",
       %{conn: conn} do
    user = Fixtures.user_fixture()

    conn = conn |> log_in_user(user) |> get("/admin")

    # `admin` is a reserved organization slug (`PromptOn.Accounts.ReservedSlugs`), so it does not
    # resolve as `/:org_slug`, and an unknown organization is sent back to `/personal`. Nothing is
    # ever rendered with a 200.
    assert redirected_to(conn) == ~p"/personal"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Organization not found"
  end
end
