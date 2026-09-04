defmodule PromptOnWeb.EvalsPanelTest do
  @moduledoc """
  The Evals tab of the use case hub (`?tab=evals`, ADR 0010 §5), driven through
  `PromptOnWeb.PromptEditorLive` because the panel is a `LiveComponent` of that screen.

  Covers the whole loop the product decision describes — sample ten logs → score them → draft the
  rubric → look at the agreement → revise → evaluate a revision → watch the run — plus the states
  that are *not* the happy path: no logs with stored log content, no provider key, an `embedding` use
  case, and hand-edited `?set=` / `?rubric=` / `?run=` values.

  The judge is `PromptOn.LLM.Fake` (the test adapter), planted through
  `PromptOn.EvalsFixtures.plant_judge/1`. Because that adapter is configured through the
  application environment, which is global, this file is `async: false`.
  """
  use PromptOnWeb.ConnCase, async: false

  alias PromptOn.Evals
  alias PromptOn.EvalsFixtures
  alias PromptOn.Fixtures

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", name: "Acme"})
    use_case = Fixtures.use_case_fixture(project, %{key: "diary_generation"})

    on_exit(&PromptOn.LLM.Fake.reset/0)

    %{
      conn: log_in_user(conn, user),
      user: user,
      project: project,
      organization: Fixtures.organization_for(user),
      use_case: use_case
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp evals_path(project, use_case, params \\ []),
    do: ~p"/personal/#{project.slug}/use-cases/#{use_case.key}/prompt?#{[tab: "evals"] ++ params}"

  defp scope(project), do: Fixtures.scope(project)

  # Twelve real monitoring logs with their payloads stored — what "eligible" means (ADR 0010 §2.2).
  defp with_logs(project, use_case, count \\ 12),
    do: Fixtures.stored_generations_fixture(project, use_case, count, %{})

  defp with_key(project), do: Fixtures.provider_key_fixture(project, provider: :openrouter)

  # A set whose ten samples all carry a human score, so "Draft criteria with AI" is unlocked.
  defp scored_set(project, use_case) do
    {set, samples} =
      EvalsFixtures.scored_calibration_set_fixture(project, use_case, [
        5,
        4,
        4,
        3,
        3,
        2,
        2,
        1,
        5,
        4
      ])

    %{set: set, samples: samples}
  end

  # ---------------------------------------------------------------------------
  # (a) Not applicable

  describe "an embedding use case" do
    test "says evals do not apply and offers nothing to click", %{conn: conn, project: project} do
      use_case = Fixtures.use_case_fixture(project, %{key: "search_index", kind: :embedding})

      {:ok, view, html} = live(conn, evals_path(project, use_case))

      assert html =~ "Evals score a prompt&#39;s output. This use case is log-only (embedding)."
      assert has_element?(view, "#evals-not-applicable")
      refute has_element?(view, "#sample-logs")
      refute has_element?(view, "#continuous-eval")
    end
  end

  # ---------------------------------------------------------------------------
  # (b) Empty

  describe "the empty state" do
    test "explains the loop and offers Sample 10 logs", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      with_logs(project, use_case)

      {:ok, view, html} = live(conn, evals_path(project, use_case))

      assert html =~ "Score 10 real logs"
      assert has_element?(view, "#sample-logs", "Sample 10 logs")
      refute has_element?(view, "#evals-no-logs")
    end

    test "says so when there are fewer than five logs with stored log content", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      with_logs(project, use_case, 3)

      {:ok, view, html} = live(conn, evals_path(project, use_case))

      assert html =~ "No monitoring logs with stored log content yet"
      assert has_element?(view, "#evals-no-logs")
      assert has_element?(view, "#evals-open-api-keys")
      refute has_element?(view, "#sample-logs")
    end

    test "without a provider key sampling still works and only the AI step is blocked", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      with_logs(project, use_case)

      {:ok, view, _html} = live(conn, evals_path(project, use_case))

      assert has_element?(view, "#evals-no-key")
      assert has_element?(view, "#sample-logs")
    end
  end

  # ---------------------------------------------------------------------------
  # (c) Scoring

  describe "sampling and scoring" do
    test "Sample 10 logs freezes ten cards and pins the set in the URL", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      with_logs(project, use_case)

      {:ok, view, _html} = live(conn, evals_path(project, use_case))

      html = view |> element("#sample-logs") |> render_click()

      assert html =~ "0 / 10 scored"

      for position <- 1..10 do
        assert has_element?(view, "#sample-#{position}")
      end

      {:ok, [set]} = Evals.list_calibration_sets(use_case.id, scope(project))
      assert_patched(view, evals_path(project, use_case, set: set.id))
    end

    test "clicking a star writes immediately and survives a remount", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      with_logs(project, use_case)

      {:ok, view, _html} = live(conn, evals_path(project, use_case))
      render_click(element(view, "#sample-logs"))

      html =
        view
        |> element(~s|#sample-1 button[phx-value-star="4"]|)
        |> render_click()

      assert html =~ "1 / 10 scored"

      {:ok, [set]} = Evals.list_calibration_sets(use_case.id, scope(project))
      {:ok, [first | _rest]} = Evals.list_calibration_samples(set.id, scope(project))
      assert first.user_score == 4

      {:ok, _view, remounted} = live(conn, evals_path(project, use_case))
      assert remounted =~ "1 / 10 scored"
    end

    test "the note is disabled until the sample has a score, then it stores", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      with_logs(project, use_case)

      {:ok, view, _html} = live(conn, evals_path(project, use_case))
      render_click(element(view, "#sample-logs"))

      assert view |> element("#sample-1-note") |> render() =~ "disabled"

      render_click(element(view, ~s|#sample-1 button[phx-value-star="5"]|))
      refute view |> element("#sample-1-note") |> render() =~ "disabled"

      view |> element("#sample-1-note") |> render_blur(%{"value" => "perfect answer"})

      {:ok, [set]} = Evals.list_calibration_sets(use_case.id, scope(project))
      {:ok, [first | _rest]} = Evals.list_calibration_samples(set.id, scope(project))
      assert first.user_note == "perfect answer"
    end

    test "Draft criteria with AI is disabled until every sample is scored", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      with_key(project)
      with_logs(project, use_case)

      {:ok, view, _html} = live(conn, evals_path(project, use_case))
      render_click(element(view, "#sample-logs"))

      assert view |> element("#draft-rubric") |> render() =~ "disabled"
      assert render(view) =~ "Score all 10 samples first."
    end

    test "an unknown ?set= falls back to the latest set instead of breaking", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      %{set: set} = scored_set(project, use_case)

      {:ok, view, _html} =
        live(conn, evals_path(project, use_case, set: Ash.UUIDv7.generate()))

      assert has_element?(view, "#sample-1")
      assert render(view) =~ "10 / 10 scored"
      assert set.id
    end
  end

  # ---------------------------------------------------------------------------
  # (d) Criteria and agreement

  describe "drafting a rubric" do
    setup %{project: project, use_case: use_case} do
      with_key(project)
      Map.merge(%{}, scored_set(project, use_case))
    end

    test "produces a rubric, the agreement table and the three stat tiles", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      EvalsFixtures.plant_judge(4)

      {:ok, view, _html} = live(conn, evals_path(project, use_case))
      refute view |> element("#draft-rubric") |> render() =~ "disabled"

      render_click(element(view, "#draft-rubric"))
      html = render_async(view, 1_000)

      assert html =~ "A good answer is short and answers the question."
      assert has_element?(view, "#rubric-card")
      assert has_element?(view, "#agreement-table")
      assert has_element?(view, "#agreement-1")
      assert html =~ "mean abs. error"
      assert html =~ "within ±1"
      assert html =~ "exact"

      {:ok, [rubric]} = Evals.list_rubrics(use_case.id, scope(project))
      assert rubric.source == :ai_draft
      assert rubric.number == 1
    end

    test "a judge that answers with something other than JSON is one flash, not a crash", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      PromptOn.LLM.Fake.set_response(%{content: "I would rather not."})

      {:ok, view, _html} = live(conn, evals_path(project, use_case))
      render_click(element(view, "#draft-rubric"))

      render_async(view, 1_000)

      # The panel hands its flashes to the LiveView, so the tray shows on the render after the
      # async result lands.
      assert render(view) =~ "The judge did not answer with JSON."
      assert {:ok, []} = Evals.list_rubrics(use_case.id, scope(project))
    end

    test "without a provider key the AI buttons are disabled" do
      user = Fixtures.user_fixture()
      other = Fixtures.project_fixture(%{user: user, slug: "no-key"})
      use_case = Fixtures.use_case_fixture(other, %{key: "unkeyed"})
      scored_set(other, use_case)

      {:ok, view, _html} = live(log_in_user(build_conn(), user), evals_path(other, use_case))

      assert view |> element("#draft-rubric") |> render() =~ "disabled"
      assert render(view) =~ "No provider key"
    end
  end

  describe "an existing rubric" do
    setup %{conn: conn, project: project, use_case: use_case} do
      with_key(project)
      %{set: set, samples: samples} = scored_set(project, use_case)
      v1 = EvalsFixtures.rubric_fixture(use_case, %{calibration_set_id: set.id})

      for sample <- samples do
        EvalsFixtures.calibration_score_fixture(v1, sample, %{score: sample.user_score})
      end

      %{conn: conn, v1: v1, set: set, samples: samples}
    end

    # Before: the three tiles read "n = 10 · within ±1 100%" (rubric aggregates over set A) while
    # every agreement row read "not scored against these criteria yet" (samples of set B) — one screen
    # contradicting itself, and no way back to set A because `?set=` had no control.
    test "sampling again does not leave the rubric's numbers next to another set's rows", %{
      conn: conn,
      project: project,
      use_case: use_case,
      set: set
    } do
      {:ok, view, _html} = live(conn, evals_path(project, use_case))
      assert has_element?(view, "#agreement-table")

      view |> element("#resample-logs") |> render_click()

      refute has_element?(view, "#agreement-table")
      assert has_element?(view, "#rubric-other-set")
      assert render(view) =~ "was calibrated on an earlier sample set"

      # …and the set the rubric belongs to is reachable again
      assert has_element?(view, "#calibration-set-picker")
      view |> element(~s|#rubric-other-set a[href*="set=#{set.id}"]|) |> render_click()

      assert has_element?(view, "#agreement-table")
      refute has_element?(view, "#rubric-other-set")
    end

    test "the version selector patches ?rubric= and an unknown number falls back", %{
      conn: conn,
      project: project,
      use_case: use_case,
      v1: v1
    } do
      v2 = EvalsFixtures.rubric_fixture(use_case, %{note: "tighter"})

      {:ok, view, html} = live(conn, evals_path(project, use_case))
      assert html =~ "v#{v2.number}"
      assert has_element?(view, "#rubric-versions")

      view
      |> element(~s|#rubric-versions a[href*="rubric=#{v1.number}"]|)
      |> render_click()

      assert_patched(view, evals_path(project, use_case, rubric: to_string(v1.number)))

      {:ok, _view, fallback} = live(conn, evals_path(project, use_case, rubric: "99"))
      assert fallback =~ "v#{v2.number}"
    end

    test "the agreement table shows both scores and the gap", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, html} = live(conn, evals_path(project, use_case))

      assert has_element?(view, "#agreement-table")
      assert has_element?(view, "#agreement-1")
      # Every AI score equals the human score in this fixture, so agreement is perfect.
      assert html =~ "100%"
      assert html =~ "0.0"
    end

    test "Revise with AI opens a modal, and revising mints the next version", %{
      conn: conn,
      project: project,
      use_case: use_case,
      v1: v1
    } do
      EvalsFixtures.plant_judge(3)

      {:ok, view, _html} = live(conn, evals_path(project, use_case))
      view |> element("#revise-rubric") |> render_click()

      assert_patched(view, evals_path(project, use_case, revise: "1"))
      assert has_element?(view, "#revise-modal")

      view
      |> form("#revise-form", %{"revise" => %{"note" => "a wrong language is never above 2"}})
      |> render_submit()

      render_async(view, 1_000)

      {:ok, rubrics} = Evals.list_rubrics(use_case.id, scope(project))

      assert [%{number: 2, source: :ai_revision, note: "a wrong language is never above 2"} | _] =
               rubrics

      assert v1.number == 1
    end

    test "Edit manually writes a new manual version from the form", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, evals_path(project, use_case))
      view |> element("#edit-rubric") |> render_click()

      assert has_element?(view, "#rubric-editor-modal")

      view
      |> form("#rubric-form", %{
        "rubric" => %{
          "summary" => "Answer in the user's language.",
          "must_never" => "switch language\ninvent facts",
          "level_1" => "no answer",
          "level_2" => "wrong language",
          "level_3" => "right language, wrong content",
          "level_4" => "right, a bit long",
          "level_5" => "right and short"
        }
      })
      |> render_submit()

      {:ok, [latest | _rest]} = Evals.list_rubrics(use_case.id, scope(project))
      assert latest.source == :manual
      assert latest.number == 2
      assert latest.criteria.summary == "Answer in the user's language."
      assert latest.criteria.must_never == ["switch language", "invent facts"]
    end

    test "Re-score with these criteria re-runs the judge over the same samples", %{
      conn: conn,
      project: project,
      use_case: use_case,
      v1: v1
    } do
      EvalsFixtures.plant_score_answer(2, "level 2")

      {:ok, view, _html} = live(conn, evals_path(project, use_case))
      render_click(element(view, "#rescore-rubric"))

      render_async(view, 1_000)
      assert render(view) =~ "Scored 10 sample(s) with these criteria."

      {:ok, scores} = Evals.list_calibration_scores(v1.id, scope(project))
      assert Enum.all?(scores, &(&1.score == 2))
    end
  end

  # ---------------------------------------------------------------------------
  # (e) Evaluate

  describe "the Evaluate modal" do
    setup %{project: project, use_case: use_case} do
      with_key(project)
      stage = EvalsFixtures.evaluatable_fixture(project, use_case: use_case, count: 6)
      %{deployment: stage.deployment, rubric: stage.rubric, environment: stage.environment}
    end

    test "shows the live revision, the rubric and the eligible count", %{
      conn: conn,
      project: project,
      use_case: use_case,
      deployment: deployment,
      rubric: rubric
    } do
      {:ok, view, _html} = live(conn, evals_path(project, use_case))
      view |> element("#evaluate-open") |> render_click()

      assert_patched(view, evals_path(project, use_case, evaluate: "1"))
      html = render(view)

      assert has_element?(view, "#evaluate-modal")
      assert html =~ "##{deployment.revision}"
      assert html =~ "v#{rubric.number}"
      assert html =~ "6 of the last 1,000 logs of this revision have stored log content."
      assert html =~ "on your OpenRouter key"
      assert has_element?(view, "#run-evaluation")
    end

    test "is blocked, with the reason in place of the button, when nothing is deployed there", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} =
        live(conn, evals_path(project, use_case, evaluate: "1", env: "staging"))

      assert render(view) =~ "Nothing is deployed to staging yet."
      refute has_element?(view, "#run-evaluation")
      assert has_element?(view, "#evaluate-blocked")
    end

    test "Run evaluation starts a run and the running card appears", %{
      conn: conn,
      project: project,
      use_case: use_case,
      deployment: deployment
    } do
      {:ok, view, _html} = live(conn, evals_path(project, use_case, evaluate: "1"))
      view |> element("#run-evaluation") |> render_click()

      {:ok, %{results: [run]}} = Evals.list_evaluation_runs(use_case.id, scope(project))
      assert run.deployment_id == deployment.id
      assert run.item_count == 6
      assert run.status == :queued

      html = render(view)
      assert html =~ "0 / 6 done"
      assert has_element?(view, "#run-#{run.id}")
      assert has_element?(view, "#run-drawer")
    end

    test "is blocked without a provider key" do
      user = Fixtures.user_fixture()
      project = Fixtures.project_fixture(%{user: user, slug: "unkeyed"})
      use_case = Fixtures.use_case_fixture(project, %{key: "diary_generation"})
      EvalsFixtures.evaluatable_fixture(project, use_case: use_case, count: 6)

      {:ok, view, _html} =
        live(log_in_user(build_conn(), user), evals_path(project, use_case, evaluate: "1"))

      assert render(view) =~ "No provider key"
      refute has_element?(view, "#run-evaluation")

      # The modal is a full-screen overlay, so the panel's own link is covered: the way out has to
      # be inside the modal.
      assert has_element?(view, "#evaluate-providers-link")
      assert view |> element("#evaluate-providers-link") |> render() =~ "/personal/settings"
    end

    # ADR 0010 §5.3(e): `?rubric=` steers what is displayed; a run is always the current rubric,
    # because the revision badge takes the newest completed run regardless of rubric.
    test "evaluating uses the current rubric even when an older one is selected", %{
      conn: conn,
      project: project,
      use_case: use_case,
      rubric: rubric
    } do
      v2 = EvalsFixtures.rubric_fixture(use_case)
      assert v2.number == rubric.number + 1

      {:ok, view, _html} =
        live(conn, evals_path(project, use_case, rubric: rubric.number, evaluate: "1"))

      assert render(view) =~ "v#{v2.number}"
      view |> element("#run-evaluation") |> render_click()

      {:ok, %{results: [run]}} = Evals.list_evaluation_runs(use_case.id, scope(project))
      assert run.rubric_id == v2.id
      assert run.rubric_number == v2.number
    end

    test "with no rubric at all the row is an em dash, not a bare v", %{conn: conn} do
      user = Fixtures.user_fixture()
      project = Fixtures.project_fixture(%{user: user, slug: "rubricless"})
      use_case = Fixtures.use_case_fixture(project, %{key: "diary_generation"})
      with_key(project)
      environment = Fixtures.environment(project, "production")
      Fixtures.simple_deployment_fixture(use_case, environment, %{})

      {:ok, view, _html} =
        live(log_in_user(conn, user), evals_path(project, use_case, evaluate: "1"))

      html = view |> element("#evaluate-modal") |> render()

      refute html =~ ">v<"
      assert html =~ "Draft criteria first"
    end

    test "a second run of the same revision is refused while the first is active", %{
      conn: conn,
      project: project,
      use_case: use_case,
      deployment: deployment,
      rubric: rubric
    } do
      EvalsFixtures.evaluation_run_fixture(use_case, deployment, %{rubric: rubric})

      {:ok, view, _html} = live(conn, evals_path(project, use_case, evaluate: "1"))

      assert render(view) =~ "An evaluation of this revision is already running."
      refute has_element?(view, "#run-evaluation")
    end
  end

  # ---------------------------------------------------------------------------
  # (f) Runs

  describe "the run list and drawer" do
    setup %{project: project, use_case: use_case} do
      with_key(project)
      stage = EvalsFixtures.evaluatable_fixture(project, use_case: use_case, count: 6)

      run =
        EvalsFixtures.evaluation_run_fixture(use_case, stage.deployment, %{rubric: stage.rubric})

      %{run: run, deployment: stage.deployment}
    end

    test "?run= opens the drawer and Cancel stops the run", %{
      conn: conn,
      project: project,
      use_case: use_case,
      run: run
    } do
      {:ok, view, _html} = live(conn, evals_path(project, use_case, run: run.id))

      assert has_element?(view, "#run-drawer")
      assert render(view) =~ "0 / 6 done"

      view |> element("#cancel-run") |> render_click()

      {:ok, cancelled} = Evals.get_evaluation_run(run.id, scope(project))
      assert cancelled.status == :cancelled
    end

    test "an unknown ?run= closes the drawer rather than crashing", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} =
        live(conn, evals_path(project, use_case, run: Ash.UUIDv7.generate()))

      refute has_element?(view, "#run-drawer")
      assert has_element?(view, "#evals-runs")
    end

    # ADR 0010 §5.3: while a run is active the panel asks the LiveView to poke it every two
    # seconds. The timer lives in the LiveView, so the tick is an ordinary message.
    test "the poll tick refreshes the progress without a page reload", %{
      conn: conn,
      project: project,
      use_case: use_case,
      run: run
    } do
      {:ok, view, html} = live(conn, evals_path(project, use_case))
      assert html =~ "0 / 6 done"

      tally(run, project, %{scored_count: 4})
      send(view.pid, {:evals_refresh, "evals-panel"})

      assert render(view) =~ "4 / 6 done"
    end

    test "a completed run shows its average, distribution and worst items", %{
      conn: conn,
      project: project,
      use_case: use_case,
      run: run
    } do
      complete_run(run, project)

      {:ok, view, html} = live(conn, evals_path(project, use_case, run: run.id))

      assert html =~ "4.2"
      assert has_element?(view, "#run-#{run.id}-dist")
      assert has_element?(view, "#run-drawer-dist")
      assert has_element?(view, "#run-no-worst")
    end
  end

  # ---------------------------------------------------------------------------
  # §5.7 Continuous evaluation

  describe "the continuous evaluation card" do
    test "is a disabled checkbox naming the plan that has the feature", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, evals_path(project, use_case))

      toggle = view |> element("#continuous-eval-toggle") |> render()
      assert toggle =~ "disabled"
      assert toggle =~ ~s|type="checkbox"|

      assert view |> element("#continuous-eval-badge") |> render() =~ "Pro"
      assert view |> element("#continuous-eval-sub") |> render() =~ "Available on Pro."

      # No dead button: the card holds no clickable control at all.
      refute has_element?(view, "#continuous-eval button")
    end

    test "says Coming soon on the pro plan", %{
      conn: conn,
      project: project,
      use_case: use_case,
      organization: organization
    } do
      Fixtures.set_plan(organization, :pro)

      {:ok, view, _html} = live(conn, evals_path(project, use_case))

      assert view |> element("#continuous-eval-badge") |> render() =~ "Coming soon"

      assert view |> element("#continuous-eval-sub") |> render() =~
               "Not built yet — manual evaluation is available above."
    end
  end

  # ---------------------------------------------------------------------------
  # Access

  describe "access" do
    test "a non-member cannot reach the tab at all", %{project: project, use_case: use_case} do
      stranger = Fixtures.user_fixture()

      assert {:error, {:redirect, %{to: to}}} =
               live(log_in_user(build_conn(), stranger), evals_path(project, use_case))

      assert to == "/personal"
    end
  end

  # ---------------------------------------------------------------------------

  # The counters the batch job's tally freezes onto the run row.
  defp tally(run, project, attrs) do
    {:ok, tallied} =
      run
      |> Ash.Changeset.for_update(
        :record_tally,
        Map.merge(
          %{
            scored_count: 6,
            unparsable_count: 0,
            failed_count: 0,
            average_score: Decimal.new("4.20"),
            score_distribution: %{"1" => 0, "2" => 0, "3" => 1, "4" => 3, "5" => 2},
            cost_usd: Decimal.new("0.01")
          },
          attrs
        ),
        system_opts(project)
      )
      |> Ash.update()

    tallied
  end

  defp complete_run(run, project) do
    {:ok, completed} =
      run
      |> tally(project, %{})
      |> Ash.Changeset.for_update(:complete, %{}, system_opts(project))
      |> Ash.update()

    completed
  end

  defp system_opts(project), do: [tenant: project.id, actor: Fixtures.system_actor()]
end
