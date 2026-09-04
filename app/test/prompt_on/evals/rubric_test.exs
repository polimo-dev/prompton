defmodule PromptOn.Evals.RubricTest do
  use PromptOn.DataCase, async: true

  import PromptOn.EvalsFixtures
  import PromptOn.Fixtures

  alias PromptOn.Evals
  alias PromptOn.Evals.RubricCriteria

  setup do
    project = project_fixture()
    %{project: project, use_case: use_case_fixture(project)}
  end

  defp calibration_set_with_logs(project, use_case) do
    stored_generations_fixture(project, use_case, 6)
    calibration_set_fixture(use_case, %{sample_size: 5})
  end

  describe "numbering" do
    test "increments within a use case", %{project: project, use_case: use_case} do
      first = rubric_fixture(use_case)
      second = rubric_fixture(use_case)

      assert first.number == 1
      assert second.number == 2

      assert {:ok, %{number: 2}} = Evals.current_rubric(use_case.id, scope(project))
    end

    test "two use cases number independently", %{project: project} do
      one = use_case_fixture(project)
      other = use_case_fixture(project)

      assert rubric_fixture(one).number == 1
      assert rubric_fixture(other).number == 1
      assert rubric_fixture(one).number == 2
    end
  end

  describe "tenancy and attribution" do
    # Attribute multitenancy does not make a foreign key composite, so the database would happily
    # accept another project's calibration set.
    test "a calibration set of another project is refused", %{use_case: use_case} do
      other_project = project_fixture()
      other_use_case = use_case_fixture(other_project)
      other_set = calibration_set_with_logs(other_project, other_use_case)

      assert {:error, error} =
               Evals.write_rubric(
                 %{
                   use_case_id: use_case.id,
                   calibration_set_id: other_set.id,
                   criteria: default_criteria()
                 },
                 scope(%{id: use_case.project_id})
               )

      assert Exception.message(error) =~ "calibration set not found in this project"
    end

    test "a calibration set of another use case in the same project is refused", %{
      project: project,
      use_case: use_case
    } do
      other_use_case = use_case_fixture(project)
      set = calibration_set_with_logs(project, other_use_case)

      assert {:error, error} =
               Evals.write_rubric(
                 %{
                   use_case_id: use_case.id,
                   calibration_set_id: set.id,
                   criteria: default_criteria()
                 },
                 scope(project)
               )

      assert Exception.message(error) =~ "calibration set belongs to another use case"
    end

    # Attribution is derived from the actor, never accepted: an argument would let any caller name
    # any user, including one outside the organization.
    test "authored_by is the actor, and the system actor writes nil" do
      user = user_fixture()
      project = project_fixture(%{user: user})
      use_case = use_case_fixture(project)

      {:ok, mine} =
        Evals.write_rubric(%{use_case_id: use_case.id, criteria: default_criteria()},
          tenant: project.id,
          actor: user
        )

      {:ok, theirs} =
        Evals.write_rubric(%{use_case_id: use_case.id, criteria: default_criteria()},
          tenant: project.id,
          actor: system_actor()
        )

      assert mine.authored_by == user.id
      assert theirs.authored_by == nil
    end
  end

  describe ":revise" do
    test "copies the use case and calibration set from the source", %{
      project: project,
      use_case: use_case
    } do
      {set, _samples} = scored_calibration_set_fixture(project, use_case, [5, 4, 3, 2, 1])
      source = rubric_fixture(use_case, %{calibration_set_id: set.id})

      {:ok, revised} =
        Evals.revise_rubric(
          source.id,
          %{criteria: %{default_criteria() | summary: "tighter"}, note: "be stricter"},
          scope(project)
        )

      assert revised.use_case_id == use_case.id
      assert revised.calibration_set_id == set.id
      assert revised.number == source.number + 1
      assert revised.source == :ai_revision
      assert revised.note == "be stricter"
    end

    test "inherits the source's judge model unless the caller names one", %{
      project: project,
      use_case: use_case
    } do
      source = rubric_fixture(use_case, %{judge_model: "openai/gpt-4o"})

      {:ok, inherited} =
        Evals.revise_rubric(source.id, %{criteria: default_criteria()}, scope(project))

      {:ok, overridden} =
        Evals.revise_rubric(
          source.id,
          %{criteria: default_criteria(), judge_model: "anthropic/claude-haiku-4"},
          scope(project)
        )

      assert inherited.judge_model == "openai/gpt-4o"
      assert overridden.judge_model == "anthropic/claude-haiku-4"
    end

    test "rejects a source in another tenant", %{project: project} do
      other_project = project_fixture()
      other_rubric = rubric_fixture(use_case_fixture(other_project))

      assert {:error, error} =
               Evals.revise_rubric(
                 other_rubric.id,
                 %{criteria: default_criteria()},
                 scope(project)
               )

      assert Exception.message(error) =~ "source rubric not found in this project"
    end

    test "rejects a source on another use case of the same project", %{
      project: project,
      use_case: use_case
    } do
      other = rubric_fixture(use_case_fixture(project))

      assert {:error, error} =
               Evals.revise_rubric(
                 other.id,
                 %{criteria: default_criteria(), use_case_id: use_case.id},
                 scope(project)
               )

      assert Exception.message(error) =~ "another use case"
    end
  end

  test "there is no update action — a rubric is immutable", %{use_case: use_case} do
    updates =
      PromptOn.Evals.Rubric
      |> Ash.Resource.Info.actions()
      |> Enum.filter(&(&1.type == :update))

    assert updates == []
    assert rubric_fixture(use_case).source == :manual
  end

  describe "agreement aggregates" do
    setup %{project: project, use_case: use_case} do
      {_set, samples} = scored_calibration_set_fixture(project, use_case, [5, 4, 3])
      %{samples: samples, rubric: rubric_fixture(use_case)}
    end

    test "mean absolute error, within one and exact ratios", %{
      project: project,
      rubric: rubric,
      samples: samples
    } do
      [a, b, c] = samples

      calibration_score_fixture(rubric, a, %{score: 5})
      calibration_score_fixture(rubric, b, %{score: 3})
      calibration_score_fixture(rubric, c, %{score: 3})

      loaded =
        Ash.load!(
          rubric,
          [:scored_count, :mean_absolute_error, :within_one_ratio, :exact_ratio],
          scope(project)
        )

      assert loaded.scored_count == 3

      assert Decimal.round(Decimal.new(to_string(loaded.mean_absolute_error)), 2) ==
               Decimal.new("0.33")

      assert loaded.within_one_ratio == 1.0
      assert_in_delta loaded.exact_ratio, 0.67, 0.01
    end

    test "unparsable scores are excluded from every ratio", %{
      project: project,
      rubric: rubric,
      samples: samples
    } do
      [a, b, c] = samples

      calibration_score_fixture(rubric, a, %{score: 5})

      calibration_score_fixture(rubric, b, %{
        status: :unparsable,
        score: nil,
        rationale: nil,
        error_message: "the judge did not answer with JSON"
      })

      calibration_score_fixture(rubric, c, %{status: :failed, score: nil, rationale: nil})

      loaded =
        Ash.load!(
          rubric,
          [:scored_count, :unparsable_count, :within_one_ratio, :exact_ratio],
          scope(project)
        )

      assert loaded.scored_count == 1
      assert loaded.unparsable_count == 2
      assert loaded.within_one_ratio == 1.0
      assert loaded.exact_ratio == 1.0
    end

    test "re-scoring the same sample upserts instead of duplicating", %{
      project: project,
      rubric: rubric,
      samples: [sample | _rest]
    } do
      calibration_score_fixture(rubric, sample, %{score: 2})
      calibration_score_fixture(rubric, sample, %{score: 5})

      {:ok, scores} = Evals.list_calibration_scores(rubric.id, scope(project))

      assert [%{score: 5, absolute_error: 0, within_one?: true}] = scores
    end
  end

  describe "RubricCriteria" do
    test "from_json accepts the judge shape" do
      json = %{
        "summary" => "short answers",
        "must_never" => ["lie"],
        "levels" => %{"1" => "a", "2" => "b", "3" => "c", "4" => "d", "5" => "e"}
      }

      assert {:ok, criteria} = RubricCriteria.from_json(json)
      assert criteria.summary == "short answers"
      assert criteria.must_never == ["lie"]
      assert criteria.level_5 == "e"
      assert RubricCriteria.to_json(criteria) == json
    end

    test "from_json rejects a missing level, a blank summary and a bad must_never" do
      levels = %{"1" => "a", "2" => "b", "3" => "c", "4" => "d", "5" => "e"}

      assert {:error, :invalid_shape} =
               RubricCriteria.from_json(%{
                 "summary" => "s",
                 "levels" => Map.delete(levels, "3")
               })

      assert {:error, :invalid_shape} =
               RubricCriteria.from_json(%{"summary" => "  ", "levels" => levels})

      assert {:error, :invalid_shape} =
               RubricCriteria.from_json(%{
                 "summary" => "s",
                 "must_never" => "lie",
                 "levels" => levels
               })
    end

    # The rubric body goes into the user message of every judge call, so a pasted megabyte would be
    # multiplied by a run's 1,000 items on the organization's own key.
    test "an oversized rubric body is refused", %{project: project, use_case: use_case} do
      criteria = Map.put(default_criteria(), :summary, String.duplicate("x", 2_100))

      assert {:error, error} =
               Evals.write_rubric(
                 %{use_case_id: use_case.id, criteria: criteria},
                 scope(project)
               )

      assert Exception.message(error) =~ "length"
    end

    test "to_prompt caps every field it embeds" do
      {:ok, criteria} =
        RubricCriteria.from_json(%{
          "summary" => String.duplicate("s", 5_000),
          "must_never" => Enum.map(1..40, &"never #{&1}"),
          "levels" => %{"1" => "a", "2" => "b", "3" => "c", "4" => "d", "5" => "e"}
        })

      prompt = RubricCriteria.to_prompt(criteria)

      refute prompt =~ String.duplicate("s", 2_001)
      refute prompt =~ "never 40"
    end

    test "to_prompt omits the must-never block when the list is empty" do
      {:ok, criteria} =
        RubricCriteria.from_json(%{
          "summary" => "s",
          "must_never" => [],
          "levels" => %{"1" => "a", "2" => "b", "3" => "c", "4" => "d", "5" => "e"}
        })

      prompt = RubricCriteria.to_prompt(criteria)

      refute prompt =~ "must never"
      assert prompt =~ "1 = a"
      assert prompt =~ "5 = e"
    end
  end
end
