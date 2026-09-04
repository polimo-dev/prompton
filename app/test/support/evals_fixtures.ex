defmodule PromptOn.EvalsFixtures do
  @moduledoc """
  Fixtures for the `PromptOn.Evals` domain (ADR 0010 §7.1).

  They live beside `PromptOn.Fixtures` rather than inside it because the evals area and the
  entitlements area were built in parallel and `test/support/fixtures.ex` has a single owner; every
  function here takes the same shape as the ones there (system actor, returns the record) and
  imports them, so a test can `alias PromptOn.{EvalsFixtures, Fixtures}` and use both.

  The `PromptOn.LLM.Fake` adapter is the judge in tests — `plant_rubric_answer/0` and
  `plant_score_answer/1` set the two answers the judge parser expects.
  """

  import PromptOn.Fixtures,
    only: [
      system_actor: 0,
      scope: 1,
      environment: 2,
      simple_deployment_fixture: 3,
      stored_generations_fixture: 4
    ]

  alias PromptOn.Evals

  @default_criteria %{
    summary: "A good answer restates the request and answers it in the user's language.",
    must_never: ["invent a fact the input does not contain"],
    level_1: "Wrong or empty.",
    level_2: "Mostly wrong.",
    level_3: "Half right.",
    level_4: "Right, with a rough edge.",
    level_5: "Right and complete."
  }

  @doc "The rubric body used by `rubric_fixture/2` when the caller gives none."
  def default_criteria, do: @default_criteria

  @doc """
  Samples a calibration set from the use case's stored logs. The logs must already exist (see
  `PromptOn.Fixtures.stored_generations_fixture/4`). `attrs` accepts `:sample_size` and `:actor`
  (`sampled_by` is derived from the actor).
  """
  def calibration_set_fixture(use_case, attrs \\ %{}) do
    {actor, attrs} = Map.pop(attrs, :actor)

    {:ok, set} =
      Evals.sample_calibration_set(
        Map.merge(%{use_case_id: use_case.id}, attrs),
        tenant: use_case.project_id,
        actor: actor || system_actor()
      )

    set
  end

  @doc """
  One frozen sample written directly through `:capture` (for unit tests that do not want a whole
  sampling round). `attrs` accepts every `:capture` field plus `:user_score`.
  """
  def calibration_sample_fixture(set, attrs \\ %{}) do
    {user_score, attrs} = Map.pop(attrs, :user_score)
    n = System.unique_integer([:positive])

    {:ok, sample} =
      Evals.capture_calibration_sample(
        Map.merge(
          %{
            calibration_set_id: set.id,
            generation_id: Ash.UUIDv7.generate(),
            position: n,
            input_text: "input #{n}",
            output_text: "output #{n}",
            model: "anthropic/claude-sonnet-4",
            started_at: DateTime.utc_now()
          },
          attrs
        ),
        scope(%{id: set.project_id})
      )

    if user_score, do: score_sample(sample, user_score), else: sample
  end

  @doc "Gives one sample its human 1-5 score."
  def score_sample(sample, user_score, attrs \\ %{}) do
    {:ok, scored} =
      Evals.score_calibration_sample(
        sample,
        Map.merge(%{user_score: user_score}, attrs),
        scope(%{id: sample.project_id})
      )

    scored
  end

  @doc """
  A calibration set whose samples all carry a human score. Creates the logs it needs, so the use
  case needs nothing beforehand. Returns `{set, samples}` with the samples in position order.
  """
  def scored_calibration_set_fixture(project, use_case, scores \\ [5, 4, 4, 3, 3, 2, 2, 1, 5, 4]) do
    stored_generations_fixture(project, use_case, max(length(scores), 5), %{})
    set = calibration_set_fixture(use_case, %{sample_size: length(scores)})

    {:ok, samples} = Evals.list_calibration_samples(set.id, scope(project))

    samples =
      samples
      |> Enum.zip(scores)
      |> Enum.map(fn {sample, score} -> score_sample(sample, score) end)

    {set, samples}
  end

  @doc "A hand-written rubric (`:write`, `source :manual`). `attrs` accepts `:criteria`, `:note`."
  def rubric_fixture(use_case, attrs \\ %{}) do
    {:ok, rubric} =
      Evals.write_rubric(
        Map.merge(%{use_case_id: use_case.id, criteria: @default_criteria}, attrs),
        scope(%{id: use_case.project_id})
      )

    rubric
  end

  @doc "One AI score of one sample under one rubric (`:record`, system actor)."
  def calibration_score_fixture(rubric, sample, attrs \\ %{}) do
    {:ok, score} =
      Evals.record_calibration_score(
        Map.merge(
          %{
            rubric_id: rubric.id,
            calibration_sample_id: sample.id,
            status: :ok,
            score: 4,
            rationale: "matches level 4",
            judge_model: "openai/gpt-4o-mini"
          },
          attrs
        ),
        scope(%{id: rubric.project_id})
      )

    score
  end

  @doc """
  Starts an evaluation run over a deployment revision. The use case must already have eligible
  logs for that deployment; `attrs` accepts `:rubric`, `:sample_limit`, `:actor`.
  """
  def evaluation_run_fixture(use_case, deployment, attrs \\ %{}) do
    {rubric, attrs} = Map.pop_lazy(attrs, :rubric, fn -> rubric_fixture(use_case) end)
    {actor, attrs} = Map.pop(attrs, :actor)

    {:ok, run} =
      Evals.start_evaluation(
        Map.merge(
          %{
            use_case_id: use_case.id,
            deployment_id: deployment.id,
            environment_id: deployment.environment_id,
            rubric_id: rubric.id
          },
          attrs
        ),
        tenant: use_case.project_id,
        actor: actor || system_actor()
      )

    run
  end

  @doc """
  A whole evaluation-ready project: a use case with a live deployment, `count` stored logs pinned
  to that revision, and a rubric. Returns
  `%{project:, use_case:, environment:, deployment:, rubric:, generations:}`.
  """
  def evaluatable_fixture(project, opts \\ []) do
    use_case = Keyword.fetch!(opts, :use_case)
    env = environment(project, Keyword.get(opts, :env, "production"))
    deployment = simple_deployment_fixture(use_case, env, %{})

    generations =
      stored_generations_fixture(project, use_case, Keyword.get(opts, :count, 6), %{
        "deployment_id" => deployment.id,
        "deployment_revision" => deployment.revision
      })

    %{
      project: project,
      use_case: use_case,
      environment: env,
      deployment: deployment,
      rubric: rubric_fixture(use_case),
      generations: generations
    }
  end

  # ---------------------------------------------------------------------------
  # Judge answers (`PromptOn.LLM.Fake`)

  @doc "The JSON body of a well-formed rubric answer."
  def rubric_answer_json do
    Jason.encode!(%{
      "summary" => "A good answer is short and answers the question.",
      "must_never" => ["make up a fact"],
      "levels" => %{
        "1" => "No answer.",
        "2" => "Wrong answer.",
        "3" => "Partly right.",
        "4" => "Right but wordy.",
        "5" => "Right and short."
      }
    })
  end

  @doc "Plants a rubric answer on the fake LLM adapter."
  def plant_rubric_answer(json \\ nil) do
    PromptOn.LLM.Fake.set_response(%{content: json || rubric_answer_json()})
  end

  @doc "Plants a score answer on the fake LLM adapter."
  def plant_score_answer(score, rationale \\ "level match") do
    PromptOn.LLM.Fake.set_response(%{
      content: Jason.encode!(%{"score" => score, "rationale" => rationale})
    })
  end

  @doc """
  Plants a judge that answers a rubric to the rubric prompt and `score` to the scoring prompt, so
  one test can run a whole draft-then-score cycle.
  """
  def plant_judge(score \\ 4) do
    rubric_json = rubric_answer_json()
    score_json = Jason.encode!(%{"score" => score, "rationale" => "level #{score}"})

    PromptOn.LLM.Fake.set_response(fn request ->
      content =
        if rubric_request?(request), do: rubric_json, else: score_json

      {:ok, %{PromptOn.LLM.Fake.default_outcome(request) | content: content}}
    end)
  end

  defp rubric_request?(%{messages: [%{content: system} | _rest]}),
    do: String.contains?(system, "evaluation-rubric designer")

  defp rubric_request?(_request), do: false
end
