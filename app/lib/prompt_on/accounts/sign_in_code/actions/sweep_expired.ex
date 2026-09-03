defmodule PromptOn.Accounts.SignInCode.Actions.SweepExpired do
  @moduledoc """
  Implementation of `SignInCode.:sweep_expired`: deletes expired (`expires_at < now`) code rows
  regardless of whether they were consumed.

  The same batch loop as `DeviceAuthorization.Actions.SweepExpired`, but with no credential to
  revoke: a code row holds only a hash. Loops `batch_size` at a time, up to `max_batches` times.
  Telemetry `[:prompton, :sign_in_codes, :sweep]` (`%{deleted:, duration:}`).
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias PromptOn.Accounts.SignInCode

  @impl true
  def run(input, _opts, _context) do
    batch_size = Ash.ActionInput.get_argument(input, :batch_size)
    max_batches = Ash.ActionInput.get_argument(input, :max_batches)
    actor = PromptOn.SystemActor.new()
    started = System.monotonic_time()

    deleted =
      Enum.reduce_while(1..max_batches, 0, fn _n, total ->
        count = sweep_batch(actor, batch_size)
        if count < batch_size, do: {:halt, total + count}, else: {:cont, total + count}
      end)

    result = %{deleted: deleted}

    :telemetry.execute(
      [:prompton, :sign_in_codes, :sweep],
      Map.put(result, :duration, System.monotonic_time() - started),
      %{}
    )

    {:ok, result}
  end

  # Returns the deleted count. Fewer than batch_size means there are no more.
  defp sweep_batch(actor, batch_size) do
    ids =
      SignInCode
      |> Ash.Query.filter(expires_at < ^DateTime.utc_now())
      |> Ash.Query.select([:id])
      |> Ash.Query.sort(expires_at: :asc)
      |> Ash.Query.limit(batch_size)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.id)

    destroy!(ids, actor)
    length(ids)
  end

  defp destroy!([], _actor), do: :ok

  defp destroy!(ids, actor) do
    %Ash.BulkResult{status: :success} =
      SignInCode
      |> Ash.Query.filter(id in ^ids)
      |> Ash.bulk_destroy!(:destroy, %{},
        actor: actor,
        strategy: [:atomic],
        return_errors?: true
      )

    :ok
  end
end
