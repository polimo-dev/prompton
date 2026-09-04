defmodule PromptOn.Evals.CalibrationTest do
  @moduledoc """
  The draft → agreement → revise loop of ADR 0010 §1, steps 3 to 5.
  """

  use PromptOn.DataCase, async: false

  import PromptOn.EvalsFixtures
  import PromptOn.Fixtures

  alias PromptOn.Evals
  alias PromptOn.Evals.Calibration

  setup do
    on_exit(&PromptOn.LLM.Fake.reset/0)

    project = project_fixture()
    provider_key_fixture(organization_id(project))
    use_case = use_case_fixture(project)
    {set, samples} = scored_calibration_set_fixture(project, use_case, [5, 4, 3, 2, 1])

    %{project: project, use_case: use_case, set: set, samples: samples}
  end

  describe "draft/2" do
    test "writes rubric #1 and scores the set with it", %{project: project, set: set} do
      plant_judge(4)

      assert {:ok, rubric} = Calibration.draft(set, scope(project))

      assert rubric.number == 1
      assert rubric.source == :ai_draft
      assert rubric.calibration_set_id == set.id
      assert rubric.criteria.summary == "A good answer is short and answers the question."

      {:ok, scores} = Evals.list_calibration_scores(rubric.id, scope(project))

      assert length(scores) == 5
      assert Enum.all?(scores, &(&1.status == :ok and &1.score == 4))
      assert Enum.map(scores, & &1.absolute_error) |> Enum.sort() == [0, 1, 1, 2, 3]
    end

    test "the agreement aggregates follow from the scores", %{project: project, set: set} do
      plant_judge(4)

      {:ok, rubric} = Calibration.draft(set, scope(project))

      loaded =
        Ash.load!(
          rubric,
          [:scored_count, :mean_absolute_error, :within_one_ratio, :exact_ratio],
          scope(project)
        )

      assert loaded.scored_count == 5
      # |4-5| + |4-4| + |4-3| + |4-2| + |4-1| = 1 + 0 + 1 + 2 + 3 = 7 over 5 samples
      assert Decimal.equal?(
               Decimal.new(to_string(loaded.mean_absolute_error)),
               Decimal.new("1.4")
             )

      assert_in_delta loaded.within_one_ratio, 0.6, 0.001
      assert_in_delta loaded.exact_ratio, 0.2, 0.001
    end

    test "an unparsable judge answer is recorded and excluded", %{project: project, set: set} do
      PromptOn.LLM.Fake.set_response(fn request ->
        rubric? =
          request.messages |> hd() |> Map.get(:content) |> String.contains?("rubric designer")

        content = if rubric?, do: rubric_answer_json(), else: "about a four I'd say"

        {:ok, %{PromptOn.LLM.Fake.default_outcome(request) | content: content}}
      end)

      {:ok, rubric} = Calibration.draft(set, scope(project))
      {:ok, scores} = Evals.list_calibration_scores(rubric.id, scope(project))

      assert Enum.all?(scores, &(&1.status == :unparsable))
      assert Enum.all?(scores, &(&1.error_message == "the judge did not answer with JSON"))

      # `error_message` is not encrypted, and a judge that ignored "JSON only" is exactly the one
      # that echoes the input back — so the raw answer is never stored.
      refute Enum.any?(scores, &(&1.error_message =~ "about a four"))

      loaded = Ash.load!(rubric, [:scored_count, :unparsable_count], scope(project))

      assert loaded.scored_count == 0
      assert loaded.unparsable_count == 5
    end

    test "a provider failure is recorded as a shape, never as a body", %{
      project: project,
      set: set
    } do
      PromptOn.LLM.Fake.set_response(fn request ->
        rubric? =
          request.messages |> hd() |> Map.get(:content) |> String.contains?("rubric designer")

        if rubric? do
          {:ok, %{PromptOn.LLM.Fake.default_outcome(request) | content: rubric_answer_json()}}
        else
          {:error, {:http_error, 429, ~s({"error":"the user asked about SECRET"}), []}}
        end
      end)

      {:ok, rubric} = Calibration.draft(set, scope(project))
      {:ok, scores} = Evals.list_calibration_scores(rubric.id, scope(project))

      assert Enum.all?(scores, &(&1.status == :failed))
      assert Enum.all?(scores, &(&1.error_message == "HTTP 429"))
      refute Enum.any?(scores, &(&1.error_message =~ "SECRET"))
    end

    test "a judge failure is passed back to the caller", %{project: project, set: set} do
      PromptOn.LLM.Fake.set_response({:error, :no_provider_key})

      assert {:error, :no_provider_key} = Calibration.draft(set, scope(project))
      assert {:ok, nil} = Evals.current_rubric(set.use_case_id, scope(project))
    end
  end

  describe "revise/2" do
    test "makes a new numbered version carrying the note", %{project: project, set: set} do
      plant_judge(4)
      {:ok, first} = Calibration.draft(set, scope(project))

      assert {:ok, second} =
               Calibration.revise(first, Keyword.put(scope(project), :note, "be harsher"))

      assert second.number == 2
      assert second.source == :ai_revision
      assert second.note == "be harsher"
      assert second.calibration_set_id == set.id

      {:ok, scores} = Evals.list_calibration_scores(second.id, scope(project))
      assert length(scores) == 5
    end

    test "refuses a rubric with no calibration set", %{project: project, use_case: use_case} do
      hand_written = rubric_fixture(use_case)

      assert {:error, :no_calibration_set} = Calibration.revise(hand_written, scope(project))
    end
  end

  describe "score_set/2" do
    test "re-scoring upserts rather than duplicating", %{project: project, set: set} do
      plant_judge(4)
      {:ok, rubric} = Calibration.draft(set, scope(project))

      plant_score_answer(2)
      assert {:ok, %{scored: 5}} = Calibration.score_set(rubric, scope(project))

      {:ok, scores} = Evals.list_calibration_scores(rubric.id, scope(project))

      assert length(scores) == 5
      assert Enum.all?(scores, &(&1.score == 2))
    end

    test "ignores samples the human has not scored", %{
      project: project,
      use_case: use_case
    } do
      stored_generations_fixture(project, use_case, 8, %{})
      set = calibration_set_fixture(use_case, %{sample_size: 6})
      {:ok, [first, second | _rest]} = Evals.list_calibration_samples(set.id, scope(project))

      score_sample(first, 5)
      score_sample(second, 1)

      rubric = rubric_fixture(use_case, %{calibration_set_id: set.id})
      plant_score_answer(3)

      assert {:ok, %{scored: 2}} = Calibration.score_set(rubric, scope(project))
    end
  end
end
