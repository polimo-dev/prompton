defmodule PromptOnWeb.Plugs.RateLimit do
  @moduledoc """
  Fixed-window rate limit keyed by client IP — over the limit it ends the request with **429**
  `{"error": {"code": "rate_limited", …}}` + a `retry-after` header.

      plug PromptOnWeb.Plugs.RateLimit, bucket: :device_code, limit: 20, scale: :timer.minutes(10)

  | Option | Meaning |
  |---|---|
  | `bucket` | counter name — the same IP is counted separately per bucket (required) |
  | `limit` | requests allowed per window |
  | `scale` | window length (ms) |

  ## Where it is attached

  The two unauthenticated device login endpoints (`router.ex`). `/device/code` is a write that
  creates a row, so it is tight; `/device/token` already has a per-code `slow_down` throttle, so it
  is loose — just enough to cap the DB lookup load.

  ## `RemoteIp` decides the IP

  The endpoint's `RemoteIp` plug unwraps the `x-forwarded-for` that Traefik attaches and puts it in
  `conn.remote_ip` (only hops from private ranges are trusted as proxies). Without it every client
  collapses onto the single gateway IP and the limit becomes effectively global — it fails toward
  blocking, so it is safe, but that is why a change to the proxy setup means revisiting this plug's
  granularity too.

  ## Per-environment tuning

  Override `limit` and `scale` per bucket, as in
  `config :prompton, PromptOnWeb.Plugs.RateLimit, device_code: [limit: 100_000]` — the test suite
  requests hundreds of codes from one IP (127.0.0.1), so test.exs lifts the limit and only the 429
  contract test tightens it briefly.
  """

  import Plug.Conn

  alias PromptOnWeb.API.V1.ErrorJSON

  @behaviour Plug

  @impl Plug
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)

    %{
      bucket: bucket,
      limit: Keyword.fetch!(opts, :limit),
      scale: Keyword.fetch!(opts, :scale)
    }
  end

  @impl Plug
  def call(conn, %{bucket: bucket} = defaults) do
    %{limit: limit, scale: scale} = configured(bucket, defaults)
    key = "#{bucket}:#{:inet.ntoa(conn.remote_ip)}"

    case PromptOn.RateLimit.hit(key, scale, limit) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_ms} ->
        retry_after = max(div(retry_after_ms + 999, 1000), 1)

        body =
          ErrorJSON.render("error.json", %{
            code: "rate_limited",
            message: "too many requests — try again in #{retry_after}s",
            details: %{"retry_after" => retry_after}
          })

        # Sent directly — `Phoenix.Controller.render/3` requires parsed params, and this plug has to
        # work wherever it sits in the pipeline.
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(body))
        |> halt()
    end
  end

  defp configured(bucket, defaults) do
    overrides =
      (Application.get_env(:prompton, __MODULE__) || [])
      |> Keyword.get(bucket, [])

    %{
      limit: Keyword.get(overrides, :limit, defaults.limit),
      scale: Keyword.get(overrides, :scale, defaults.scale)
    }
  end
end
