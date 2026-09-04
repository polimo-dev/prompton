defmodule PromptOnWeb.API.V1.LogController do
  @moduledoc """
  `POST /api/v1/logs` - **monitoring logs** ingestion: batched, idempotent, partially
  accepted (plan.md §6.4, docs/api.md).

  The app calls its own provider directly without PromptOn (§2 config-fetch) and sends the result of
  each call here - PromptOn does not sit on the request path. The route is named after the resource,
  `logs`.

  - Scope `:logs` (403 `forbidden` without it).
  - **The request picks the environment** (2026-09-01): the `environment` parameter (default
    `"production"`) is enforced on the **whole** batch - keys are not bound to an environment
    (`PromptOnWeb.API.V1.RequestEnvironment`), so the value a record claims is still ignored. An
    unknown environment is 404.
  - Body `{"logs": [ … ≤200 records … ]}` - not a list, or more than 200 records, is 400
    `invalid_request`.
  - Response `202 {"accepted", "duplicates", "rejected": [{"index", "id", "code", "message"}]}`.
  - The 5MB body cap is set by the `Plug.Parsers` `length` in `PromptOnWeb.Endpoint` (a global
    parser - it is below the default 8MB, so there is no separate per-route parser; Plug answers 413
    when exceeded).
  - A storage failure (transaction rollback, DB outage) is 503 `unavailable` + `Retry-After: 5` -
    the SDK resends with the same ids and the server absorbs the duplicates. Internal error text
    stays out of the response and goes only to the server log (contract decision #8).
  """

  use PromptOnWeb, :controller

  require Logger

  alias PromptOn.Observability.Ingest
  alias PromptOnWeb.API.V1.{ErrorJSON, RequestEnvironment}

  @retry_after_seconds 5

  plug PromptOnWeb.Plugs.RequireScope, :logs

  action_fallback PromptOnWeb.API.V1.FallbackController

  def create(conn, %{"logs" => logs} = params) when is_list(logs) do
    api_key = conn.assigns.api_key

    with :ok <- check_batch_size(logs),
         {:ok, environment} <- RequestEnvironment.fetch(conn, params),
         {:ok, result} <-
           Ingest.ingest(logs,
             actor: api_key,
             tenant: api_key.project_id,
             environment_id: environment.id,
             bytes: body_bytes(conn)
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{
        accepted: result.accepted,
        duplicates: result.duplicates,
        rejected:
          Enum.map(result.rejected, fn r ->
            %{index: r.index, id: r.id, code: r.code, message: r.message}
          end)
      })
    else
      {:error, {:invalid_request, _} = error} ->
        {:error, error}

      {:error, {:not_found, _message, _details} = error} ->
        {:error, error}

      {:error, :forbidden} ->
        {:error, :forbidden}

      {:error, reason} ->
        Logger.error(
          "prompton ingest failed for project #{api_key.project_id}: #{inspect(reason, limit: 20)}"
        )

        conn
        |> put_status(:service_unavailable)
        |> put_resp_header("retry-after", Integer.to_string(@retry_after_seconds))
        |> put_view(json: ErrorJSON)
        |> render(:error,
          code: "unavailable",
          message: "could not store the monitoring logs, retry with the same ids",
          details: %{retry_after: @retry_after_seconds}
        )
    end
  end

  def create(_conn, %{"logs" => _}),
    do: {:error, {:invalid_request, "logs must be a list"}}

  def create(_conn, _params),
    do: {:error, {:invalid_request, "body must be {\"logs\": [...]}"}}

  defp check_batch_size(logs) do
    if length(logs) <= Ingest.max_batch(),
      do: :ok,
      else: {:error, {:invalid_request, "at most #{Ingest.max_batch()} logs per request"}}
  end

  defp body_bytes(conn) do
    case get_req_header(conn, "content-length") do
      [value | _] ->
        case Integer.parse(value) do
          {n, _} -> n
          :error -> 0
        end

      _ ->
        0
    end
  end
end
