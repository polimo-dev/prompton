defmodule PromptOnWeb.OrgUsageLiveTest do
  @moduledoc """
  Organization usage (`/:org_slug/usage`) tests.

  Checks monitoring and AI cost accounting, matching organization/project/use-case totals, URL
  state for periods and expanded projects, and organization/project access boundaries.
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Fixtures

  doctest PromptOnWeb.OrgUsageLive, import: true

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", description: "Acme"})
    use_case = Fixtures.use_case_fixture(project, %{key: "chat_response"})

    %{conn: log_in_user(conn, user), user: user, project: project, use_case: use_case}
  end

  defp seed(project, use_case, opts) do
    now = DateTime.utc_now()

    payloads =
      [
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
      ] ++ Keyword.get(opts, :extra, [])

    ingest_fixture(project, payloads)
  end

  # Compare cells so a digit in a different column cannot satisfy an assertion.
  # Columns: name, logs, errors, tokens, calls cost, Draft, Evaluation, total cost.
  defp row_cells(view, id) do
    view
    |> element("##{id}")
    |> render()
    |> String.replace(~r/<[^>]*>/, "|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  test "rows and totals report the real Generation count, cost and errors as they are", %{
    conn: conn,
    project: project,
    use_case: use_case
  } do
    assert %{accepted: 2} = seed(project, use_case, [])

    {:ok, view, _html} = live(conn, ~p"/personal/usage")

    # 2 logs, 1 error, 120 tokens, $0.25 cost
    assert ["acme", "2", "1", "120", "$0.25", "$0", "$0", "$0.25"] =
             row_cells(view, "usage-row-acme")

    totals = view |> element("#usage-totals") |> render()
    assert totals =~ "$0.25"
  end

  test "with no usage every count and cost is zero", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/personal/usage")

    assert ["acme", "0", "0", "0", "$0", "$0", "$0", "$0"] =
             row_cells(view, "usage-row-acme")

    refute has_element?(view, "#usage-incomplete-costs")
  end

  test "the project name expands and collapses without leaving usage", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/personal/usage?period=7d")

    assert has_element?(view, "#usage-open-acme[data-phx-link='patch'][aria-expanded='false']")
    view |> element("#usage-open-acme") |> render_click()

    assert_patched(view, ~p"/personal/usage?#{[period: "7d", open: "acme"]}")
    assert has_element?(view, "#usage-breakdown-acme")
    assert has_element?(view, "#usage-open-acme[aria-expanded='true']")

    view |> element("#usage-open-acme") |> render_click()

    assert_patched(view, ~p"/personal/usage?period=7d")
    refute has_element?(view, "#usage-breakdown-acme")
  end

  test "the period stays in the URL as ?period=", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/personal/usage")

    view |> element("#usage-period a", "30d") |> render_click()

    assert_patched(view, ~p"/personal/usage?period=30d")
  end

  test "logs outside the period are not counted", %{
    conn: conn,
    project: project,
    use_case: use_case
  } do
    old =
      generation_payload_fixture(use_case, %{
        "started_at" => DateTime.utc_now() |> DateTime.add(-3, :day) |> DateTime.to_iso8601()
      })

    assert %{accepted: 3} = seed(project, use_case, extra: [old])

    {:ok, view, _html} = live(conn, ~p"/personal/usage?period=24h")
    assert ["acme", "2" | _rest] = row_cells(view, "usage-row-acme")

    {:ok, view, _html} = live(conn, ~p"/personal/usage?period=7d")
    assert ["acme", "3" | _rest] = row_cells(view, "usage-row-acme")
  end

  test "a tampered ?period=nope falls back to the default period", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/personal/usage" <> "?period=nope")

    assert has_element?(view, "#usage-period a.on", "24h")
  end

  test "another organization's projects have no row", %{conn: conn, user: user} do
    team = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc"})
    Fixtures.project_fixture(%{user: user, organization: team, slug: "team-proj"})

    {:ok, view, _html} = live(conn, ~p"/personal/usage")

    assert has_element?(view, "#usage-row-acme")
    refute has_element?(view, "#usage-row-team-proj")

    {:ok, view, _html} = live(conn, ~p"/acme-inc/usage")

    assert has_element?(view, "#usage-row-team-proj")
    refute has_element?(view, "#usage-row-acme")
  end

  test "an organization with no projects is the empty state", %{conn: conn, user: user} do
    _empty = Fixtures.team_org_fixture(%{user: user, slug: "empty-co"})

    {:ok, view, _html} = live(conn, ~p"/empty-co/usage")

    assert has_element?(view, "#usage-empty")
    refute has_element?(view, "#usage-table")
  end

  describe "per-use-case breakdown (?open=)" do
    test "expanding opens per-use-case rows and their sum equals the project total", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      other_use_case = Fixtures.use_case_fixture(project, %{key: "voice_transcription"})
      now = DateTime.utc_now()

      # chat_response: 2 logs (1 error), 120 tokens, $0.25
      # voice_transcription: 1 generation, 30 tokens, $0.50
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
        }),
        generation_payload_fixture(other_use_case, %{
          "started_at" => now |> DateTime.add(-90, :second) |> DateTime.to_iso8601(),
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 20,
            "cost_usd" => "0.50",
            "cost_source" => "provider"
          }
        })
      ]

      assert %{accepted: 3} = ingest_fixture(project, payloads)

      {:ok, view, _html} = live(conn, ~p"/personal/usage")

      # While collapsed there are no use case rows.
      refute has_element?(view, "#usage-breakdown-acme")

      view |> element("#usage-toggle-acme") |> render_click()
      assert_patched(view, ~p"/personal/usage?#{[period: "24h", open: "acme"]}")
      assert has_element?(view, "#usage-breakdown-acme")

      project_row = row_cells(view, "usage-row-acme")
      assert ["acme", "3", "1", "150", "$0.75", "$0", "$0", "$0.75"] = project_row

      chat = row_cells(view, "usage-uc-acme-chat_response")
      voice = row_cells(view, "usage-uc-acme-voice_transcription")

      assert ["chat_response", "2", "1", "120", "$0.25", "$0", "$0", "$0.25"] = chat
      assert ["voice_transcription", "1", "0", "30", "$0.5", "$0", "$0", "$0.5"] = voice

      # Project total = sum over use cases (logs, errors, tokens)
      for column <- 1..3 do
        total = project_row |> Enum.at(column) |> String.to_integer()
        parts = [chat, voice] |> Enum.map(&(&1 |> Enum.at(column) |> String.to_integer()))
        assert total == Enum.sum(parts), "column #{column}: #{total} != #{inspect(parts)}"
      end

      # The same holds for cost (compared as values, not strings).
      assert Decimal.equal?(
               Decimal.new("0.75"),
               Decimal.add(Decimal.new("0.25"), Decimal.new("0.5"))
             )
    end

    test "clicking again collapses it and ?open= disappears", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/usage?period=24h&open=acme")

      assert has_element?(view, "#usage-breakdown-acme")

      view |> element("#usage-toggle-acme") |> render_click()

      assert_patched(view, ~p"/personal/usage?period=24h")
      refute has_element?(view, "#usage-breakdown-acme")
    end

    test "changing the period keeps the expanded project in the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/usage?open=acme")

      view |> element("#usage-period a", "7d") |> render_click()

      assert_patched(view, ~p"/personal/usage?#{[period: "7d", open: "acme"]}")
      assert has_element?(view, "#usage-breakdown-acme")
    end

    test "logs outside the period are absent from the use case rows too", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      old =
        generation_payload_fixture(use_case, %{
          "started_at" => DateTime.utc_now() |> DateTime.add(-3, :day) |> DateTime.to_iso8601()
        })

      assert %{accepted: 3} = seed(project, use_case, extra: [old])

      {:ok, view, _html} = live(conn, ~p"/personal/usage?period=24h&open=acme")
      assert ["chat_response", "2" | _rest] = row_cells(view, "usage-uc-acme-chat_response")

      {:ok, view, _html} = live(conn, ~p"/personal/usage?period=7d&open=acme")
      assert ["chat_response", "3" | _rest] = row_cells(view, "usage-uc-acme-chat_response")
    end

    test "expanding a project with no usage says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/usage?open=acme")

      assert has_element?(view, "#usage-breakdown-empty-acme")
      assert view |> element("#usage-breakdown-empty-acme") |> render() =~ "No usage"
    end

    test "a tampered ?open= falls back to collapsed", %{conn: conn, user: user} do
      team = Fixtures.team_org_fixture(%{user: user, slug: "acme-inc"})
      Fixtures.project_fixture(%{user: user, organization: team, slug: "team-proj"})

      # An unknown slug
      {:ok, view, _html} = live(conn, ~p"/personal/usage?open=nope")
      refute has_element?(view, "#usage-breakdown-nope")

      # A project slug from another organization
      {:ok, view, _html} = live(conn, ~p"/personal/usage?open=team-proj")
      refute has_element?(view, "#usage-breakdown-team-proj")
      assert has_element?(view, "#usage-row-acme")
    end
  end

  describe "Draft and Evaluation costs" do
    test "cost categories add up across use cases and projects without inflating log counts", %{
      conn: conn,
      user: user,
      project: project,
      use_case: use_case
    } do
      assert %{accepted: 2} = seed(project, use_case, [])
      ai_only = Fixtures.use_case_fixture(project, %{key: "draft_only"})
      other_project = Fixtures.project_fixture(%{user: user, slug: "second"})
      other_use_case = Fixtures.use_case_fixture(other_project, %{key: "chat_response"})

      record_ai_cost(project, use_case, :draft, "0.1")
      record_ai_cost(project, use_case, :draft, "0.2")
      record_ai_cost(project, use_case, :evaluation, "0.4")
      record_ai_cost(project, ai_only, :draft, "0.5")
      record_ai_cost(project, ai_only, :evaluation, "0.6")
      record_ai_cost(other_project, other_use_case, :evaluation, "0.7")

      {:ok, view, _html} = live(conn, ~p"/personal/usage?open=acme")

      assert ["chat_response", "2", "1", "120", "$0.25", "$0.3", "$0.4", "$0.95"] =
               row_cells(view, "usage-uc-acme-chat_response")

      assert ["draft_only", "0", "0", "0", "$0", "$0.5", "$0.6", "$1.1"] =
               row_cells(view, "usage-uc-acme-draft_only")

      assert ["acme", "2", "1", "120", "$0.25", "$0.8", "$1", "$2.05"] =
               row_cells(view, "usage-row-acme")

      assert ["second", "0", "0", "0", "$0", "$0", "$0.7", "$0.7"] =
               row_cells(view, "usage-row-second")

      assert has_element?(view, "#usage-totals", "$2.75")
      assert has_element?(view, "#usage-cost-calls", "$0.25")
      assert has_element?(view, "#usage-cost-draft", "$0.8")
      assert has_element?(view, "#usage-cost-evaluation", "$1.7")

      assert has_element?(
               view,
               "#usage-note",
               "Historical Evaluation costs include retained scores only"
             )
    end

    test "AI-only usage follows the selected period for all totals and breakdowns", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      record_ai_cost(project, use_case, :draft, "0.1")
      record_ai_cost(project, use_case, :evaluation, "0.2")
      old = DateTime.add(DateTime.utc_now(), -3, :day)
      record_ai_cost(project, use_case, :draft, "1", started_at: old)
      record_ai_cost(project, use_case, :evaluation, "2", started_at: old)

      {:ok, view, _html} = live(conn, ~p"/personal/usage?period=24h&open=acme")

      assert ["acme", "0", "0", "0", "$0", "$0.1", "$0.2", "$0.3"] =
               row_cells(view, "usage-row-acme")

      assert ["chat_response", "0", "0", "0", "$0", "$0.1", "$0.2", "$0.3"] =
               row_cells(view, "usage-uc-acme-chat_response")

      assert has_element?(view, "#usage-totals", "$0.3")
      view |> element("#usage-period a", "7d") |> render_click()

      assert ["acme", "0", "0", "0", "$0", "$1.1", "$2.2", "$3.3"] =
               row_cells(view, "usage-row-acme")

      assert ["chat_response", "0", "0", "0", "$0", "$1.1", "$2.2", "$3.3"] =
               row_cells(view, "usage-uc-acme-chat_response")

      assert has_element?(view, "#usage-totals", "$3.3")
    end

    test "unknown costs show an incomplete-total notice while reported zero remains free", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      record_ai_cost(project, use_case, :draft, "0")
      record_ai_cost(project, use_case, :evaluation, "0.2")
      {:ok, view, _html} = live(conn, ~p"/personal/usage?open=acme")
      refute has_element?(view, "#usage-incomplete-costs")

      record_ai_cost(project, use_case, :evaluation, nil)
      view |> element("#usage-period a", "7d") |> render_click()

      assert has_element?(view, "#usage-incomplete-costs", "Calls with unavailable cost: 1")
      assert has_element?(view, "#usage-totals", "$0.2")
    end

    test "AI usage in another organization cannot enter totals through a matching project slug",
         %{
           conn: conn,
           user: user,
           project: project,
           use_case: use_case
         } do
      team = Fixtures.team_org_fixture(%{user: user, slug: "cost-team"})
      team_project = Fixtures.project_fixture(%{user: user, organization: team, slug: "acme"})
      team_use_case = Fixtures.use_case_fixture(team_project, %{key: use_case.key})
      record_ai_cost(project, use_case, :draft, "0.1")
      record_ai_cost(team_project, team_use_case, :draft, "9")
      record_ai_cost(team_project, team_use_case, :evaluation, "8")

      {:ok, view, _html} = live(conn, ~p"/personal/usage?open=acme")

      assert ["acme", "0", "0", "0", "$0", "$0.1", "$0", "$0.1"] =
               row_cells(view, "usage-row-acme")

      assert has_element?(view, "#usage-cost-draft", "$0.1")
      assert has_element?(view, "#usage-cost-evaluation", "$0")

      {:ok, view, _html} = live(conn, ~p"/cost-team/usage?open=acme")

      assert ["acme", "0", "0", "0", "$0", "$9", "$8", "$17"] =
               row_cells(view, "usage-row-acme")

      assert has_element?(view, "#usage-totals", "$17")
    end

    test "a member only sees granted project costs and loses them after grant revocation", %{
      conn: conn,
      user: owner
    } do
      team = Fixtures.team_org_fixture(%{user: owner, slug: "cost-access"})
      Fixtures.set_plan(team, :team)
      allowed = Fixtures.project_fixture(%{user: owner, organization: team, slug: "allowed"})
      hidden = Fixtures.project_fixture(%{user: owner, organization: team, slug: "hidden"})
      allowed_uc = Fixtures.use_case_fixture(allowed, %{key: "chat_response"})
      hidden_uc = Fixtures.use_case_fixture(hidden, %{key: "chat_response"})
      record_ai_cost(allowed, allowed_uc, :draft, "0.1")
      record_ai_cost(hidden, hidden_uc, :evaluation, "9")
      member = Fixtures.user_fixture()

      {:ok, _membership} =
        PromptOn.Accounts.add_member(
          %{organization_id: team.id, user_id: member.id, role: :member},
          actor: Fixtures.system_actor()
        )

      {:ok, grant} =
        PromptOn.Projects.grant_project_membership(
          %{project_id: allowed.id, user_id: member.id},
          actor: owner
        )

      conn = log_in_user(conn, member)
      {:ok, view, _html} = live(conn, ~p"/cost-access/usage?open=allowed")

      assert has_element?(view, "#usage-row-allowed")
      refute has_element?(view, "#usage-row-hidden")
      assert has_element?(view, "#usage-totals", "$0.1")

      :ok = PromptOn.Projects.revoke_project_membership(grant, actor: owner)
      view |> element("#usage-period a", "7d") |> render_click()

      refute has_element?(view, "#usage-row-allowed")
      refute has_element?(view, "#usage-breakdown-allowed")
      assert has_element?(view, "#usage-empty")
      assert has_element?(view, "#usage-totals", "$0")
    end
  end

  defp record_ai_cost(project, use_case, operation, cost, opts \\ []) do
    attrs = %{
      use_case_key: use_case.key,
      operation: operation,
      model: "openai/gpt-4o-mini",
      input_tokens: 100,
      output_tokens: 20,
      cost_usd: cost,
      started_at: Keyword.get(opts, :started_at, DateTime.add(DateTime.utc_now(), -60, :second))
    }

    {:ok, usage} =
      PromptOn.Observability.record_ai_usage(attrs,
        tenant: project.id,
        actor: Fixtures.system_actor()
      )

    usage
  end

  test "a non-member cannot open another organization's usage", %{conn: conn} do
    stranger = Fixtures.user_fixture()
    _closed = Fixtures.team_org_fixture(%{user: stranger, slug: "closed-doors"})

    assert {:error, {:redirect, %{to: "/personal"}}} = live(conn, ~p"/closed-doors/usage")
  end
end
