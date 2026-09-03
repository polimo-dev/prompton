defmodule PromptOnWeb.API.V1.DeviceController do
  @moduledoc """
  `POST /api/v1/device/code` and `POST /api/v1/device/token` - device login for the CLI (RFC 8628
  style, agent-first-spec batch ③, `docs/management-api.md` §2).

  | Request | What it does |
  |---|---|
  | `POST /device/code` | Issues a code pair (`DeviceAuthorization.:start`) |
  | `POST /device/token` | Polling - once approved, hands out **the token once** (`:consume`) |

  ## There is no authentication

  Both routes are unauthenticated - authentication happens on the browser side (sign-in + Approve on
  the `/device` screen), and all the CLI presents here is the `device_code` it was just given. So
  the controller calls the domain as `PromptOn.SystemActor` (the SystemActor bypass in the resource
  policies).

  ## Failures use the RFC 8628 names verbatim

  All four are **400** and are distinguished by `code`. The CLI keeps waiting on
  `authorization_pending`/`slow_down` and gives up on `expired_token`/`access_denied`.

  | code | When |
  |---|---|
  | `authorization_pending` | Nobody has approved yet |
  | `slow_down` | Polled faster than the recommended `interval` |
  | `expired_token` | 15 minutes passed, the token was already taken once, or no such code exists |
  | `access_denied` | The person denied it |

  An unknown code is also `expired_token` **so as not to reveal existence** - opening a way to ask
  whether a code is valid on an unauthenticated route is exactly the door to an enumeration attack.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Accounts
  alias PromptOn.Accounts.DeviceAuthorization
  alias PromptOnWeb.API.V1.Management.Params

  action_fallback PromptOnWeb.API.V1.FallbackController

  # Polling faster than this gets `slow_down`. Using `interval` as-is would bounce honest clients on
  # clock skew and network jitter, so shave off one second.
  @min_poll_gap_seconds DeviceAuthorization.poll_interval_seconds() - 1

  def code(conn, params) do
    with {:ok, client} <- Params.required_string(params, "client"),
         {:ok, name} <- Params.optional_string(params, "name"),
         {:ok, request} <-
           Accounts.start_device_authorization(%{client: client, key_name: name}, actor: system()) do
      device_code = Ash.Resource.get_metadata(request, :device_code)

      conn |> put_status(:created) |> json(code_response(conn, request, device_code))
    end
  end

  def token(conn, params) do
    with {:ok, device_code} <- Params.required_string(params, "device_code"),
         {:ok, request} <- fetch(device_code),
         :ok <- check_poll_rate(request),
         {:ok, request} <- check_state(request),
         {:ok, session} <- take_token(request) do
      json(conn, token_response(session))
    end
  end

  # ---------------------------------------------------------------------------
  # Lookup and state

  defp fetch(device_code) do
    case Accounts.device_authorization_by_device_code(device_code, actor: system()) do
      {:ok, %DeviceAuthorization{} = request} -> {:ok, request}
      _other -> {:error, device_error(:expired_token)}
    end
  end

  # The poll timestamp is stamped **before** the verdict - a request that polled too fast must still
  # refresh "when it last polled", so a client that keeps polling too fast keeps getting
  # `slow_down`.
  defp check_poll_rate(request) do
    gap = last_poll_gap(request)
    _ = Accounts.touch_device_poll(request, actor: system())

    if gap != nil and gap < @min_poll_gap_seconds,
      do: {:error, device_error(:slow_down)},
      else: :ok
  end

  defp last_poll_gap(%{last_polled_at: nil}), do: nil
  defp last_poll_gap(%{last_polled_at: at}), do: DateTime.diff(DateTime.utc_now(), at, :second)

  defp check_state(request) do
    cond do
      request.status == :denied -> {:error, device_error(:access_denied)}
      request.status == :consumed -> {:error, device_error(:expired_token)}
      DeviceAuthorization.expired?(request) -> {:error, device_error(:expired_token)}
      request.status == :approved -> {:ok, request}
      true -> {:error, device_error(:authorization_pending)}
    end
  end

  # The token goes out only once - `:consume` wipes the ciphertext and moves the state as soon as it
  # has been read.
  defp take_token(request) do
    with {:ok, loaded} <- Ash.load(request, [:token, :user], actor: system()),
         token when is_binary(token) <- loaded.token,
         {:ok, _consumed} <- Accounts.consume_device_authorization(loaded, actor: system()) do
      {:ok, %{token: token, user: loaded.user}}
    else
      _other -> {:error, device_error(:expired_token)}
    end
  end

  # ---------------------------------------------------------------------------
  # Responses

  defp code_response(conn, request, device_code) do
    verification_uri = url(conn, ~p"/device")

    %{
      "device_code" => device_code,
      "user_code" => request.user_code,
      "verification_uri" => verification_uri,
      "verification_uri_complete" => verification_uri <> "?code=" <> request.user_code,
      "expires_in" => DeviceAuthorization.ttl_seconds(),
      "interval" => DeviceAuthorization.poll_interval_seconds()
    }
  end

  defp token_response(%{token: token, user: user}) do
    %{
      "token" => token,
      "user" => PromptOnWeb.API.V1.Management.JSON.user(user),
      "organizations" => organizations(user)
    }
  end

  defp organizations(user) do
    case Accounts.list_organizations_for(user.id, actor: user) do
      {:ok, organizations} ->
        Enum.map(organizations, &PromptOnWeb.API.V1.Management.JSON.organization/1)

      {:error, _error} ->
        []
    end
  end

  @messages %{
    authorization_pending: "the user has not yet approved this device",
    slow_down: "polling too fast — wait for the interval given with the device code",
    expired_token: "this device code is no longer valid",
    access_denied: "the user denied this device"
  }

  defp device_error(code), do: {:device, code, @messages[code]}

  defp system, do: PromptOn.SystemActor.new()
end
