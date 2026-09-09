defmodule PromptOn.Observability.AIUsageBackfillTest do
  use PromptOn.DataCase, async: true

  import Ecto.Query
  import PromptOn.Fixtures
  import PromptOn.EvalsFixtures

  alias PromptOn.Evals.{CalibrationScore, EvaluationResult, EvaluationRun}
  alias PromptOn.Observability.AIUsage
  alias PromptOn.Repo

  test "recovery snapshots known legacy costs once at their original call times" do
    project = project_fixture()
    provider_key_fixture(organization_id(project))
    select_judge_model(project)
    use_case = use_case_fixture(project)
    target = evaluatable_fixture(project, use_case: use_case)
    run = evaluation_run_fixture(use_case, target.deployment, %{rubric: target.rubric})

    {:ok, %{results: [result | _]}} =
      PromptOn.Evals.list_evaluation_results(run.id, scope(project))

    {set, [sample, failed_sample | _]} = scored_calibration_set_fixture(project, use_case)
    rubric = rubric_fixture(use_case, %{calibration_set_id: set.id})
    score = calibration_score_fixture(rubric, sample, %{cost_usd: Decimal.new("0.5")})
    failed = calibration_score_fixture(rubric, failed_sample, %{cost_usd: Decimal.new("99")})
    called_at = DateTime.add(DateTime.utc_now(), -2, :day)

    Repo.update_all(from(r in EvaluationResult, where: r.id == ^result.id),
      set: [status: :scored, cost_usd: Decimal.new("0.25"), scored_at: called_at]
    )

    Repo.update_all(from(s in CalibrationScore, where: s.id == ^score.id),
      set: [updated_at: called_at]
    )

    # A failed historical rescore can retain the previous cost; its attempt time is unknowable.
    Repo.update_all(from(s in CalibrationScore, where: s.id == ^failed.id),
      set: [status: :failed]
    )

    Repo.update_all(from(r in EvaluationRun, where: r.id == ^run.id),
      set: [cost_usd: Decimal.new("1234")]
    )

    statement =
      AIUsage
      |> AshPostgres.DataLayer.Info.custom_statements()
      |> Enum.find(&(&1.name == :recover_evaluation_usage))

    assert %{num_rows: 2} = Repo.query!(statement.up)
    assert %{num_rows: 0} = Repo.query!(statement.up)

    rows = Ash.read!(AIUsage, scope(project))
    assert length(rows) == 2
    assert MapSet.new(Enum.map(rows, & &1.id)) == MapSet.new([result.id, score.id])
    assert Enum.all?(rows, &(&1.operation == :evaluation and &1.use_case_key == use_case.key))
    assert Enum.all?(rows, &(DateTime.compare(&1.started_at, called_at) == :eq))

    assert Decimal.equal?(
             Enum.reduce(rows, Decimal.new(0), &Decimal.add(&1.cost_usd, &2)),
             "0.75"
           )
  end
end
