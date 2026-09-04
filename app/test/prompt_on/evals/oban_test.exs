defmodule PromptOn.Evals.ObanTest do
  @moduledoc """
  The AshOban wiring of the eval batch (ADR 0010 §3.1). `Oban` is `testing: :manual` in this
  environment, so jobs are inserted but only run when this test drains them.
  """

  use PromptOn.DataCase, async: false

  import PromptOn.EvalsFixtures
  import PromptOn.Fixtures

  alias PromptOn.Evals
  alias PromptOn.Evals.EvaluationResult

  setup do
    on_exit(&PromptOn.LLM.Fake.reset/0)

    project = project_fixture()
    provider_key_fixture(organization_id(project))
    use_case = use_case_fixture(project)
    target = evaluatable_fixture(project, use_case: use_case, count: 12)

    plant_score_answer(4)

    %{project: project, use_case: use_case, target: target}
  end

  defp results(run, project) do
    {:ok, page} = Evals.list_evaluation_results(run.id, scope(project))
    page.results
  end

  test "starting a run enqueues one score job per item", %{project: project, target: target} do
    run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})

    jobs = Oban.Job |> PromptOn.Repo.all() |> Enum.filter(&(&1.queue == "evals"))

    assert length(jobs) == run.item_count
    assert Enum.all?(jobs, &(&1.worker == "PromptOn.Evals.EvaluationResult.Workers.Score"))
    assert Enum.all?(jobs, &(&1.args["tenant"] == project.id))
  end

  test "running one trigger scores one result", %{project: project, target: target} do
    run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})
    [result | _rest] = results(run, project)

    assert {:ok, %{status: :scored}} =
             result |> AshOban.run_trigger(:score, tenant: project.id) |> perform()

    {:ok, scored} = Ash.get(EvaluationResult, result.id, scope(project))
    assert scored.status == :scored
  end

  test "draining the queue finishes and completes the whole run", %{
    project: project,
    target: target
  } do
    run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})

    assert %{success: 12, failure: 0} = Oban.drain_queue(queue: :evals, with_recursion: true)

    {:ok, completed} = Evals.get_evaluation_run(run.id, scope(project))

    assert completed.status == :completed
    assert completed.scored_count == 12
    assert Decimal.equal?(completed.average_score, Decimal.new("4.0"))

    # Draining again does nothing: every result is terminal, so `:scorable` finds none of them.
    assert %{success: 0, failure: 0} = Oban.drain_queue(queue: :evals, with_recursion: true)
  end

  test "the scheduler picks up a pending result whose enqueue was lost", %{
    project: project,
    target: target
  } do
    run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})

    # Simulate the node dying between the commit and the enqueue.
    PromptOn.Repo.delete_all(Oban.Job)

    AshOban.schedule(EvaluationResult, :score)
    Oban.drain_queue(queue: :maintenance, with_recursion: true)

    assert %{success: 12} = Oban.drain_queue(queue: :evals, with_recursion: true)

    {:ok, completed} = Evals.get_evaluation_run(run.id, scope(project))
    assert completed.status == :completed
  end

  test "a cancelled run's outstanding jobs are discarded", %{project: project, target: target} do
    run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})

    {:ok, _cancelled} = Evals.cancel_evaluation(run, scope(project))

    assert %{success: 0, cancelled: 12} = Oban.drain_queue(queue: :evals, with_recursion: true)

    assert Enum.all?(results(run, project), &(&1.status == :pending))
  end

  @tag :capture_log
  test "a permanently failing judge ends the run failed", %{project: project, target: target} do
    run = evaluation_run_fixture(target.use_case, target.deployment, %{rubric: target.rubric})

    PromptOn.LLM.Fake.set_response({:error, {:request_failed, %{reason: :closed}}})

    Oban.drain_queue(queue: :evals, with_recursion: true, with_scheduled: true)

    {:ok, finished} = Evals.get_evaluation_run(run.id, scope(project))

    assert finished.status == :failed
    assert finished.failed_count == 12
    assert Enum.all?(results(run, project), &(&1.status == :failed))
  end

  test ":sweep_stalled_evaluations is a registered scheduled action" do
    assert %{queue: :maintenance} =
             AshOban.Info.oban_scheduled_action(
               PromptOn.Evals.EvaluationRun,
               :sweep_stalled_evaluations
             )
  end

  # `AshOban.run_trigger/3` returns the inserted job; run it in this process.
  defp perform(%Oban.Job{} = job) do
    PromptOn.Evals.EvaluationResult.Workers.Score.perform(job)
  end
end
