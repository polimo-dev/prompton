defmodule PromptOn.Observability.GenerationRetentionTest do
  @moduledoc """
  `Generation.:purge_over_retention` (ADR 0010 §3.2) — the **plan** retention rule.

  Two passes: age (`received_at` older than `log_retention_days`) and count (beyond the newest
  `log_count_per_use_case` rows of one use case key). Both cascade to `GenerationPayload`, both are
  per tenant, and both leave every other tenant and every other use case key alone.

  The pre-existing payload purge (`GenerationPayload.:purge_expired`, a different unit with a
  different owner) must keep working untouched — the regression is at the bottom of this file.
  """
  use PromptOn.DataCase, async: true

  alias PromptOn.Fixtures
  alias PromptOn.Observability
  alias PromptOn.Observability.Generation
  alias PromptOn.Observability.GenerationPayload

  import PromptOn.Fixtures

  setup do
    user = user_fixture()
    project = project_fixture(%{user: user})
    use_case = use_case_fixture(project, %{key: "diary_generation"})
    %{user: user, project: project, use_case: use_case}
  end

  # `received_at` has no write action (ingest sets it to now), so ageing rows is raw SQL — the same
  # trick `generation_payload_test.exs` uses on `expires_at`.
  defp age!(generations, days) do
    ids = Enum.map(generations, &Ecto.UUID.dump!(&1.id))

    Ecto.Adapters.SQL.query!(
      PromptOn.Repo,
      "UPDATE generations SET received_at = now() - ($1 || ' days')::interval WHERE id = ANY($2)",
      [to_string(days), ids]
    )

    :ok
  end

  defp generation_ids(project) do
    Generation
    |> Ash.Query.for_read(:read, %{}, scope(project))
    |> Ash.Query.sort(received_at: :desc, id: :desc)
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end

  defp payload_count(project) do
    GenerationPayload
    |> Ash.Query.for_read(:read, %{}, scope(project))
    |> Ash.count!()
  end

  defp purge(project, attrs \\ %{}) do
    {:ok, result} = Observability.purge_generations_over_retention(attrs, scope(project))
    result
  end

  describe "age pass" do
    test "free deletes logs older than 7 days, with their payloads", %{
      project: project,
      use_case: use_case
    } do
      old = stored_generations_fixture(project, use_case, 3)
      fresh = stored_generations_fixture(project, use_case, 2)
      :ok = age!(old, 9)

      assert payload_count(project) == 5

      assert %{by_age: 3, by_count: 0, plan: :free} = purge(project)

      kept = generation_ids(project)
      assert Enum.sort(kept) == Enum.sort(Enum.map(fresh, & &1.id))
      # the payloads went with the rows (FK cascade), not just the rows
      assert payload_count(project) == 2

      for generation <- old do
        assert {:ok, nil} = Observability.get_generation(generation.id, scope(project))
        assert {:ok, nil} = Observability.get_payload(generation.id, scope(project))
      end
    end

    test "a row exactly inside the window survives", %{project: project, use_case: use_case} do
      [inside] = stored_generations_fixture(project, use_case, 1)
      :ok = age!([inside], 6)

      assert %{by_age: 0} = purge(project)
      assert generation_ids(project) == [inside.id]
    end

    test "pro keeps 90 days where free would have deleted", %{
      project: project,
      use_case: use_case
    } do
      logs = stored_generations_fixture(project, use_case, 3)
      :ok = age!(logs, 30)

      Fixtures.set_plan(project, :pro)

      assert %{by_age: 0, plan: :pro} = purge(project)
      assert length(generation_ids(project)) == 3

      Fixtures.set_plan(project, :free)

      assert %{by_age: 3, plan: :free} = purge(project)
      assert generation_ids(project) == []
    end
  end

  describe "count pass" do
    test "free keeps the newest 1,000 of a use case key and drops the older ones", %{
      project: project,
      use_case: use_case
    } do
      project = drop_payloads(project)
      other = use_case_fixture(project, %{key: "chat_response"})

      ids = narrow_logs!(project, use_case, 1_050)
      other_ids = narrow_logs!(project, other, 4)

      # `batch_size: 20` forces the delete loop through several batches
      assert %{by_age: 0, by_count: 50} = purge(project, %{batch_size: 20})

      kept = generation_ids(project)
      assert length(kept) == 1_004
      assert Enum.sort(kept -- other_ids) == ids |> Enum.take(-1_000) |> Enum.sort()
      # the 50 oldest are gone
      assert ids |> Enum.take(50) |> Enum.all?(&(&1 not in kept))
      # a second use case key is untouched
      assert Enum.all?(other_ids, &(&1 in kept))
    end

    test "a use case key under the limit is left alone", %{project: project, use_case: use_case} do
      logs = stored_generations_fixture(project, use_case, 4)

      assert %{by_count: 0} = purge(project)
      assert length(generation_ids(project)) == length(logs)
      assert payload_count(project) == 4
    end

    test "team keeps what free would have dropped", %{project: project, use_case: use_case} do
      project = drop_payloads(project)
      ids = narrow_logs!(project, use_case, 1_010)

      Fixtures.set_plan(project, :team)
      assert %{by_count: 0, plan: :team} = purge(project)
      assert length(generation_ids(project)) == 1_010

      Fixtures.set_plan(project, :free)
      assert %{by_count: 10, plan: :free} = purge(project)
      assert Enum.sort(generation_ids(project)) == ids |> Enum.take(-1_000) |> Enum.sort()
    end
  end

  describe "both rules together, and tenant isolation" do
    test "two projects on different plans in one tenant-less run", %{
      project: free_project,
      use_case: free_use_case
    } do
      # a different owner, so the two projects are in different organizations — the plan lives on
      # the organization, not the project
      paid_project = project_fixture(%{slug: "paid"})
      paid_use_case = use_case_fixture(paid_project, %{key: "diary_generation"})

      free_old = stored_generations_fixture(free_project, free_use_case, 2)
      free_fresh = stored_generations_fixture(free_project, free_use_case, 1)
      paid_logs = stored_generations_fixture(paid_project, paid_use_case, 2)

      :ok = age!(free_old, 10)
      :ok = age!(paid_logs, 10)

      Fixtures.set_plan(paid_project, :pro)

      {:ok, result} =
        Observability.purge_generations_over_retention(%{}, actor: Fixtures.system_actor())

      # a tenant-less run spans plans, so it reports none
      assert %{by_age: 2, by_count: 0, plan: nil} = result

      assert generation_ids(free_project) == Enum.map(free_fresh, & &1.id)
      assert length(generation_ids(paid_project)) == 2
    end

    test "a project on team keeps what free would have dropped", %{
      project: project,
      use_case: use_case
    } do
      other_project = project_fixture(%{slug: "other"})
      other_use_case = use_case_fixture(other_project, %{key: "diary_generation"})
      other_logs = stored_generations_fixture(other_project, other_use_case, 2)
      :ok = age!(other_logs, 20)

      logs = stored_generations_fixture(project, use_case, 2)
      :ok = age!(logs, 20)

      Fixtures.set_plan(other_project, :team)

      assert %{by_age: 2} = purge(project)
      assert generation_ids(project) == []

      assert %{by_age: 0, plan: :team} = purge(other_project)
      assert length(generation_ids(other_project)) == 2
    end
  end

  describe "an unreadable plan" do
    # `Entitlements.plan_for_project/1` falls back to `:free`, which is the safe direction for a
    # creation gate and the destructive one here: a Pro tenant would lose ~83 days of logs to a
    # transient read failure, with no undo. The purge skips instead.
    test "a tenant whose plan cannot be read is skipped, not purged on a guess", %{
      project: project,
      use_case: use_case
    } do
      logs = stored_generations_fixture(project, use_case, 2)
      :ok = age!(logs, 3650)

      ghost = Ash.UUIDv7.generate()

      assert {:ok, %{by_age: 0, by_count: 0, skipped: 1, plan: nil}} =
               Observability.purge_generations_over_retention(%{},
                 tenant: ghost,
                 actor: Fixtures.system_actor()
               )

      # the real tenant is untouched by that run, and still purges normally
      assert length(generation_ids(project)) == 2
      assert %{by_age: 2, skipped: 0} = purge(project)
    end
  end

  describe "telemetry and the scheduled action" do
    test "emits [:prompton, :retention, :generations]", %{project: project, use_case: use_case} do
      logs = stored_generations_fixture(project, use_case, 2)
      :ok = age!(logs, 30)

      handler = "retention-generations-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:prompton, :retention, :generations],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert %{by_age: 2} = purge(project)

      assert_receive {:telemetry, %{by_age: 2, by_count: 0, duration: duration},
                      %{tenant: tenant, plan: :free}}

      assert tenant == project.id
      assert is_integer(duration)
    end

    test "the generated Oban worker's own input shape runs", %{
      project: project,
      use_case: use_case
    } do
      logs = stored_generations_fixture(project, use_case, 2)
      :ok = age!(logs, 30)

      # AshOban's worker always adds `last_oban_attempt?` to the input; an action that does not
      # accept it fails every scheduled run with `NoSuchInput`, which calling the code interface
      # directly would never reveal.
      assert {:ok, %{by_age: 2}} =
               Generation
               |> Ash.ActionInput.new()
               |> Ash.ActionInput.set_tenant(project.id)
               |> Ash.ActionInput.for_action(
                 :purge_over_retention,
                 %{last_oban_attempt?: false},
                 actor: Fixtures.system_actor()
               )
               |> Ash.run_action()
    end

    test "the scheduled action is registered on the maintenance queue, after the payload purge" do
      [schedule] = AshOban.Info.oban_scheduled_actions(Generation)

      assert schedule.action == :purge_over_retention
      assert schedule.queue == :maintenance
      assert schedule.cron == "40 3 * * *"
      assert Code.ensure_loaded?(schedule.worker)

      # the payload purge stays where it was, half an hour earlier
      [payload_schedule] = AshOban.Info.oban_scheduled_actions(GenerationPayload)
      assert payload_schedule.cron == "10 3 * * *"
      assert :evals in Keyword.keys(Application.fetch_env!(:prompton, Oban)[:queues])
    end
  end

  describe "policies" do
    test "purging is the system actor's alone", %{
      user: user,
      project: project,
      use_case: use_case
    } do
      [generation] = stored_generations_fixture(project, use_case, 1)
      {api_key, _raw} = api_key_fixture(project)
      stranger = user_fixture()

      for actor <- [user, stranger, api_key] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Ash.destroy(generation, action: :purge, tenant: project.id, actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Observability.purge_generations_over_retention(%{},
                   tenant: project.id,
                   actor: actor
                 )
      end

      assert {:ok, _} = Observability.get_generation(generation.id, scope(project))
    end
  end

  describe "the payload purge is unaffected" do
    test "it still deletes only expired payloads and leaves the log rows", %{
      project: project,
      use_case: use_case
    } do
      [fresh, old] = stored_generations_fixture(project, use_case, 2)

      Ecto.Adapters.SQL.query!(
        PromptOn.Repo,
        "UPDATE generation_payloads SET expires_at = now() - interval '1 day' WHERE generation_id = $1",
        [Ecto.UUID.dump!(old.id)]
      )

      assert {:ok, %{deleted: 1}} = Observability.purge_expired_payloads(%{}, scope(project))

      assert {:ok, nil} = Observability.get_payload(old.id, scope(project))
      assert {:ok, %GenerationPayload{}} = Observability.get_payload(fresh.id, scope(project))
      # the narrow rows are all still there — that is the other job's business
      assert length(generation_ids(project)) == 2
    end
  end

  # The count rule's real boundary is 1,000 rows per use case key, which is only affordable in a
  # test when the rows are narrow: `mode: :none` means ingest writes the log row and no payload.
  # `received_at` is then stamped one second apart so "the newest 1,000" is unambiguous.
  defp drop_payloads(project) do
    {:ok, updated} =
      PromptOn.Projects.set_project_payload_policy(project, %{payload_policy: %{mode: :none}},
        actor: Fixtures.system_actor()
      )

    Ash.load!(updated, [:environments], scope(project))
  end

  defp narrow_logs!(project, use_case, count) do
    payloads =
      for _i <- 1..count,
          do: generation_payload_fixture(use_case, %{"id" => Ash.UUIDv7.generate()})

    payloads
    |> Enum.chunk_every(PromptOn.Observability.Ingest.max_batch())
    |> Enum.each(fn chunk ->
      expected = length(chunk)
      %{accepted: ^expected} = ingest_fixture(project, chunk)
    end)

    ids = Enum.map(payloads, & &1["id"])
    stamp_received_at!(ids)
    ids
  end

  # Oldest first: element i gets `now - (count - i) seconds`.
  defp stamp_received_at!(ids) do
    count = length(ids)

    Ecto.Adapters.SQL.query!(
      PromptOn.Repo,
      """
      UPDATE generations AS g
      SET received_at = now() - ((#{count} - u.position) || ' seconds')::interval
      FROM unnest($1::uuid[]) WITH ORDINALITY AS u(id, position)
      WHERE g.id = u.id
      """,
      [Enum.map(ids, &Ecto.UUID.dump!/1)]
    )

    :ok
  end
end
