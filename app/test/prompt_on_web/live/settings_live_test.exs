defmodule PromptOnWeb.SettingsLiveTest do
  @moduledoc """
  Project settings screen (`/{org}/{project}/settings`, mockup `s_settings.jsx` SettingsScreen)
  tests.

  Checks that modal targets stay in the URL (zero-downtime deployment discipline) and that
  environment editing goes through the real domain actions.

  This screen has **no tabs**. Provider keys (BYOK) became organization-owned on 2026-09-01 and
  moved to `PromptOnWeb.OrgSettingsLiveTest`; PromptOn SDK keys moved the same day to
  `PromptOnWeb.ApiKeysLiveTest` (`/{org}/{project}/api-keys`).
  **Context dimensions are gone altogether**: once deployments became pins (ADR 0007 revision
  2026-09-01) their only consumer, rule conditions, disappeared, and `Project.dimensions` was
  deleted as well.
  This file guards the fact that all three **are gone**.
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Fixtures
  alias PromptOn.Projects

  doctest PromptOnWeb.SettingsLive, import: true

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", name: "Acme"})
    production = Fixtures.environment(project, "production")

    %{
      conn: log_in_user(conn, user),
      user: user,
      project: project,
      production: production
    }
  end

  describe "no tabs" do
    test "the settings screen holds only the project's own things (no tab row)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings")

      assert has_element?(view, "#settings-project")
      refute has_element?(view, "#tab-project")
      refute has_element?(view, "#tab-keys")
      refute has_element?(view, "#tab-providers")
    end

    # Since each kind of key went to its own place, old `?tab=` links simply fall back to the
    # default screen (no 500s).
    test "old ?tab= URLs still render the screen", %{conn: conn} do
      for tab <- ~w(keys providers project) do
        {:ok, view, _html} = live(conn, ~p"/personal/acme/settings?tab=#{tab}")

        assert has_element?(view, "#settings-project")
        refute has_element?(view, "#settings-keys")
      end
    end

    test "the SDK key UI is not here (it moved to its own screen)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings")

      refute has_element?(view, "#sdk-keys-card")
      refute has_element?(view, "#sdk-setup-card")
      refute has_element?(view, "#issue-key")
    end

    test "the context dimension UI is gone (deployments are pins)", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/personal/acme/settings")

      refute has_element?(view, "#dimensions-card")
      refute has_element?(view, "#declare-dimension")
      refute html =~ "Context dimensions"

      # Old `?dim=` links still render the screen (only the modal does not open).
      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings?dim=plan")
      assert has_element?(view, "#settings-project")
      refute has_element?(view, "#dimension-modal")
    end
  end

  describe "General" do
    test "key is read-only and name is saved", %{conn: conn, project: project, user: user} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings")

      assert has_element?(view, "#project-key[readonly]")

      html =
        view
        |> form("#general-form", project: %{"name" => "Acme Inc."})
        |> render_submit()

      assert html =~ "Project saved"

      {:ok, reloaded} = Projects.get_project(project.id, actor: user)
      assert reloaded.name == "Acme Inc."
      assert reloaded.slug == "acme"
    end
  end

  describe "Environments" do
    test "rows show the live Deployment count", %{
      conn: conn,
      project: project,
      production: production
    } do
      use_case = Fixtures.use_case_fixture(project)
      Fixtures.simple_deployment_fixture(use_case, production)

      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings")

      assert view |> element("#env-row-production") |> render() =~ "1 live deployments"
      assert view |> element("#env-row-production") |> render() =~ "protected"
      assert view |> element("#env-row-staging") |> render() =~ "0 live deployments"
    end

    test "the add-environment modal stays in the URL as ?env=new and creates the environment", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings")

      view |> element("#add-environment") |> render_click()
      assert_patched(view, ~p"/personal/acme/settings?env=new")
      assert has_element?(view, "#environment-form")

      view
      |> form("#environment-form",
        environment: %{"slug" => "development", "name" => "Development", "protected" => "false"}
      )
      |> render_submit()

      assert_patched(view, ~p"/personal/acme/settings")
      assert has_element?(view, "#env-row-development")

      {:ok, envs} = Projects.list_environments(tenant: project.id, actor: user)
      development = Enum.find(envs, &(&1.slug == "development"))
      assert development.name == "Development"
      refute development.protected?
    end

    test "environment editing is ?env=<id> and production's protected flag is display-only", %{
      conn: conn,
      production: production
    } do
      {:ok, view, _html} =
        live(conn, ~p"/personal/acme/settings?env=#{production.id}")

      assert has_element?(view, "#environment-form")
      refute has_element?(view, "#env-protected")
      assert render(view) =~ "Protection on the default environment cannot be changed"
    end

    test "renames an environment", %{conn: conn, project: project, user: user} do
      {:ok, [_ | _] = envs} = Projects.list_environments(tenant: project.id, actor: user)
      staging = Enum.find(envs, &(&1.slug == "staging"))

      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings?env=#{staging.id}")

      view
      |> form("#environment-form", environment: %{"name" => "Stage"})
      |> render_submit()

      {:ok, reloaded} = Projects.get_environment(staging.id, tenant: project.id, actor: user)
      assert reloaded.name == "Stage"
    end
  end

  describe "Delete project" do
    test "rejects a mismatched slug", %{conn: conn, project: project, user: user} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings?delete=1")

      html =
        view |> form("#delete-project-form", confirm: %{"slug" => "nope"}) |> render_submit()

      assert html =~ "Project key does not match."

      {:ok, reloaded} = Projects.get_project(project.id, actor: user)
      assert is_nil(reloaded.archived_at)
    end

    test "typing the exact slug archives the project and goes to /personal", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings?delete=1")

      view |> form("#delete-project-form", confirm: %{"slug" => "acme"}) |> render_submit()

      assert_redirect(view, ~p"/personal")

      {:ok, projects} = Projects.list_projects(actor: user)
      refute Enum.any?(projects, &(&1.id == project.id))
    end
  end

  describe "zero-downtime deployment: form recovery" do
    test "every form carries phx-change (recovery target)", %{conn: conn, project: project} do
      # Phoenix form recovery only replays `form[phx-change]` on reconnect: a phx-submit-only
      # form comes back with its inputs wiped even when the modal is reopened from the URL.
      staging = Fixtures.environment(project, "staging")

      forms = [
        {~p"/personal/acme/settings", "#general-form"},
        {~p"/personal/acme/settings?env=new", "#environment-form"},
        {~p"/personal/acme/settings?env=#{staging.id}", "#environment-form"},
        {~p"/personal/acme/settings?delete=1", "#delete-project-form"}
      ]

      for {path, selector} <- forms do
        {:ok, view, _html} = live(conn, path)
        assert view |> element(selector) |> render() =~ "phx-change=", "#{selector} (#{path})"
      end
    end

    test "the recovery event puts the typed values back into the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme/settings?env=new")

      view
      |> element("#environment-form")
      |> render_change(%{"environment" => %{"slug" => "typed-slug", "name" => "Typed"}})

      form = view |> element("#environment-form") |> render()
      assert form =~ "typed-slug"
      assert form =~ "Typed"
    end

    test "a tampered ?env[a]=b only closes the modal", %{conn: conn} do
      # The URL is a shared contract: the screen must render even from a broken link (no 500s).
      {:ok, view, html} = live(conn, ~p"/personal/acme/settings" <> "?env[a]=b")

      assert html =~ "settings-project"
      refute has_element?(view, "#environment-modal")
    end
  end

  describe "access control" do
    test "another user's project settings do not open", %{conn: conn} do
      stranger = Fixtures.user_fixture()
      hidden = Fixtures.project_fixture(%{user: stranger, slug: "hidden"})

      assert {:error, {:redirect, %{to: "/personal"}}} =
               live(conn, ~p"/personal/#{hidden.slug}/settings")
    end

    test "redirects to /sign-in when signed out" do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(build_conn(), ~p"/personal/acme/settings")
    end
  end
end
