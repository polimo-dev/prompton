defmodule PromptOn.Accounts.SignInCode.Actions.Attempt do
  @moduledoc """
  Implementation of `SignInCode.:attempt`: tries a code. **The attempt is counted under a lock,
  and it is committed even on failure.**

  1. Lock the address's newest live (not consumed, not expired) row with `SELECT … FOR UPDATE`.
     None: fail.
  2. If `attempts` is already `SignInCode.max_attempts/0`: fail, even if the code is correct.
  3. Write `attempts + 1`. If the hash matches, stamp `consumed_at` too and return the row.

  The lock serializes concurrent submissions of the same code: the second request waits for the
  first's commit and then re-reads the updated row (READ COMMITTED), where the consumed row falls
  out of the condition and becomes "none", so there is one sign-in.

  Why the generic action's `transaction?` is not used: Ash **rolls back** the transaction when an
  action ends in an error. The attempt count of a wrong code must not be rolled back (otherwise
  the 5-attempt limit means nothing), so we open `Repo.transaction/1` directly here, return the
  failure as a value so it **commits**, and turn it into an error outside.

  Every failure has one shape (`invalid/0`).
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias PromptOn.Accounts.SignInCode
  alias PromptOn.Repo

  @impl true
  def run(input, _opts, context) do
    email = input |> Ash.ActionInput.get_argument(:email) |> to_string()
    code = Ash.ActionInput.get_argument(input, :code)
    opts = Ash.Context.to_opts(context)

    case Repo.transaction(fn -> attempt(email, code, opts) end) do
      {:ok, {:ok, %SignInCode{} = consumed}} -> {:ok, consumed}
      {:ok, :invalid} -> {:error, invalid()}
      {:error, error} -> {:error, error}
    end
  end

  defp attempt(email, code, opts) do
    with %SignInCode{} = row <- latest_live(email, opts),
         true <- row.attempts < SignInCode.max_attempts() do
      record(row, code, opts)
    else
      _no_row_or_exhausted -> :invalid
    end
  end

  # Row lock: concurrent attempts on the same address wait here for the earlier attempt's commit.
  defp latest_live(email, opts) do
    SignInCode
    |> Ash.Query.filter(
      email == ^email and is_nil(consumed_at) and expires_at > ^DateTime.utc_now()
    )
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(opts)
  end

  defp record(row, code, opts) do
    matched? = Plug.Crypto.secure_compare(row.code_hash, SignInCode.hash(row.id, code))
    attempts = row.attempts + 1

    params =
      if matched?,
        do: %{attempts: attempts, consumed_at: DateTime.utc_now()},
        else: %{attempts: attempts}

    # Inside a transaction, so notifications are collected here (this resource has no notifier).
    {updated, _notifications} =
      row
      |> Ash.Changeset.for_update(:record_attempt, params, opts)
      |> Ash.update!(return_notifications?: true)

    if matched?, do: {:ok, updated}, else: :invalid
  end

  @doc """
  The one shape of failure; missing, wrong, expired, and over the limit are not distinguished.
  """
  @spec invalid() :: Ash.Error.Changes.InvalidArgument.t()
  def invalid,
    do: Ash.Error.Changes.InvalidArgument.exception(field: :code, message: "is not valid")
end
