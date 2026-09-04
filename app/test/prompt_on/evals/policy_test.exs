defmodule PromptOn.Evals.PolicyTest do
  @moduledoc """
  The three actors on all six evals resources (ADR 0010 §2.0): a project member, a non-member, and
  an `ApiKey`. Evals are console-only, so the ApiKey is forbidden everywhere — read included.
  """

  use PromptOn.DataCase, async: false

  import PromptOn.EvalsFixtures
  import PromptOn.Fixtures

  alias PromptOn.Evals

  alias PromptOn.Evals.{
    CalibrationSample,
    CalibrationScore,
    CalibrationSet,
    EvaluationResult,
    EvaluationRun,
    Rubric
  }

  @resources [
    CalibrationSet,
    CalibrationSample,
    Rubric,
    CalibrationScore,
    EvaluationRun,
    EvaluationResult
  ]

  setup do
    on_exit(&PromptOn.LLM.Fake.reset/0)

    user = user_fixture()
    project = project_fixture(%{user: user})
    provider_key_fixture(organization_id(project))
    use_case = use_case_fixture(project)
    target = evaluatable_fixture(project, use_case: use_case, count: 6)

    {set, [sample | _rest]} = scored_calibration_set_fixture(project, use_case, [5, 4, 3, 2, 1])
    calibration_score_fixture(target.rubric, sample)

    plant_score_answer(4)
    run = evaluation_run_fixture(use_case, target.deployment, %{rubric: target.rubric})

    {api_key, _raw} = api_key_fixture(project)

    %{
      user: user,
      outsider: user_fixture(),
      api_key: api_key,
      project: project,
      use_case: use_case,
      target: target,
      set: set,
      sample: sample,
      run: run
    }
  end

  defp read(resource, project, actor) do
    resource
    |> Ash.Query.for_read(:read, %{}, tenant: project.id, actor: actor)
    |> Ash.read()
  end

  test "a member reads every evals resource", ctx do
    for resource <- @resources do
      assert {:ok, rows} = read(resource, ctx.project, ctx.user)
      refute rows == [], "#{inspect(resource)} returned nothing for a member"
    end
  end

  test "a non-member sees nothing", ctx do
    for resource <- @resources do
      assert {:ok, []} = read(resource, ctx.project, ctx.outsider)
    end
  end

  test "an ApiKey sees nothing on read, for every resource", ctx do
    # `forbid_if always()` on a read is folded into the query filter
    # (`config :ash, policies: [no_filter_static_forbidden_reads?: false]`), so it is an empty list
    # rather than an error — the same shape as `PromptOn.Prompts.ArenaMessage`. Not even the key's
    # own project's rows leak.
    for resource <- @resources do
      assert {:ok, []} = read(resource, ctx.project, ctx.api_key)
    end
  end

  test "an ApiKey is forbidden on write", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             Evals.sample_calibration_set(%{use_case_id: ctx.use_case.id},
               tenant: ctx.project.id,
               actor: ctx.api_key
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Evals.write_rubric(
               %{use_case_id: ctx.use_case.id, criteria: default_criteria()},
               tenant: ctx.project.id,
               actor: ctx.api_key
             )
  end

  test "a member may score a calibration sample and archive a set", ctx do
    assert {:ok, %{user_score: 2}} =
             Evals.score_calibration_sample(ctx.sample, %{user_score: 2},
               tenant: ctx.project.id,
               actor: ctx.user
             )

    assert {:ok, _archived} =
             Evals.archive_calibration_set(ctx.set, tenant: ctx.project.id, actor: ctx.user)
  end

  test "the internal-only actions are forbidden for a member", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             Evals.capture_calibration_sample(
               %{
                 calibration_set_id: ctx.set.id,
                 generation_id: Ash.UUIDv7.generate(),
                 position: 99
               },
               tenant: ctx.project.id,
               actor: ctx.user
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Evals.record_calibration_score(
               %{
                 rubric_id: ctx.target.rubric.id,
                 calibration_sample_id: ctx.sample.id,
                 status: :ok,
                 score: 3,
                 judge_model: "openai/gpt-4o-mini"
               },
               tenant: ctx.project.id,
               actor: ctx.user
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Evals.tally_evaluation(ctx.run.id, tenant: ctx.project.id, actor: ctx.user)

    {:ok, page} = Evals.list_evaluation_results(ctx.run.id, scope(ctx.project))

    assert {:error, %Ash.Error.Forbidden{}} =
             page.results
             |> hd()
             |> Ash.Changeset.for_update(:score, %{}, tenant: ctx.project.id, actor: ctx.user)
             |> Ash.update()
  end

  test "a member may cancel a run", ctx do
    assert {:ok, %{status: :cancelled}} =
             Evals.cancel_evaluation(ctx.run, tenant: ctx.project.id, actor: ctx.user)
  end

  test "every resource refuses a call with no tenant", ctx do
    for resource <- @resources do
      assert {:error, %Ash.Error.Invalid{}} =
               resource
               |> Ash.Query.for_read(:read, %{}, actor: ctx.user)
               |> Ash.read()
    end
  end
end
