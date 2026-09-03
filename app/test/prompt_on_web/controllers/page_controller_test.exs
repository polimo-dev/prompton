defmodule PromptOnWeb.PageControllerTest do
  @moduledoc """
  The root (`/`) is a fork, not a screen: it is always either `/personal` or `/sign-in`.
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Fixtures

  test "GET / sends a signed-out visitor to sign-in", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/sign-in"
  end

  test "GET / sends a signed-in user to /personal", %{conn: conn} do
    user = Fixtures.user_fixture()

    conn = conn |> log_in_user(user) |> get(~p"/")

    assert redirected_to(conn) == ~p"/personal"
  end

  test "with a project the root still goes to the personal organization home, not into the project",
       %{conn: conn} do
    user = Fixtures.user_fixture()
    Fixtures.project_fixture(%{user: user, slug: "acme"})

    conn = conn |> log_in_user(user) |> get(~p"/")

    assert redirected_to(conn) == ~p"/personal"
  end
end
