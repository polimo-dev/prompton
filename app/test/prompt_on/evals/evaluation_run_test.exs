defmodule PromptOn.Evals.EvaluationRunTest do
  use PromptOn.DataCase, async: false

  import PromptOn.EvalsFixtures
  import PromptOn.Fixtures

  alias PromptOn.Evals

  setup do
    on_exit(&PromptOn.LLM.Fake.reset/0)

    project = project_fixture()
    provider_key_fixture(organization_id(project))
    use_case = use_case_fixture(project)

    %{
      project: project,
      use_case: use_case,
      target: evaluatable_fixture(project, use_case: use_case)
    }
  end

  describe ":start" do
    test "creates the run and one pending result per eligible log", %{
      project: project,
      target: target
    } do
      run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})

      assert run.status == :queued
      assert run.item_count == 6
      assert run.deployment_revision == target.deployment.revision
      assert run.rubric_number == target.rubric.number
      assert run.judge_model == "openai/gpt-4o-mini"
      assert run.window_from
      assert run.window_to

      {:ok, page} = Evals.list_evaluation_results(run.id, scope(project))

      assert length(page.results) == 6
      assert Enum.all?(page.results, &(&1.status == :pending))
      assert Enum.map(page.results, & &1.position) == Enum.to_list(1..6)
    end

    test "a validation failure creates neither the run nor any result", %{
      project: project,
      use_case: use_case,
      target: target
    } do
      other_use_case = use_case_fixture(project)
      other_rubric = rubric_fixture(other_use_case)

      assert {:error, error} =
               Evals.start_evaluation(
                 %{
                   use_case_id: use_case.id,
                   deployment_id: target.deployment.id,
                   environment_id: target.environment.id,
                   rubric_id: other_rubric.id
                 },
                 scope(project)
               )

      assert Exception.message(error) =~ "rubric belongs to another use case"
      assert {:ok, %{results: []}} = Evals.list_evaluation_runs(use_case.id, scope(project))
    end

    test "refuses a second active run for the same revision", %{project: project, target: target} do
      _first =
        evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})

      assert {:error, error} =
               Evals.start_evaluation(
                 %{
                   use_case_id: target.use_case.id,
                   deployment_id: target.deployment.id,
                   environment_id: target.environment.id,
                   rubric_id: target.rubric.id
                 },
                 scope(project)
               )

      assert Exception.message(error) =~ "is already running"
    end

    # `NoActiveRun` runs while the changeset is built — outside the transaction and without a lock —
    # so two tabs or two nodes can both read nil. The partial unique index is the guard, and it is
    # tested by going around Ash entirely.
    test "the database refuses a second active run for one revision", %{
      project: project,
      target: target
    } do
      run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})

      columns =
        ~w(project_id use_case_id deployment_id environment_id rubric_id status
           deployment_revision rubric_number judge_model sample_limit item_count
           scored_count unparsable_count failed_count score_distribution inserted_at)

      sql = """
      INSERT INTO evaluation_runs (id, #{Enum.join(columns, ", ")})
      SELECT $2, #{Enum.join(columns, ", ")} FROM evaluation_runs WHERE id = $1
      """

      assert_raise Postgrex.Error, ~r/one_active_run_per_deployment/, fn ->
        PromptOn.Repo.query!(sql, [
          Ecto.UUID.dump!(run.id),
          Ecto.UUID.dump!(Ash.UUID.generate())
        ])
      end

      # a finished run is not in the way — the same revision may be measured again
      {:ok, _cancelled} = Evals.cancel_evaluation(run, scope(project))

      assert {:ok, _second} =
               PromptOn.Repo.query(sql, [
                 Ecto.UUID.dump!(run.id),
                 Ecto.UUID.dump!(Ash.UUID.generate())
               ])
    end

    # The ceiling is `Entitlements.limit(plan, :evaluation_sample_limit)`, applied by the clamp — a
    # hard-coded attribute `max` would refuse the one change the entitlement exists to make cheap.
    test "a sample_limit above the plan ceiling is clamped, not refused", %{
      project: project,
      target: target
    } do
      assert {:ok, run} =
               Evals.start_evaluation(
                 %{
                   use_case_id: target.use_case.id,
                   deployment_id: target.deployment.id,
                   environment_id: target.environment.id,
                   rubric_id: target.rubric.id,
                   sample_limit: 5_000
                 },
                 scope(project)
               )

      assert run.sample_limit ==
               PromptOn.Entitlements.limit(:free, :evaluation_sample_limit)
    end

    test "requested_by is the actor, not an argument", %{project: project, target: target} do
      user = user_fixture()

      {:ok, membership} =
        PromptOn.Accounts.add_member(
          %{organization_id: project.organization_id, user_id: user.id, role: :editor},
          actor: system_actor()
        )

      assert membership.user_id == user.id

      {:ok, run} =
        Evals.start_evaluation(
          %{
            use_case_id: target.use_case.id,
            deployment_id: target.deployment.id,
            environment_id: target.environment.id,
            rubric_id: target.rubric.id
          },
          tenant: project.id,
          actor: user
        )

      assert run.requested_by == user.id
    end

    test "refuses a deployment from another tenant", %{project: project, target: target} do
      other_project = project_fixture()
      other_use_case = use_case_fixture(other_project)
      other = evaluatable_fixture(other_project, use_case: other_use_case)

      assert {:error, error} =
               Evals.start_evaluation(
                 %{
                   use_case_id: target.use_case.id,
                   deployment_id: other.deployment.id,
                   environment_id: target.environment.id,
                   rubric_id: target.rubric.id
                 },
                 scope(project)
               )

      assert Exception.message(error) =~ "deployment not found in this project"
    end

    test "refuses a revision with no eligible logs", %{project: project, use_case: use_case} do
      env = environment(project, "staging")
      deployment = simple_deployment_fixture(use_case, env, %{})
      rubric = rubric_fixture(use_case)

      assert {:error, error} =
               Evals.start_evaluation(
                 %{
                   use_case_id: use_case.id,
                   deployment_id: deployment.id,
                   environment_id: env.id,
                   rubric_id: rubric.id
                 },
                 scope(project)
               )

      assert Exception.message(error) =~ "no monitoring logs with stored log content in staging"
    end

    test "refuses to start without a provider key", %{project: project} do
      keyless = project_fixture()
      use_case = use_case_fixture(keyless)
      target = evaluatable_fixture(keyless, use_case: use_case)

      refute project.id == keyless.id

      assert {:error, error} =
               Evals.start_evaluation(
                 %{
                   use_case_id: use_case.id,
                   deployment_id: target.deployment.id,
                   environment_id: target.environment.id,
                   rubric_id: target.rubric.id
                 },
                 scope(keyless)
               )

      assert Exception.message(error) =~ "no provider key"
      assert Exception.message(error) =~ "Organization settings"
    end

    test "clamps sample_limit to the plan entitlement", %{target: target} do
      run =
        evaluation_run_fixture(target.use_case, target.deployment, %{
          rubric: target.rubric,
          sample_limit: 1_000
        })

      assert run.sample_limit ==
               min(
                 1_000,
                 PromptOn.Entitlements.limit(:free, :evaluation_sample_limit)
               )
    end
  end

  describe ":tally" do
    setup %{target: target} do
      %{run: evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})}
    end

    test "freezes the counters and completes when nothing is pending", %{
      project: project,
      run: run
    } do
      plant_score_answer(4)
      drain_results(run, project)

      assert {:ok, %{status: :completed, pending: 0}} =
               Evals.tally_evaluation(run.id, scope(project))

      {:ok, tallied} = Evals.get_evaluation_run(run.id, scope(project))

      assert tallied.status == :completed
      assert tallied.scored_count == 6
      assert tallied.unparsable_count == 0
      assert tallied.failed_count == 0
      assert Decimal.equal?(tallied.average_score, Decimal.new("4.0"))
      assert tallied.score_distribution == %{"1" => 0, "2" => 0, "3" => 0, "4" => 6, "5" => 0}
      assert tallied.finished_at
    end

    test "a second tally is a no-op", %{project: project, run: run} do
      plant_score_answer(5)
      drain_results(run, project)

      {:ok, _first} = Evals.tally_evaluation(run.id, scope(project))
      {:ok, before} = Evals.get_evaluation_run(run.id, scope(project))

      assert {:ok, %{status: :completed}} = Evals.tally_evaluation(run.id, scope(project))
      {:ok, after_second} = Evals.get_evaluation_run(run.id, scope(project))

      assert after_second.finished_at == before.finished_at
      assert after_second.scored_count == before.scored_count
    end

    test "a run with zero scored results ends failed", %{project: project, run: run} do
      PromptOn.LLM.Fake.set_response(%{content: "not json at all"})
      drain_results(run, project)

      {:ok, failed} = Evals.get_evaluation_run(run.id, scope(project))

      assert failed.status == :failed
      assert failed.unparsable_count == 6
      assert failed.error_message =~ "every item failed"
      assert is_nil(failed.average_score)
    end
  end

  describe ":cancel" do
    test "stops the run and makes its results unscorable", %{project: project, target: target} do
      run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})

      {:ok, cancelled} = Evals.cancel_evaluation(run, scope(project))

      assert cancelled.status == :cancelled
      assert cancelled.finished_at

      {:ok, scorable} =
        PromptOn.Evals.EvaluationResult
        |> Ash.Query.for_read(:scorable, %{}, scope(project))
        |> Ash.read()

      assert scorable == []

      {:ok, page} = Evals.list_evaluation_results(run.id, scope(project))
      assert Enum.all?(page.results, &(&1.status == :pending))
    end
  end

  describe ":latest_for_deployments" do
    test "returns the newest completed run per revision and nothing for an unevaluated one", %{
      project: project,
      target: target
    } do
      run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})
      plant_score_answer(3)
      drain_results(run, project)
      {:ok, _tally} = Evals.tally_evaluation(run.id, scope(project))

      other_use_case = use_case_fixture(project)
      other = evaluatable_fixture(project, use_case: other_use_case)

      scores =
        Evals.scores_for_deployments(
          [target.deployment.id, other.deployment.id],
          scope(project)
        )

      assert Map.has_key?(scores, target.deployment.id)
      refute Map.has_key?(scores, other.deployment.id)
      assert Decimal.equal?(scores[target.deployment.id].average_score, Decimal.new("3.0"))
    end

    test "an empty id list needs no query", %{project: project} do
      assert Evals.scores_for_deployments([], scope(project)) == %{}
    end
  end

  describe ":sweep_stalled" do
    test "finalizes a run whose tally was lost", %{project: project, target: target} do
      run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})
      plant_score_answer(4)
      drain_results(run, project, leave_last: true)

      # Simulate a node that died between writing the last result and tallying its run: the row is
      # terminal, but the run is still `:running` with nothing pending.
      {:ok, %{results: [last | _rest]}} =
        Evals.list_evaluation_results(run.id, %{status: :pending}, scope(project))

      {1, _} =
        Repo.update_all(
          from(r in "evaluation_results", where: r.id == type(^last.id, :binary_id)),
          set: [status: "scored", score: 4]
        )

      {:ok, %{finalized: 1}} = Evals.sweep_stalled_evaluations(scope(project))

      {:ok, swept} = Evals.get_evaluation_run(run.id, scope(project))
      assert swept.status == :completed
      assert swept.scored_count == 6
    end

    test "fails a run that has been going too long", %{project: project, target: target} do
      run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})
      backdate(run, hours: 3)

      {:ok, %{failed: 1}} = Evals.sweep_stalled_evaluations(scope(project))

      {:ok, swept} = Evals.get_evaluation_run(run.id, scope(project))

      assert swept.status == :failed
      assert swept.error_message =~ "evaluation timed out"

      {:ok, page} = Evals.list_evaluation_results(run.id, scope(project))
      assert Enum.all?(page.results, &(&1.status == :failed))

      # The results are failed with `tally?: false` and the run is tallied **once** at the end;
      # the frozen counters must still be right.
      assert swept.failed_count == run.item_count
      assert swept.scored_count == 0
      assert swept.average_score == nil
    end
  end

  # Pushes a run's clock back, so the stall sweeper sees it as old.
  defp backdate(run, hours: hours) do
    at = DateTime.add(DateTime.utc_now(), -hours * 3_600, :second)

    {1, _} =
      Repo.update_all(
        from(r in "evaluation_runs", where: r.id == type(^run.id, :binary_id)),
        set: [inserted_at: at, started_at: at]
      )

    :ok
  end

  # Scores every pending result of a run in place (the worker action, without Oban).
  # `leave_last: true` stops one short, for the tests that need a run that is still `:running`.
  defp drain_results(run, project, opts \\ []) do
    {:ok, page} = Evals.list_evaluation_results(run.id, scope(project))
    pending = Enum.filter(page.results, &(&1.status == :pending))

    pending =
      if Keyword.get(opts, :leave_last, false), do: Enum.drop(pending, -1), else: pending

    for result <- pending do
      result
      |> Ash.Changeset.for_update(:score, %{}, scope(project))
      |> Ash.update!()
    end

    :ok
  end
end
