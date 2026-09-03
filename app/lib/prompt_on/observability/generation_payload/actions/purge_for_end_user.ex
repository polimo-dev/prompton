defmodule PromptOn.Observability.GenerationPayload.Actions.PurgeForEndUser do
  @moduledoc """
  Implements `GenerationPayload.:purge_for_end_user` (plan.md §9.7 -- the HeyDiary account-deletion
  hook). Deletes all raw content held by the Generations with that `end_user_ref` (the narrow-table
  rows remain and `payload_state` is untouched -- whether raw content exists is judged through the
  `payload` relationship). Returning the list of promoted DatasetItems is P1.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Ash.Error.Invalid.TenantRequired
  alias PromptOn.Observability.GenerationPayload
  alias PromptOn.Observability.GenerationPayload.Actions.PurgeExpired

  @batch 5_000

  @impl true
  def run(input, _opts, _context) do
    end_user_ref = Ash.ActionInput.get_argument(input, :end_user_ref)
    tenant = input.tenant
    actor = PromptOn.SystemActor.new()

    if is_nil(tenant) do
      {:error, TenantRequired.exception(resource: GenerationPayload)}
    else
      {:ok, %{deleted: purge(tenant, actor, end_user_ref, 0)}}
    end
  end

  defp purge(tenant, actor, end_user_ref, acc) do
    ids =
      GenerationPayload
      |> Ash.Query.filter(generation.end_user_ref == ^end_user_ref)
      |> Ash.Query.select([:generation_id])
      |> Ash.Query.limit(@batch)
      |> Ash.read!(tenant: tenant, actor: actor)
      |> Enum.map(& &1.generation_id)

    case ids do
      [] ->
        acc

      ids ->
        PurgeExpired.destroy_ids!(tenant, actor, ids)
        count = length(ids)
        if count < @batch, do: acc + count, else: purge(tenant, actor, end_user_ref, acc + count)
    end
  end
end
