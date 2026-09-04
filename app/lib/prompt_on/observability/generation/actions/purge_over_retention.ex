defmodule PromptOn.Observability.Generation.Actions.PurgeOverRetention do
  @moduledoc """
  Implements `Generation.:purge_over_retention` (ADR 0010 §3.2) — the **plan** retention rule, a
  sibling of `GenerationPayload.:purge_expired` (the **project storage policy** rule). Both must
  keep running: this one deletes whole log rows and cascades to their payloads; that one deletes
  only expired payloads.

  Two passes per tenant, both driven by `PromptOn.Entitlements`:

  1. **Age** — `received_at < now - log_retention_days`, project-wide. Cheap: it rides the
     `generations_received_at_brin` index.
  2. **Count** — per `use_case_key`, keep the newest `log_count_per_use_case` rows. The cutoff row
     is found with `OFFSET max LIMIT 1` on `received_at desc, id desc`, and everything at or below
     that keyset is deleted.

  Both passes delete in `batch_size` chunks (read PKs, then `Ash.bulk_destroy(:purge, strategy:
  [:atomic])`), the same loop shape as `GenerationPayload.Actions.PurgeExpired`.

  ## Why `received_at` and not `started_at`

  `started_at` is client-supplied. A client sending a timestamp far in the future would make its
  logs immortal, and one with a wrong clock would make them vanish. `received_at` is
  server-authoritative and already carries a BRIN index. The consequence — the log explorer, which
  filters on `started_at`, can show a row slightly outside the retention window near the boundary
  — is accepted.

  A tenant whose plan cannot be resolved (`PromptOn.Entitlements.plan_for_project_result/1` returns
  `:error`) is **skipped and counted**, never purged on a guessed plan — the `:free` fallback is the
  safe direction for a creation gate and the destructive one for an irreversible delete.

  Telemetry `[:prompton, :retention, :generations]`, measurements `%{by_age:, by_count:, skipped:,
  duration:}`, metadata `%{tenant:, plan:, skipped:}`.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias PromptOn.Entitlements
  alias PromptOn.Observability.Generation
  alias PromptOn.Observability.ProjectTenants

  @impl true
  def run(input, _opts, _context) do
    batch_size = Ash.ActionInput.get_argument(input, :batch_size) || 5_000
    max_batches = Ash.ActionInput.get_argument(input, :max_batches) || 200
    actor = PromptOn.SystemActor.new()

    tenants = if input.tenant, do: [input.tenant], else: ProjectTenants.list_tenants([])

    started = System.monotonic_time()

    {by_age, by_count, skipped} =
      Enum.reduce(tenants, {0, 0, 0}, fn tenant, {age_acc, count_acc, skipped_acc} ->
        opts = [tenant: tenant, actor: actor, batch_size: batch_size, max_batches: max_batches]

        # A tenant whose plan cannot be read is **skipped**, never purged on a guessed plan: the
        # `:free` fallback of `plan_for_project/1` would turn a Pro tenant's 90-day window into 7
        # days and delete ~83 days of logs, and there is no undo.
        case Entitlements.plan_for_project_result(tenant) do
          {:ok, plan} ->
            {age_acc + purge_by_age(plan, opts), count_acc + purge_by_count(plan, opts),
             skipped_acc}

          :error ->
            {age_acc, count_acc, skipped_acc + 1}
        end
      end)

    # One tenant per job (the schedule fans out over `ProjectTenants`), so the plan is meaningful
    # in the payload; a manual tenant-less run spans plans and reports none.
    plan =
      case input.tenant && Entitlements.plan_for_project_result(input.tenant) do
        {:ok, plan} -> plan
        _other -> nil
      end

    :telemetry.execute(
      [:prompton, :retention, :generations],
      %{
        by_age: by_age,
        by_count: by_count,
        skipped: skipped,
        duration: System.monotonic_time() - started
      },
      %{tenant: input.tenant, plan: plan, skipped: skipped}
    )

    {:ok, %{by_age: by_age, by_count: by_count, skipped: skipped, plan: plan}}
  end

  # --- Age pass --------------------------------------------------------------

  defp purge_by_age(plan, opts) do
    cutoff =
      DateTime.add(DateTime.utc_now(), -Entitlements.limit(plan, :log_retention_days), :day)

    delete_loop(opts, fn ->
      Generation
      |> Ash.Query.filter(received_at < ^cutoff)
    end)
  end

  # --- Count pass ------------------------------------------------------------

  defp purge_by_count(plan, opts) do
    max = Entitlements.limit(plan, :log_count_per_use_case)

    opts
    |> use_case_keys()
    |> Enum.reduce(0, fn key, acc -> acc + purge_key(key, max, opts) end)
  end

  # Unregistered use case keys are logs too, so the key list comes from the log table itself.
  defp use_case_keys(opts) do
    Generation
    |> Ash.Query.for_read(:read, %{}, tenant: opts[:tenant], actor: opts[:actor])
    |> Ash.Query.distinct([:use_case_key])
    |> Ash.Query.distinct_sort(use_case_key: :asc)
    |> Ash.Query.sort(use_case_key: :asc)
    |> Ash.Query.select([:use_case_key])
    |> Ash.read!()
    |> Enum.map(& &1.use_case_key)
    |> Enum.uniq()
  end

  defp purge_key(key, max, opts) do
    case cutoff_row(key, max, opts) do
      nil ->
        0

      cut ->
        delete_loop(opts, fn ->
          Ash.Query.filter(
            Generation,
            use_case_key == ^key and
              (received_at < ^cut.received_at or
                 (received_at == ^cut.received_at and id <= ^cut.id))
          )
        end)
    end
  end

  # The `max + 1`-th newest row of this key, if there is one: everything at or below its keyset is
  # over the limit.
  defp cutoff_row(key, max, opts) do
    Generation
    |> Ash.Query.for_read(:read, %{}, tenant: opts[:tenant], actor: opts[:actor])
    |> Ash.Query.filter(use_case_key == ^key)
    |> Ash.Query.sort(received_at: :desc, id: :desc)
    |> Ash.Query.offset(max)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  # --- Shared delete loop ----------------------------------------------------

  defp delete_loop(opts, query_fun) do
    batch_size = opts[:batch_size]

    Enum.reduce_while(1..opts[:max_batches], 0, fn _n, acc ->
      count = delete_batch(query_fun.(), opts, batch_size)
      if count < batch_size, do: {:halt, acc + count}, else: {:cont, acc + count}
    end)
  end

  defp delete_batch(query, opts, batch_size) do
    ids =
      query
      |> Ash.Query.select([:id])
      |> Ash.Query.limit(batch_size)
      |> Ash.read!(tenant: opts[:tenant], actor: opts[:actor])
      |> Enum.map(& &1.id)

    destroy_ids!(ids, opts)
    length(ids)
  end

  defp destroy_ids!([], _opts), do: :ok

  defp destroy_ids!(ids, opts) do
    Generation
    |> Ash.Query.filter(id in ^ids)
    |> Ash.bulk_destroy!(:purge, %{},
      strategy: [:atomic],
      tenant: opts[:tenant],
      actor: opts[:actor],
      return_records?: false,
      notify?: false
    )

    :ok
  end
end
