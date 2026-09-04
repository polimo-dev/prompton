defmodule PromptOnWeb.API.V1.SnapshotController do
  @moduledoc """
  `GET /api/v1/use-cases` - the SDK's main path (plan.md §6.2, schema v4 / ADR 0007). The full
  deployment state of one environment.

  - Scope `:read`.
  - The environment is chosen by the **query parameter** `?environment=<slug>` (default
    `production`) - keys are project-level (2026-09-01). An unknown environment is 404.
  - `ETag` = sha256 of the canonical JSON body (`"sha256-<hex>"`, a strong ETag including the
    quotes). A matching `If-None-Match` gets `304`.
  - The body is the assembled canonical bytes **verbatim** (hashed bytes = response bytes).
  - `Last-Modified` = the latest change time of the live Deployment and the resources it
    references; `Cache-Control: max-age=30`.
  - Body and ETag come from `PromptOn.Deployments.SnapshotCache` (per-environment ETS, default TTL
    5 seconds, ETag revalidation on expiry) - polling is the normal use of this endpoint, so it is
    not assembled per request. As a result, the previous revision can be served for up to the TTL
    right after a deployment commit.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Deployments.SnapshotCache
  alias PromptOnWeb.API.V1.RequestEnvironment

  plug PromptOnWeb.Plugs.RequireScope, :read

  action_fallback PromptOnWeb.API.V1.FallbackController

  @max_age 30

  def show(conn, params) do
    api_key = conn.assigns.api_key

    with {:ok, environment} <- RequestEnvironment.fetch(conn, params),
         {:ok, snapshot} <-
           SnapshotCache.fetch(environment, actor: api_key, tenant: api_key.project_id) do
      etag = quote_etag(snapshot.etag)

      conn =
        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header("last-modified", http_date(snapshot.last_modified))
        |> put_resp_header("cache-control", "max-age=#{@max_age}")

      if none_match?(conn, snapshot.etag) do
        send_resp(conn, 304, "")
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, snapshot.body)
      end
    end
  end

  @doc "The ETag value in HTTP header form (with quotes)."
  @spec quote_etag(String.t()) :: String.t()
  def quote_etag(etag), do: ~s("#{etag}")

  @doc "RFC 7231 IMF-fixdate (`Mon, 18 Aug 2026 09:12:03 GMT`)."
  @spec http_date(DateTime.t()) :: String.t()
  def http_date(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  # `If-None-Match: "sha256-…", W/"sha256-…", *` - strip the quotes/weak marker and compare.
  defp none_match?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&normalize_etag/1)
    |> Enum.any?(&(&1 == etag or &1 == "*"))
  end

  defp normalize_etag(value) do
    value
    |> String.trim()
    |> String.replace_prefix("W/", "")
    |> String.trim("\"")
  end
end
