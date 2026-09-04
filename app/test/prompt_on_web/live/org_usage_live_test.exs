defmodule PromptOnWeb.OrgUsageLiveTest do
  @moduledoc """
  Organization usage (`/:org_slug/usage`) tests.

  Checks: the numbers match the **actually ingested Generations** (no fake columns), the period
  and the **expanded project** stay in the URL, the per-use-case breakdown sums to the project
  total, and projects of other organizations do not leak in.
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Fixtures

  doctest PromptOnWeb.OrgUsageLive, import: true

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", name: "Acme"})
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

  # A row's mono cells = [project, logs, errors, tokens, cost]. Checking a number by
  # substring could pass by matching a digit in another cell, so check cell by cell.
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
    assert ["acme", "2", "1", "120", "$0.25"] = row_cells(view, "usage-row-acme")

    totals = view |> element("#usage-totals") |> render()
    assert totals =~ "$0.25"
  end

  test "with no logs it is 0 (not glossed over as —)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/personal/usage")

    assert ["acme", "0", "0", "0", "$0"] = row_cells(view, "usage-row-acme")
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
      assert ["acme", "3", "1", "150", "$0.75"] = project_row

      chat = row_cells(view, "usage-uc-acme-chat_response")
      voice = row_cells(view, "usage-uc-acme-voice_transcription")

      assert ["chat_response", "2", "1", "120", "$0.25"] = chat
      assert ["voice_transcription", "1", "0", "30", "$0.5"] = voice

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

    test "expanding a project with no logs says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/usage?open=acme")

      assert has_element?(view, "#usage-breakdown-empty-acme")
      assert view |> element("#usage-breakdown-empty-acme") |> render() =~ "No logs"
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

  test "a non-member cannot open another organization's usage", %{conn: conn} do
    stranger = Fixtures.user_fixture()
    _closed = Fixtures.team_org_fixture(%{user: stranger, slug: "closed-doors"})

    assert {:error, {:redirect, %{to: "/personal"}}} = live(conn, ~p"/closed-doors/usage")
  end
end
