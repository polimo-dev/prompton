defmodule PromptOn.Observability.GenerationPayload.Actions.PurgeExpired do
  @moduledoc """
  Implements `GenerationPayload.:purge_expired` (plan.md §9.3 retention). Reads PKs `batch_size`
  at a time through the `:expired` read and deletes them with
  `Ash.bulk_destroy(:destroy, strategy: [:atomic])`. Without a tenant (a manual run) it walks
  every project -- the AshOban schedule creates one job per tenant via
  `PromptOn.Observability.ProjectTenants`.
  Telemetry `[:prompton, :retention, :run]` (`%{deleted: n, duration: ns}`, `%{tenant: id}`).
  """

  use Ash.Resource.Actions.Implementation

  alias PromptOn.Observability.{GenerationPayload, ProjectTenants}

  @impl true
  def run(input, _opts, _context) do
    batch_size = Ash.ActionInput.get_argument(input, :batch_size) || 5_000
    max_batches = Ash.ActionInput.get_argument(input, :max_batches) || 200
    actor = PromptOn.SystemActor.new()

    tenants = if input.tenant, do: [input.tenant], else: ProjectTenants.list_tenants([])

    started = System.monotonic_time()

    deleted =
      Enum.reduce(tenants, 0, fn tenant, acc ->
        acc + purge_tenant(tenant, actor, batch_size, max_batches)
      end)

    :telemetry.execute(
      [:prompton, :retention, :run],
      %{deleted: deleted, duration: System.monotonic_time() - started},
      %{tenant: input.tenant}
    )

    {:ok, %{deleted: deleted}}
  end

  defp purge_tenant(tenant, actor, batch_size, max_batches) do
    Enum.reduce_while(1..max_batches, 0, fn _n, acc ->
      count = purge_batch(tenant, actor, batch_size)
      if count < batch_size, do: {:halt, acc + count}, else: {:cont, acc + count}
    end)
  end

  # Reads batch_size expired PKs and deletes them. Returns the number of rows deleted.
  defp purge_batch(tenant, actor, batch_size) do
    ids =
      GenerationPayload
      |> Ash.Query.for_read(:expired, %{}, tenant: tenant, actor: actor)
      |> Ash.Query.select([:generation_id])
      |> Ash.Query.limit(batch_size)
      |> Ash.read!()
      |> Enum.map(& &1.generation_id)

    destroy_ids!(tenant, actor, ids)
    length(ids)
  end

  @doc false
  def destroy_ids!(_tenant, _actor, []), do: :ok

  def destroy_ids!(tenant, actor, ids) do
    require Ash.Query

    GenerationPayload
    |> Ash.Query.filter(generation_id in ^ids)
    |> Ash.bulk_destroy!(:destroy, %{},
      strategy: [:atomic],
      tenant: tenant,
      actor: actor,
      return_records?: false,
      notify?: false
    )

    :ok
  end
end
