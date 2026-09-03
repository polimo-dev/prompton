defmodule PromptOn.Accounts.Sessions do
  @moduledoc """
  **All of one user's stored tokens**, browser sessions (`"user"`) and CLI sessions (`"cli"`)
  alike.

  Where `PromptOn.Accounts.CliSession` handles CLI sessions one by one, this module does one thing
  only: "revoke all of this person's sign-ins". Its place is **Sign out everywhere** on the
  account screen `/account` (`PromptOnWeb.AccountLive`).

  On an account without a password (ADR 0008: sign-in is by email code only) there is no path of
  "change the password to cut off every other session". So revoking everything is an **explicit
  button**. ash_authentication's `log_out_everywhere` add-on is tied to password changes, so it is
  not used.

  ## The current session is kept

  Cutting off the very browser that clicked would leave the user with "I clicked and got signed
  out myself". So `except:` takes the current session's `jti` and keeps only that one; the
  account screen pulls it out of the session and passes it along (`session["user_token"]`).
  """

  alias PromptOn.Accounts.Token
  alias PromptOn.Accounts.User
  alias PromptOn.SystemActor

  require Ash.Query

  @doc """
  Revokes all of the user's stored tokens (whatever the purpose). A single `except: jti` can be
  kept.
  """
  @spec revoke_all(User.t(), keyword()) :: :ok | {:error, term()}
  def revoke_all(%User{} = user, opts \\ []) do
    subject = AshAuthentication.user_to_subject(user)

    Token
    |> Ash.Query.filter(subject == ^subject and purpose != "revocation")
    |> keep(opts[:except])
    |> Ash.bulk_update(:revoke_all_stored_for_subject, %{subject: subject},
      actor: SystemActor.new(),
      strategy: [:atomic, :atomic_batches, :stream],
      return_errors?: true,
      stop_on_error?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  defp keep(query, nil), do: query
  defp keep(query, jti) when is_binary(jti), do: Ash.Query.filter(query, jti != ^jti)
end
