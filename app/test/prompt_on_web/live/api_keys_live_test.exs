defmodule PromptOnWeb.ApiKeysLiveTest do
  @moduledoc """
  PromptOn SDK key screen (`/{org}/{project}/api-keys`) tests.

  In the 2026-09-01 sidebar restructure the "API Keys" tab of project Settings moved out into this
  screen, so this is the only place for issuing, revoking and SDK setup. Checks:

  - a list row carries prefix, name, scope and last use
  - the issue modal target stays in the URL (zero-downtime deployment discipline)
  - the raw issued key is shown **exactly once**
  - **keys are not bound to an environment** (2026-09-01): the issue modal has no environment
    field and the prefix is the project slug
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Fixtures
  alias PromptOn.Projects

  doctest PromptOnWeb.ApiKeysLive, import: true

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", name: "Acme"})
    production = Fixtures.environment(project, "production")

    %{conn: log_in_user(conn, user), user: user, project: project, production: production}
  end

  describe "screen" do
    test "the sidebar API keys item is active", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/api-keys")

      assert has_element?(view, "#api-keys-screen")
      assert has_element?(view, "#nav-apikeys.active")
    end

    test "a row shows prefix, name, scope and last use", %{conn: conn, project: project} do
      {key, _raw} = Fixtures.api_key_fixture(project, scopes: [:read], name: "Server key")

      {:ok, view, _html} = live(conn, ~p"/personal/acme/api-keys")

      row = view |> element("#key-row-#{key.id}") |> render()
      assert row =~ key.key_prefix
      assert row =~ "Server key"
      assert row =~ "read"
      assert row =~ "used never"
      assert has_element?(view, "#copy-key-#{key.id}[data-copy='#{key.key_prefix}']")

      # The prefix is the project slug: keys are not bound to an environment.
      assert key.key_prefix =~ "ptn_acme"
    end

    test "says so when there are no keys", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/personal/acme/api-keys")

      assert html =~ "No keys issued yet."
    end

    test "the SDK setup card carries this project's real values", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/api-keys")

      config = view |> element("#sdk-config") |> render()
      screen = render(view)
      assert config =~ "config :prompton_sdk"
      assert config =~ PromptOnWeb.Endpoint.url()
      assert config =~ "priv/prompton/use-cases.production.json"
      assert screen =~ "ETag polling every 30s"
      assert screen =~ "deployed use-case document"
      refute screen =~ "whole snapshot"
      refute screen =~ "resolves locally"
    end
  end

  describe "issuing" do
    test "the issue modal is ?issue=1 and shows the raw key exactly once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/api-keys")

      view |> element("#issue-key") |> render_click()
      assert_patched(view, ~p"/personal/acme/api-keys?issue=1")

      html =
        view
        |> form("#issue-key-form", api_key: %{"scopes" => ["read", "logs"]})
        |> render_submit()

      assert html =~ "This key will not be shown again."
      assert html =~ "ptn_acme_"
      assert has_element?(view, "#issued-key")

      # Closing with Done drops the raw key: reopening shows only the prefix.
      view |> element("#issue-done") |> render_click()
      assert_patched(view, ~p"/personal/acme/api-keys")
      refute has_element?(view, "#issued-key")
      refute render(view) =~ "This key will not be shown again."
    end

    test "the issue modal has no environment field: a key reads the whole project", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/api-keys?issue=1")

      refute has_element?(view, "#issue-env")
      assert has_element?(view, "#issue-key-name")

      view
      |> form("#issue-key-form", api_key: %{"name" => "Server key", "scopes" => ["read"]})
      |> render_submit()

      {:ok, [key]} = Projects.list_api_keys(project.id, actor: user)
      assert key.name == "Server key"
      assert key.scopes == [:read]
      refute Map.has_key?(key, :environment_id)
    end

    test "a blank name gets the default name", %{conn: conn, project: project, user: user} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/api-keys?issue=1")

      view
      |> form("#issue-key-form", api_key: %{"name" => "  ", "scopes" => ["read", "logs"]})
      |> render_submit()

      {:ok, [key]} = Projects.list_api_keys(project.id, actor: user)
      assert key.name == "SDK key"
      assert key.scopes == [:read, :logs]
    end

    test "an issued key appears in the list and disappears when revoked", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/api-keys?issue=1")

      view
      |> form("#issue-key-form", api_key: %{"scopes" => ["read"]})
      |> render_submit()

      view |> element("#issue-done") |> render_click()

      {:ok, [key]} = Projects.list_api_keys(project.id, actor: user)
      assert key.scopes == [:read]
      assert has_element?(view, "#key-row-#{key.id}")

      view |> element("#revoke-key-#{key.id}") |> render_click()

      refute has_element?(view, "#key-row-#{key.id}")
    end
  end

  describe "zero-downtime deployment: form recovery" do
    test "the issue form carries phx-change (recovery target)", %{conn: conn} do
      # Phoenix form recovery only replays `form[phx-change]` on reconnect.
      {:ok, view, _html} = live(conn, ~p"/personal/acme/api-keys?issue=1")

      assert view |> element("#issue-key-form") |> render() =~ "phx-change="
    end

    test "a tampered ?issue[a]=b does not open the modal", %{conn: conn} do
      # The URL is a shared contract: the screen must render even from a broken link (no 500s).
      {:ok, view, html} = live(conn, ~p"/personal/acme/api-keys" <> "?issue[a]=b")

      assert html =~ "api-keys-body"
      refute has_element?(view, "#issue-key-modal")
    end
  end

  describe "access control" do
    test "another user's project key screen does not open", %{conn: conn} do
      stranger = Fixtures.user_fixture()
      hidden = Fixtures.project_fixture(%{user: stranger, slug: "hidden"})

      assert {:error, {:redirect, %{to: "/personal"}}} =
               live(conn, ~p"/personal/#{hidden.slug}/api-keys")
    end

    test "redirects to /sign-in when signed out" do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(build_conn(), ~p"/personal/acme/api-keys")
    end
  end
end
