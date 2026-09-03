defmodule PromptOnWeb.AccountLiveTest do
  @moduledoc """
  Account screen (`/account`) tests.

  Checks: the email is shown read-only, there is **no** password field (ADR 0008), "Sign out
  everywhere" cuts off the other browsers and every CLI session while keeping this browser, the
  device list and per-device logout, the sign-out link, and that the screen cannot be opened
  without signing in.
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Accounts.CliSession
  alias PromptOn.Accounts.Token
  alias PromptOn.Fixtures

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp browser_alive?(token) do
    match?(
      {:ok, [_]},
      AshAuthentication.TokenResource.Actions.get_token(Token, %{
        "token" => token,
        "purpose" => "user"
      })
    )
  end

  test "the email is shown read-only and there is a sign-out link", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/account")

    assert html =~ to_string(user.email)
    assert has_element?(view, "#account-email[readonly]")
    assert has_element?(view, "#account-sign-out[href='/sign-out']")
  end

  test "there is no password field: sign-in is the email code only", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/account")

    refute has_element?(view, "#account-password-card")
    refute has_element?(view, "#password-form")
    refute html =~ "Change password"
    assert html =~ "there is no password"
  end

  describe "sign out everywhere" do
    test "revokes every other browser session and every CLI session, keeps this browser",
         %{conn: conn, user: user} do
      {:ok, cli, %{"jti" => cli_jti}} = CliSession.issue(user, name: "CLI on lain")
      {:ok, other_browser, _} = AshAuthentication.Jwt.token_for_user(user, %{})

      {:ok, view, _html} = live(conn, ~p"/account")
      assert has_element?(view, "#device-row-#{cli_jti}")

      html = view |> element("#account-sign-out-everywhere") |> render_click()

      assert html =~ "Signed out everywhere else."
      assert :error = CliSession.verify(cli)
      refute browser_alive?(other_browser)
      refute has_element?(view, "#device-row-#{cli_jti}")
      assert has_element?(view, "#device-empty")

      # Opens again with the same cookie: the current session was not revoked.
      assert {:ok, _view, again} = live(conn, ~p"/account")
      assert again =~ to_string(user.email)
    end

    test "leaves other users alone", %{conn: conn} do
      other = Fixtures.user_fixture()
      {:ok, theirs, _} = CliSession.issue(other, name: "theirs")

      {:ok, view, _html} = live(conn, ~p"/account")
      view |> element("#account-sign-out-everywhere") |> render_click()

      assert {:ok, _} = CliSession.verify(theirs)
    end
  end

  describe "logged-in devices" do
    test "lists CLI sessions with name, client and last use", %{conn: conn, user: user} do
      {:ok, _token, %{"jti" => jti}} =
        CliSession.issue(user, client: "prompton-cli/0.1.0 (darwin/arm64)", name: "CLI on lain")

      {:ok, view, html} = live(conn, ~p"/account")

      assert html =~ "Logged-in devices"
      assert has_element?(view, "#device-row-#{jti}", "CLI on lain")
      assert has_element?(view, "#device-row-#{jti}", "prompton-cli/0.1.0 (darwin/arm64)")
      assert has_element?(view, "#device-row-#{jti}", "used never")
      assert has_element?(view, "#logout-device-#{jti}")
      refute has_element?(view, "#device-empty")
    end

    test "shows an empty state when nothing is connected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account")

      assert has_element?(view, "#device-empty", "prompton login")
    end

    test "Log out revokes that device only", %{conn: conn, user: user} do
      {:ok, laptop, %{"jti" => laptop_jti}} = CliSession.issue(user, name: "laptop")
      {:ok, desktop, %{"jti" => desktop_jti}} = CliSession.issue(user, name: "desktop")

      {:ok, view, _html} = live(conn, ~p"/account")

      html = view |> element("#logout-device-#{laptop_jti}") |> render_click()

      assert html =~ "Device signed out"
      refute has_element?(view, "#device-row-#{laptop_jti}")
      assert has_element?(view, "#device-row-#{desktop_jti}")
      assert :error = CliSession.verify(laptop)
      assert {:ok, _} = CliSession.verify(desktop)
    end

    test "a malformed logout payload does not crash the view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/account")

      assert render_click(view, "logout_device", %{"jti" => []}) =~ "already signed out"
      assert render_click(view, "logout_device", %{}) =~ "already signed out"
      assert has_element?(view, "#account-devices-card")
    end

    test "another user's device cannot be signed out from here", %{conn: conn} do
      other = Fixtures.user_fixture()
      {:ok, theirs, %{"jti" => their_jti}} = CliSession.issue(other, name: "theirs")

      {:ok, view, _html} = live(conn, ~p"/account")
      refute has_element?(view, "#device-row-#{their_jti}")

      html = render_click(view, "logout_device", %{"jti" => their_jti})

      assert html =~ "already signed out"
      assert {:ok, _} = CliSession.verify(theirs)
    end
  end

  test "redirects to the sign-in screen when not signed in" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/account")
  end
end
