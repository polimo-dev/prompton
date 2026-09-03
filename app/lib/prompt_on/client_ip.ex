defmodule PromptOn.ClientIp do
  @moduledoc """
  Client IP resolution, following the **same rules** as the endpoint's `RemoteIp` plug
  (`PromptOnWeb.Endpoint`). Behind the gateway (Traefik) the peer IP is the gateway, and the real
  client is in the `x-forwarded-for` header that Traefik **overwrites**. `RemoteIp.from/2` skips
  private and loopback hops in that chain and picks the last public IP, falling back to the peer
  when there is none.

  Used by `PromptOnWeb.SignInController` as the throttle key for sign-in code requests and
  verification (`PromptOn.Accounts.SignInThrottle`). `from_conn/1` turns the value the endpoint has
  already resolved into `conn.remote_ip` into a string by the same rules (the same bucket rule as
  `PromptOnWeb.Plugs.RateLimit` on `/device`).
  """

  @forwarded_header "x-forwarded-for"

  @doc "The request's client IP (dotted string, `nil` when unknown)."
  @spec from_conn(Plug.Conn.t()) :: String.t() | nil
  def from_conn(%Plug.Conn{req_headers: headers, remote_ip: peer}), do: resolve(headers, peer)

  @doc """
  `headers` is a list of `{name, value}` tuples (only `x-forwarded-for` is considered); `peer` is an
  `:inet.ip_address()` tuple or a dotted string (or `nil`). The result is a dotted string, `nil`
  when unknown.
  """
  @spec resolve([{String.t(), String.t()}], :inet.ip_address() | String.t() | nil) ::
          String.t() | nil
  def resolve(headers, peer) when is_list(headers) do
    case RemoteIp.from(headers, headers: [@forwarded_header]) || parse_peer(peer) do
      nil -> nil
      ip -> ip |> :inet.ntoa() |> to_string()
    end
  end

  defp parse_peer(address) when is_tuple(address), do: address

  defp parse_peer(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, ip} -> ip
      {:error, _} -> nil
    end
  end

  defp parse_peer(_other), do: nil
end
