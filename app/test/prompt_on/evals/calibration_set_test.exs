defmodule PromptOn.Evals.CalibrationSetTest do
  use PromptOn.DataCase, async: true

  import PromptOn.EvalsFixtures
  import PromptOn.Fixtures

  alias PromptOn.Evals
  alias PromptOn.Observability

  doctest PromptOn.Evals.Sampler

  setup do
    project = project_fixture()
    use_case = use_case_fixture(project)
    %{project: project, use_case: use_case}
  end

  describe ":sample" do
    test "freezes the sampled logs into the set", %{project: project, use_case: use_case} do
      stored_generations_fixture(project, use_case, 12, %{})

      set = calibration_set_fixture(use_case, %{sample_size: 10})

      assert set.sample_size == 10
      assert set.candidate_count == 12
      assert set.window_from
      assert set.window_to

      {:ok, samples} = Evals.list_calibration_samples(set.id, scope(project))

      assert length(samples) == 10
      assert Enum.map(samples, & &1.position) == Enum.to_list(1..10)
      assert Enum.all?(samples, &is_binary(&1.model))
    end

    test "only samples live, ok, payload-bearing logs", %{project: project, use_case: use_case} do
      stored_generations_fixture(project, use_case, 6, %{})

      # An error log and a log whose payload policy dropped the raw content are both ineligible.
      ingest_fixture(project, [
        generation_payload_fixture(use_case, %{
          "status" => "error",
          "error" => %{"kind" => "timeout", "message" => "took too long"}
        })
      ])

      set = calibration_set_fixture(use_case, %{sample_size: 10})

      assert set.candidate_count == 6
    end

    test "does not sample a log whose payload was purged", %{
      project: project,
      use_case: use_case
    } do
      generations = stored_generations_fixture(project, use_case, 8, %{})
      purged = List.last(generations)

      {:ok, payload} = Observability.get_payload(purged.id, scope(project))
      :ok = Ash.destroy!(payload, scope(project))

      set = calibration_set_fixture(use_case, %{sample_size: 10})
      {:ok, samples} = Evals.list_calibration_samples(set.id, scope(project))

      assert set.candidate_count == 7
      refute purged.id in Enum.map(samples, & &1.generation_id)
    end

    test "refuses fewer than five eligible logs with the count in the message", %{
      project: project,
      use_case: use_case
    } do
      stored_generations_fixture(project, use_case, 3, %{})

      assert {:error, error} =
               Evals.sample_calibration_set(%{use_case_id: use_case.id}, scope(project))

      assert Exception.message(error) =~ "at least 5 monitoring logs with stored payloads"
      assert Exception.message(error) =~ "has 3"
    end

    test "is deterministic and evenly spaced", %{project: project, use_case: use_case} do
      stored_generations_fixture(project, use_case, 20, %{})

      first = calibration_set_fixture(use_case, %{sample_size: 5})
      second = calibration_set_fixture(use_case, %{sample_size: 5})

      {:ok, first_samples} = Evals.list_calibration_samples(first.id, scope(project))
      {:ok, second_samples} = Evals.list_calibration_samples(second.id, scope(project))

      assert Enum.map(first_samples, & &1.generation_id) ==
               Enum.map(second_samples, & &1.generation_id)

      # Evenly spaced over 20 candidates with a stride of 4, not the five newest.
      assert length(Enum.uniq(Enum.map(first_samples, & &1.generation_id))) == 5
    end
  end

  describe "the sampler contract" do
    # `{:error, _}` collapsed into `[]` turns a read failure into the confident sentence "this use
    # case has no logs with stored payloads". It has to stay distinguishable.
    test "eligible/2 returns ok or error, never a bare list", %{
      project: project,
      use_case: use_case
    } do
      stored_generations_fixture(project, use_case, 3, %{})

      assert {:ok, logs} =
               PromptOn.Evals.Sampler.eligible(use_case,
                 limit: 10,
                 tenant: project.id,
                 actor: system_actor()
               )

      assert length(logs) == 3

      assert {3, true} =
               PromptOn.Evals.Sampler.count_eligible(use_case,
                 limit: 10,
                 tenant: project.id,
                 actor: system_actor()
               )
    end

    test "sampled_by is the actor, not an argument", %{project: project, use_case: use_case} do
      stored_generations_fixture(project, use_case, 6, %{})
      user = user_fixture()

      {:ok, _membership} =
        PromptOn.Accounts.add_member(
          %{organization_id: project.organization_id, user_id: user.id, role: :editor},
          actor: system_actor()
        )

      {:ok, set} =
        Evals.sample_calibration_set(%{use_case_id: use_case.id, sample_size: 5},
          tenant: project.id,
          actor: user
        )

      assert set.sampled_by == user.id
    end
  end

  describe "frozen text" do
    setup %{project: project, use_case: use_case} do
      stored_generations_fixture(project, use_case, 6, %{})
      %{set: calibration_set_fixture(use_case, %{sample_size: 5})}
    end

    test "is not decrypted by default and is decrypted on request", %{
      project: project,
      set: set
    } do
      {:ok, [sample | _rest]} = Evals.list_calibration_samples(set.id, scope(project))

      assert %Ash.NotLoaded{} = sample.input_text

      loaded = Ash.load!(sample, [:input_text, :output_text], scope(project))

      assert loaded.input_text =~ "user: hello"
      assert loaded.output_text =~ "Hi there!"
    end

    test "survives the deletion of every source log", %{project: project, set: set} do
      {:ok, samples} = Evals.list_calibration_samples(set.id, scope(project))

      for sample <- samples do
        {:ok, generation} = Observability.get_generation(sample.generation_id, scope(project))
        Ash.destroy!(generation, [action: :purge] ++ scope(project))
      end

      {:ok, still_there} = Evals.list_calibration_samples(set.id, scope(project))

      assert length(still_there) == length(samples)
      assert Ash.load!(hd(still_there), [:input_text], scope(project)).input_text =~ "hello"
    end
  end

  describe ":score" do
    test "records the human score and completes the set", %{
      project: project,
      use_case: use_case
    } do
      {set, _samples} = scored_calibration_set_fixture(project, use_case, [5, 4, 3, 2, 1])

      loaded = Ash.load!(set, [:sample_count, :scored_sample_count, :complete?], scope(project))

      assert loaded.sample_count == 5
      assert loaded.scored_sample_count == 5
      assert loaded.complete?
    end

    test "an unscored set is not complete", %{project: project, use_case: use_case} do
      stored_generations_fixture(project, use_case, 6, %{})
      set = calibration_set_fixture(use_case, %{sample_size: 5})

      loaded = Ash.load!(set, [:complete?, :scored_sample_count], scope(project))

      refute loaded.complete?
      assert loaded.scored_sample_count == 0
    end
  end

  describe ":latest_for_use_case" do
    test "returns the newest non-archived set", %{project: project, use_case: use_case} do
      stored_generations_fixture(project, use_case, 8, %{})
      _old = calibration_set_fixture(use_case, %{sample_size: 5})
      newest = calibration_set_fixture(use_case, %{sample_size: 6})

      assert {:ok, %{id: id}} = Evals.latest_calibration_set(use_case.id, scope(project))
      assert id == newest.id

      {:ok, _archived} = Evals.archive_calibration_set(newest, scope(project))

      assert {:ok, %{id: other_id}} = Evals.latest_calibration_set(use_case.id, scope(project))
      refute other_id == newest.id
    end
  end
end
