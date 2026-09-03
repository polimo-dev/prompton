defmodule PromptOn.Accounts.SignInThrottle do
  @moduledoc """
  Abuse control for sign-in codes: fixed-window counters (`PromptOn.RateLimit`, Hammer ETS;
  counted per node).

  | axis | what | default limit | why |
  |---|---|---|---|
  | `email` | code **requests** | 3 per 10 min | stops flooding one address with mail (an attack that fills someone else's inbox with spam) |
  | `ip` | code **requests** | 10 per 10 min | stops one browser from firing mail while cycling through addresses |
  | `verify_ip` | code **verifications** | 20 per 10 min | how many times one browser may try a code; one more layer on top of the 5-per-code limit |

  ## Exceeding it is not an error

  `/sign-in` is unauthenticated. If the screen changed when the request throttle kicked in, that
  would say "there was a recent request for this address", i.e. the address's existence/activity
  would leak. So when `allow_request?/3` returns `false`, the caller
  (`PromptOn.Accounts.SignIn.request/2`) **merely skips sending the mail and behaves exactly like
  success** (same flash). The verify throttle (`allow_verify?/2`) fails with the same message as
  a wrong code; again indistinguishable. This module leaves no trace either, beyond a single log
  line.

  ## Per-environment tuning

  Override `limit` and `scale` per axis, as in
  `config :prompton, PromptOn.Accounts.SignInThrottle, ip: [limit: 1_000_000]`. The test suite
  requests and verifies codes hundreds of times from one IP (127.0.0.1), so `config/test.exs`
  relaxes the two IP axes (the email axis stays at 3 because every test uses a different
  address).
  """

  @defaults [
    email: [limit: 3, scale: :timer.minutes(10)],
    ip: [limit: 10, scale: :timer.minutes(10)],
    verify_ip: [limit: 20, scale: :timer.minutes(10)]
  ]

  @doc """
  Whether this code request may be sent. Increments **both** counters first (an attempt is an
  attempt), then `true` only when both are within their limits. If `client_ip` is `nil`, the IP
  axis is not counted.

  Limits can be overridden via `opts` (`email: [limit: 1]`), for tests.
  """
  @spec allow_request?(String.t(), String.t() | nil, keyword()) :: boolean()
  def allow_request?(email, client_ip, opts \\ []) when is_binary(email) do
    limits = limits(opts)

    email_ok? = hit("request:email", normalize_email(email), limits[:email])
    ip_ok? = is_nil(client_ip) or hit("request:ip", client_ip, limits[:ip])

    email_ok? and ip_ok?
  end

  @doc """
  Whether this IP may try a code. If `client_ip` is `nil` it is not counted (`true`).
  """
  @spec allow_verify?(String.t() | nil, keyword()) :: boolean()
  def allow_verify?(client_ip, opts \\ []) do
    is_nil(client_ip) or hit("verify:ip", client_ip, limits(opts)[:verify_ip])
  end

  defp hit(axis, key, window) do
    case PromptOn.RateLimit.hit("sign_in:#{axis}:#{key}", window[:scale], window[:limit]) do
      {:allow, _count} -> true
      {:deny, _retry_after_ms} -> false
    end
  end

  # So the same address with different case or surrounding whitespace does not get a different
  # bucket.
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()

  defp limits(opts) do
    configured = Application.get_env(:prompton, __MODULE__, [])

    for {axis, defaults} <- @defaults do
      merged =
        defaults
        |> Keyword.merge(Keyword.get(configured, axis, []))
        |> Keyword.merge(Keyword.get(opts, axis, []))

      {axis, Keyword.take(merged, [:limit, :scale])}
    end
  end
end
