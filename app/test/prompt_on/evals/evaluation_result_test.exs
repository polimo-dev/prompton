defmodule PromptOn.Evals.EvaluationResultTest do
  use PromptOn.DataCase, async: false

  import PromptOn.EvalsFixtures
  import PromptOn.Fixtures

  alias PromptOn.Evals
  alias PromptOn.Evals.EvaluationResult
  alias PromptOn.Observability

  setup do
    on_exit(&PromptOn.LLM.Fake.reset/0)

    project = project_fixture()
    provider_key_fixture(organization_id(project))
    use_case = use_case_fixture(project)
    target = evaluatable_fixture(project, use_case: use_case, count: 5)

    plant_score_answer(4)
    run = evaluation_run_fixture(use_case, target.deployment, %{rubric: target.rubric})

    %{project: project, use_case: use_case, target: target, run: run}
  end

  defp results(run, project) do
    {:ok, page} = Evals.list_evaluation_results(run.id, scope(project))
    page.results
  end

  defp score!(result, project) do
    result
    |> Ash.Changeset.for_update(:score, %{}, scope(project))
    |> Ash.update!()
  end

  describe ":score" do
    test "writes the score, the encrypted rationale, tokens and cost", %{
      project: project,
      run: run
    } do
      plant_score_answer(5, "the answer names level 5")

      scored = run |> results(project) |> hd() |> score!(project)

      assert scored.status == :scored
      assert scored.score == 5
      assert scored.judge_model
      assert scored.latency_ms
      assert scored.input_tokens
      assert scored.output_tokens
      assert scored.scored_at
      assert %Ash.NotLoaded{} = scored.rationale

      loaded = Ash.load!(scored, [:rationale], scope(project))
      assert loaded.rationale == "the answer names level 5"
    end

    test "flips the run to running on the first result", %{project: project, run: run} do
      run |> results(project) |> hd() |> score!(project)

      {:ok, reloaded} = Evals.get_evaluation_run(run.id, scope(project))

      assert reloaded.status == :running
      assert reloaded.started_at
      assert reloaded.scored_count == 1
    end

    test "a purged payload is a terminal failure, not a retry", %{project: project, run: run} do
      [result | _rest] = results(run, project)
      {:ok, payload} = Observability.get_payload(result.generation_id, scope(project))
      Ash.destroy!(payload, scope(project))

      failed = score!(result, project)

      assert failed.status == :failed
      assert failed.error_message == "payload no longer stored"
      assert is_nil(failed.score)
    end

    test "an unparsable answer is excluded from the average", %{project: project, run: run} do
      [first, second | _rest] = results(run, project)

      plant_score_answer(2)
      score!(first, project)

      PromptOn.LLM.Fake.set_response(%{content: "I would say a three."})
      unparsable = score!(second, project)

      assert unparsable.status == :unparsable
      assert is_nil(unparsable.score)
      assert unparsable.error_message =~ "did not answer with JSON"

      {:ok, tallied} = Evals.get_evaluation_run(run.id, scope(project))

      assert tallied.scored_count == 1
      assert tallied.unparsable_count == 1
      assert Decimal.equal?(tallied.average_score, Decimal.new("2.0"))
    end

    test "a revoked provider key is terminal too", %{project: project, run: run} do
      PromptOn.LLM.Fake.set_response({:error, :no_provider_key})

      failed = run |> results(project) |> hd() |> score!(project)

      assert failed.status == :failed
      assert failed.error_message == "no provider key"
    end

    test "a transport failure is a changeset error, so AshOban retries", %{
      project: project,
      run: run
    } do
      PromptOn.LLM.Fake.set_response({:error, {:request_failed, %{reason: :closed}}})

      [result | _rest] = results(run, project)

      assert {:error, error} =
               result
               |> Ash.Changeset.for_update(:score, %{}, scope(project))
               |> Ash.update()

      assert Exception.message(error) =~ "judge call failed: request failed"

      {:ok, unchanged} = Ash.get(EvaluationResult, result.id, scope(project))
      assert unchanged.status == :pending
    end
  end

  describe ":mark_failed" do
    test "records the failure and tallies", %{project: project, run: run} do
      [result | _rest] = results(run, project)

      marked =
        result
        |> Ash.Changeset.for_update(:mark_failed, %{error: :evaluation_timed_out}, scope(project))
        |> Ash.update!()

      assert marked.status == :failed
      assert marked.error_message == "evaluation timed out"

      {:ok, tallied} = Evals.get_evaluation_run(run.id, scope(project))
      assert tallied.failed_count == 1
    end

    test "never carries a provider error body into the message", %{project: project, run: run} do
      [result | _rest] = results(run, project)

      marked =
        result
        |> Ash.Changeset.for_update(
          :mark_failed,
          %{error: "upstream said: the user asked about SECRET"},
          scope(project)
        )
        |> Ash.update!()

      assert marked.error_message == "the judge job failed"
      refute marked.error_message =~ "SECRET"
      assert String.length(marked.error_message) <= 500
    end

    test "reduces a provider failure tuple to its shape", %{project: project, run: run} do
      [result | _rest] = results(run, project)

      marked =
        result
        |> Ash.Changeset.for_update(
          :mark_failed,
          %{error: {:http_error, 429, ~s({"error":"SECRET quoted back"}), []}},
          scope(project)
        )
        |> Ash.update!()

      assert marked.error_message == "HTTP 429"
    end

    # `Exception.message/1` of an Ash error class starts with a blank line; the first *non-blank*
    # line is the reason, and an empty string would be cast to nil and record nothing at all.
    test "records an informative reason for a real Ash error", %{project: project, run: run} do
      [result | _rest] = results(run, project)

      error =
        Ash.Error.to_error_class(
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :status,
            message: "judge call failed: HTTP 500"
          )
        )

      marked =
        result
        |> Ash.Changeset.for_update(:mark_failed, %{error: error}, scope(project))
        |> Ash.update!()

      assert is_binary(marked.error_message)
      assert String.trim(marked.error_message) != ""
      assert marked.error_message =~ "judge call failed"
    end
  end

  describe ":scorable" do
    test "excludes results that are done and results of a cancelled run", %{
      project: project,
      run: run
    } do
      [first | _rest] = results(run, project)
      score!(first, project)

      {:ok, scorable} =
        EvaluationResult |> Ash.Query.for_read(:scorable, %{}, scope(project)) |> Ash.read()

      assert length(scorable) == 4

      {:ok, _cancelled} = Evals.cancel_evaluation(run, scope(project))

      {:ok, after_cancel} =
        EvaluationResult |> Ash.Query.for_read(:scorable, %{}, scope(project)) |> Ash.read()

      assert after_cancel == []
    end
  end

  describe ":worst_for_run" do
    test "shows the failures first", %{project: project, run: run} do
      [a, b, c, d, _e] = results(run, project)

      plant_score_answer(1)
      score!(a, project)
      plant_score_answer(2)
      score!(b, project)
      plant_score_answer(5)
      score!(c, project)
      plant_score_answer(4)
      score!(d, project)

      {:ok, worst} = Evals.worst_evaluation_results(run.id, scope(project))

      assert Enum.map(worst, & &1.score) == [1, 2]
    end
  end

  test "the same generation cannot be enqueued twice in one run", %{project: project, run: run} do
    [result | _rest] = results(run, project)

    assert {:error, error} =
             Ash.create(
               EvaluationResult,
               %{
                 evaluation_run_id: run.id,
                 generation_id: result.generation_id,
                 position: 99
               },
               [action: :enqueue] ++ scope(project)
             )

    assert Exception.message(error) =~ "already been taken" or
             Exception.message(error) =~ "unique"
  end
end
