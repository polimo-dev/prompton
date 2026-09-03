defmodule PromptOn.Accounts.SignIn do
  @moduledoc """
  **Email code sign-in**, the one and only sign-in method (user decision 2026-09-03, ADR 0008
  revision: a 6-digit code rather than a link). The screen is `PromptOnWeb.SignInController`
  (`/sign-in`), storage is `PromptOn.Accounts.SignInCode`, and this module is the two steps in
  between:

  1. `request/2`: address shape check → throttle → code issuance (`SignInCode.:request`) → mail
     (`PromptOn.Accounts.SignIn.Email` → `PromptOn.Mailer`, Resend). **Whether the address exists
     or not, whether it was throttled, whether the mail failed: `:ok`**, and the screen shows the
     same notice in every case (no existence disclosure). The only cases that show a different
     face are an address that is not shaped like an email (`{:error, :invalid_email}`) and a code
     that could not be created (`{:error, :unavailable}`, a server-side problem).
  2. `verify/3`: verify throttle → code shape → `SignInCode.:attempt` (attempt counting + consume
     under a lock) → find or create the user. **Sign-up = sign-in**: an unknown address is
     created via `User.:register` (system actor), and the personal organization is created then
     too (`Changes.CreatePersonalOrganization`). Every failure has the one shape
     `{:error, :invalid}`.

  **The code is left nowhere**: it is not put in logs, errors, or return values (`request/2`
  returns only `:ok`), and the request parameter `code` is masked by
  `config :phoenix, :filter_parameters`.
  """

  alias PromptOn.Accounts
  alias PromptOn.Accounts.SignIn.Email
  alias PromptOn.Accounts.SignInCode
  alias PromptOn.Accounts.SignInThrottle
  alias PromptOn.Accounts.User
  alias PromptOn.Mailer
  alias PromptOn.SystemActor

  require Logger

  # A loose shape check; the real validation is whether the mail arrives. `x@y.z` without
  # whitespace is enough.
  @email ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @doc """
  Whether the address is shaped like an email (the same check as `request/2`, for the screen to
  pre-filter).
  """
  @spec valid_email?(term()) :: boolean()
  def valid_email?(email) when is_binary(email), do: Regex.match?(@email, String.trim(email))
  def valid_email?(_email), do: false

  @doc """
  Creates a code and sends it by mail. `client_ip` is the per-IP throttle key
  (`PromptOn.ClientIp.from_conn/1`), `nil` if unknown.
  """
  @spec request(String.t(), String.t() | nil) :: :ok | {:error, :invalid_email | :unavailable}
  def request(email, client_ip) when is_binary(email) do
    email = String.trim(email)

    cond do
      not Regex.match?(@email, email) ->
        {:error, :invalid_email}

      not SignInThrottle.allow_request?(email, client_ip) ->
        Logger.info("sign-in code request throttled for #{obscure(email)}")
        :ok

      true ->
        issue_and_send(email, client_ip)
    end
  end

  @doc """
  Tries the code and returns the user if it matches, creating one if none exists. Any failure is
  `{:error, :invalid}`.
  """
  @spec verify(String.t(), String.t(), String.t() | nil) :: {:ok, User.t()} | {:error, :invalid}
  def verify(email, code, client_ip) when is_binary(email) do
    email = String.trim(email)

    with true <- SignInThrottle.allow_verify?(client_ip),
         {:ok, code} <- SignInCode.normalize_code(code),
         {:ok, _consumed} <-
           Accounts.attempt_sign_in_code(%{email: email, code: code}, actor: SystemActor.new()),
         {:ok, %User{} = user} <- find_or_register(email) do
      {:ok, user}
    else
      _anything -> {:error, :invalid}
    end
  end

  # ---------------------------------------------------------------------------

  defp issue_and_send(email, client_ip) do
    case Accounts.request_sign_in_code(%{email: email, requested_ip: client_ip},
           actor: SystemActor.new()
         ) do
      {:ok, record} ->
        record |> Ash.Resource.get_metadata(:code) |> deliver(email)

      {:error, error} ->
        # Failing to create a code is a storage problem: nothing the user can fix, and unrelated
        # to existence information.
        Logger.error("could not issue a sign-in code for #{obscure(email)}: #{describe(error)}")
        {:error, :unavailable}
    end
  end

  # A delivery failure is `:ok` too; success and failure are not distinguished on screen. Only
  # the reason (adapter error) is logged.
  defp deliver(code, email) do
    email
    |> Email.build(code)
    |> Mailer.deliver()
    |> case do
      {:ok, _delivered} ->
        :ok

      {:error, reason} ->
        Logger.error("sign-in code email to #{obscure(email)} failed: #{describe(reason)}")
        :ok
    end
  end

  defp find_or_register(email) do
    case Accounts.get_user_by_email(email, actor: SystemActor.new()) do
      {:ok, %User{} = user} -> {:ok, user}
      {:ok, nil} -> register(email)
      {:error, _error} = error -> error
    end
  end

  # Two concurrent sign-ins with the same new address still yield one user: the second INSERT is
  # blocked by the `users.email` unique index, so we look up again (signing in as the user the
  # first one created).
  defp register(email) do
    case Accounts.register_user(%{email: email}, actor: SystemActor.new()) do
      {:ok, user} ->
        {:ok, user}

      {:error, error} ->
        case Accounts.get_user_by_email(email, actor: SystemActor.new()) do
          {:ok, %User{} = user} -> {:ok, user}
          _not_found -> {:error, error}
        end
    end
  end

  # For logs; the full address is not recorded: `a***@example.com`.
  defp obscure(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> String.first(local) <> "***@" <> domain
      _ -> "***"
    end
  end

  # Only the reason the adapter/Ash gave; a struct that might carry the mail body (the code) is
  # never printed whole.
  defp describe(%Resend.Error{name: name, message: message, status_code: status}),
    do: "resend #{status} #{name}: #{message}"

  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason, printable_limit: 200, limit: 20)
end
