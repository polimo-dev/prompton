defmodule PromptOn.Evals.ChatOnlyTest do
  use PromptOn.DataCase, async: false

  import PromptOn.Fixtures
  import PromptOn.EvalsFixtures

  alias PromptOn.Evals
  alias PromptOn.Evals.Calibration

  test "retired use cases cannot create evaluations or invoke the judge from existing work" do
    on_exit(&PromptOn.LLM.Fake.reset/0)
    test_pid = self()

    PromptOn.LLM.Fake.set_response(fn _request ->
      send(test_pid, :unexpected_judge_call)
      {:error, :unexpected_judge_call}
    end)

    for {kind, archived_at} <- [
          {"text", nil},
          {"embedding", nil},
          {"chat", ~N[2026-01-01 00:00:00.000000]}
        ] do
      project = project_fixture()
      provider_key_fixture(organization_id(project))
      use_case = use_case_fixture(project)
      target = evaluatable_fixture(project, use_case: use_case, count: 5)
      run = evaluation_run_fixture(use_case, target.deployment, %{rubric: target.rubric})
      {set, _samples} = scored_calibration_set_fixture(project, use_case, [5, 4, 3, 2, 1])
      rubric = %{target.rubric | calibration_set_id: set.id}

      Repo.query!("UPDATE use_cases SET kind = $1, archived_at = $2 WHERE id = $3", [
        kind,
        archived_at,
        Ecto.UUID.dump!(use_case.id)
      ])

      assert {:error, _} =
               Evals.sample_calibration_set(%{use_case_id: use_case.id}, scope(project))

      assert {:error, _} =
               Evals.write_rubric(
                 %{use_case_id: use_case.id, criteria: default_criteria()},
                 scope(project)
               )

      assert {:error, :not_found} = Calibration.draft(set, scope(project))
      assert {:error, :not_found} = Calibration.revise(rubric, scope(project))
      assert {:error, :not_found} = Calibration.score_set(rubric, scope(project))

      {:ok, %{results: results}} = Evals.list_evaluation_results(run.id, scope(project))

      for result <- results do
        scored = result |> Ash.Changeset.for_update(:score, %{}, scope(project)) |> Ash.update!()
        assert scored.status == :failed
        assert scored.error_message =~ "no longer an active chat"
        assert is_nil(scored.score)
      end

      assert {:ok, %{status: :failed, failed_count: 5}} =
               Evals.get_evaluation_run(run.id, scope(project))

      assert {:error, _} =
               Evals.start_evaluation(
                 %{
                   use_case_id: use_case.id,
                   deployment_id: target.deployment.id,
                   environment_id: target.environment.id,
                   rubric_id: rubric.id
                 },
                 scope(project)
               )
    end

    refute_received :unexpected_judge_call
  end
end
