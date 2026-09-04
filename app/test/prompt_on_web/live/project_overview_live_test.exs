defmodule PromptOnWeb.ProjectOverviewLiveTest do
  @moduledoc """
  Project overview (`/{org}/{project}`) tests: the project root screen.

  Checks: the numbers come from **rows that actually exist** (no fake columns), the period stays
  in the URL, and the router does not confuse the project root with organization screens or
  project sub-screens.
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Fixtures

  doctest PromptOnWeb.ProjectOverviewLive, import: true

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", name: "Acme"})
    production = Fixtures.environment(project, "production")
    use_case = Fixtures.use_case_fixture(project, %{key: "diary_generation"})

    %{
      conn: log_in_user(conn, user),
      user: user,
      project: project,
      production: production,
      use_case: use_case
    }
  end

  # Extracts only the value cells of a tile/row: check cell by cell so a digit in another cell
  # cannot make the assertion pass.
  defp cells(view, id) do
    view
    |> element("##{id}")
    |> render()
    |> String.replace(~r/<[^>]*>/, "|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  describe "routing" do
    test "the project root is the overview screen and the sidebar Overview is active", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/acme")

      assert has_element?(view, "#project-overview-screen")
      assert has_element?(view, "#nav-overview.active")
      assert has_element?(view, "#sidebar")
    end

    test "another user's project root does not open", %{conn: conn} do
      stranger = Fixtures.user_fixture()
      hidden = Fixtures.project_fixture(%{user: stranger, slug: "hidden"})

      assert {:error, {:redirect, %{to: "/personal"}}} = live(conn, ~p"/personal/#{hidden.slug}")
    end

    test "redirects to /sign-in when signed out" do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/personal/acme")
    end
  end

  describe "retention note" do
    test "says how long the logs on this screen are kept, from the plan", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme")

      assert view |> element("#overview-retention-note") |> render() =~
               "Logs are kept for 7 days, and at most the most recent 1,000 per use case — whichever comes first (Free plan)."
    end

    test "a paid organization sees its own numbers", %{conn: conn, user: user} do
      Fixtures.set_plan(Fixtures.organization_for(user), :pro)

      {:ok, view, _html} = live(conn, ~p"/personal/acme")

      assert view |> element("#overview-retention-note") |> render() =~
               "Logs are kept for 90 days, and at most the most recent 100,000 per use case — whichever comes first (Pro plan)."
    end
  end

  describe "honest numbers" do
    test "with no generations it is 0 (not glossed over as —)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme")

      assert ["generations", "0", "errors", "0", "tokens", "0", "cost", "$0"] =
               cells(view, "overview-totals")
    end

    test "totals count the actually ingested Generations as they are", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      now = DateTime.utc_now()

      payloads = [
        generation_payload_fixture(use_case, %{
          "started_at" => now |> DateTime.add(-60, :second) |> DateTime.to_iso8601(),
          "usage" => %{
            "input_tokens" => 100,
            "output_tokens" => 20,
            "cost_usd" => "0.25",
            "cost_source" => "provider"
          }
        }),
        generation_payload_fixture(use_case, %{
          "started_at" => now |> DateTime.add(-120, :second) |> DateTime.to_iso8601(),
          "status" => "error",
          "error" => %{"kind" => "timeout"},
          "usage" => %{}
        })
      ]

      assert %{accepted: 2} = ingest_fixture(project, payloads)

      {:ok, view, _html} = live(conn, ~p"/personal/acme")

      assert ["generations", "2", "errors", "1", "tokens", "120", "cost", "$0.25"] =
               cells(view, "overview-totals")
    end

    test "the period stays in the URL and generations outside the window are not counted", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      old =
        generation_payload_fixture(use_case, %{
          "started_at" =>
            DateTime.utc_now() |> DateTime.add(-3 * 86_400, :second) |> DateTime.to_iso8601()
        })

      assert %{accepted: 1} = ingest_fixture(project, [old])

      # The default is 24h: a generation from 3 days ago is not visible.
      {:ok, view, _html} = live(conn, ~p"/personal/acme")
      assert ["generations", "0" | _] = cells(view, "overview-totals")

      view |> element("#overview-period a", "7d") |> render_click()
      assert_patched(view, ~p"/personal/acme?period=7d")
      assert ["generations", "1" | _] = cells(view, "overview-totals")

      # Opening directly from the URL gives the same result (the same window after a remount).
      {:ok, view, _html} = live(conn, ~p"/personal/acme?period=7d")
      assert ["generations", "1" | _] = cells(view, "overview-totals")
    end

    test "an unknown ?period= falls back to the default period", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/acme?period=nope")

      assert view |> element("#overview-period a.on") |> render() =~ "24h"
    end
  end

  describe "use cases and deployments" do
    test "the use case count and deployment status reflect the real state", %{
      conn: conn,
      project: project,
      production: production,
      use_case: use_case
    } do
      other = Fixtures.use_case_fixture(project, %{key: "title_suggestion"})
      Fixtures.simple_deployment_fixture(use_case, production)

      {:ok, view, _html} = live(conn, ~p"/personal/acme")

      count = view |> element("#overview-use-case-count") |> render()
      assert count =~ "2"
      assert count =~ "defined"
      assert count =~ "with a live deployment"

      assert view |> element("#overview-use-case-#{use_case.key}") |> render() =~
               "live in production"

      assert view |> element("#overview-use-case-#{other.key}") |> render() =~ "not deployed"
    end

    test "environment rows show the live deployment count", %{
      conn: conn,
      production: production,
      use_case: use_case
    } do
      Fixtures.simple_deployment_fixture(use_case, production)

      {:ok, view, _html} = live(conn, ~p"/personal/acme")

      production_row = view |> element("#overview-env-production") |> render()
      assert production_row =~ "1 live deployments"
      assert production_row =~ "protected"

      assert view |> element("#overview-env-staging") |> render() =~ "0 live deployments"
    end

    test "says so when there are no use cases", %{conn: conn, user: user} do
      empty = Fixtures.project_fixture(%{user: user, slug: "empty"})

      {:ok, _view, html} = live(conn, ~p"/personal/#{empty.slug}")

      assert html =~ "No use cases yet."
    end
  end
end
