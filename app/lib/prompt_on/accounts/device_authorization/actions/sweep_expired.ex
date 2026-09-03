defmodule PromptOn.Accounts.DeviceAuthorization.Actions.SweepExpired do
  @moduledoc """
  Implementation of `DeviceAuthorization.:sweep_expired`: deletes expired (`expires_at < now`)
  requests regardless of status.

  One thing is checked before deleting: a row that expired while `approved` holds, encrypted, a
  **CLI session token** the CLI never managed to fetch. That token is a live credential with no
  expiry, so rather than letting it vanish with the row we revoke it first
  (`PromptOn.Accounts.CliSession.revoke/1`). If it cannot be decrypted or the revocation fails,
  the row is **kept** and the next run retries; once deleted it can never be touched again.

  Kept rows are not re-read within the same run (`id not in kept`); otherwise, when the few oldest
  rows are stuck, every batch would read the same rows and the expired rows behind them would
  never be swept.

  Loops `batch_size` at a time, up to `max_batches` times. Telemetry
  `[:prompton, :device_authorizations, :sweep]` (`%{deleted:, revoked:, kept:, duration:}`).
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query
  require Logger

  alias PromptOn.Accounts.CliSession
  alias PromptOn.Accounts.DeviceAuthorization

  @impl true
  def run(input, _opts, _context) do
    batch_size = Ash.ActionInput.get_argument(input, :batch_size)
    max_batches = Ash.ActionInput.get_argument(input, :max_batches)
    actor = PromptOn.SystemActor.new()
    started = System.monotonic_time()

    {deleted, revoked, kept} =
      Enum.reduce_while(1..max_batches, {0, 0, []}, fn _n, {d, r, kept} ->
        {count, batch_deleted, batch_revoked, batch_kept} = sweep_batch(actor, batch_size, kept)
        acc = {d + batch_deleted, r + batch_revoked, batch_kept ++ kept}
        if count < batch_size, do: {:halt, acc}, else: {:cont, acc}
      end)

    result = %{deleted: deleted, revoked: revoked, kept: length(kept)}

    :telemetry.execute(
      [:prompton, :device_authorizations, :sweep],
      Map.put(result, :duration, System.monotonic_time() - started),
      %{}
    )

    {:ok, result}
  end

  # Returns `{read count, deleted count, revoked token count, kept ids}`. Fewer read than
  # batch_size means there are no more.
  defp sweep_batch(actor, batch_size, kept) do
    expired =
      DeviceAuthorization
      |> Ash.Query.filter(expires_at < ^DateTime.utc_now())
      |> exclude_kept(kept)
      |> Ash.Query.select([:id, :status])
      |> Ash.Query.sort(expires_at: :asc)
      |> Ash.Query.limit(batch_size)
      |> Ash.read!(actor: actor)

    tokens = stranded_tokens(expired, actor)

    {revoked, deletable, batch_kept} =
      Enum.reduce(expired, {0, [], []}, fn row, {r, ids, kept_ids} ->
        case release(row, tokens) do
          :revoked -> {r + 1, [row.id | ids], kept_ids}
          :nothing_to_revoke -> {r, [row.id | ids], kept_ids}
          :keep -> {r, ids, [row.id | kept_ids]}
        end
      end)

    destroy!(deletable, actor)
    {length(expired), length(deletable), revoked, batch_kept}
  end

  # Decrypts the tokens of approved-but-not-consumed rows **in one go**
  # (`id => token | nil | :undecryptable`). AshCloak's decryption calculation **raises** on broken
  # ciphertext (base64 decode) instead of returning `{:error, _}`, so when the batch fails as a
  # whole we retry row by row and single out only the broken ones. If one row killed the whole
  # job, the expired rows behind it would never be swept.
  defp stranded_tokens(expired, actor) do
    approved = Enum.filter(expired, &(&1.status == :approved))

    try do
      approved |> Ash.load!([:token], actor: actor) |> Map.new(&{&1.id, &1.token})
    rescue
      _error -> Map.new(approved, fn row -> {row.id, decrypt_one(row, actor)} end)
    end
  end

  defp decrypt_one(row, actor) do
    Ash.load!(row, [:token], actor: actor).token
  rescue
    _error -> :undecryptable
  end

  defp exclude_kept(query, []), do: query
  defp exclude_kept(query, kept), do: Ash.Query.filter(query, id not in ^kept)

  # Approved but not consumed → revoke the token inside. Other statuses hold no token (`pending`
  # and `denied` never had one, and `consumed` was cleared by `Changes.ClearToken`).
  defp release(%{status: :approved} = row, tokens) do
    case Map.get(tokens, row.id) do
      nil -> :nothing_to_revoke
      :undecryptable -> keep(row, :undecryptable)
      token -> revoke(row, token)
    end
  end

  defp release(_row, _tokens), do: :nothing_to_revoke

  defp revoke(row, token) do
    case CliSession.revoke(token) do
      :ok -> :revoked
      {:error, reason} -> keep(row, reason)
    end
  end

  defp keep(row, reason) do
    Logger.warning(
      "device authorization #{row.id}: could not revoke stranded CLI token, keeping row: " <>
        inspect(reason)
    )

    :keep
  end

  defp destroy!([], _actor), do: :ok

  defp destroy!(ids, actor) do
    %Ash.BulkResult{status: :success} =
      DeviceAuthorization
      |> Ash.Query.filter(id in ^ids)
      |> Ash.bulk_destroy!(:destroy, %{},
        actor: actor,
        strategy: [:atomic],
        return_errors?: true
      )

    :ok
  end
end
