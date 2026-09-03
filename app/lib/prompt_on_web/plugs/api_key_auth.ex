defmodule PromptOnWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Public API authentication (plan.md §6.1, §11.5).

  `Authorization: Bearer ptn_<project_slug>_<random32>` → `ApiKey.:by_raw_key` (sha256 comparison)
  → `Ash.PlugHelpers.set_actor(conn, api_key)` + `set_tenant(conn, api_key.project_id)`.
  Scope checks are done by the controller/policies (`PromptOn.Checks.ApiKeyScope`). `last_used_at`
  is throttled to once per 5 minutes.
  If the key's project is archived (`archived_at`) the answer is 401 even though the key is alive
  (contract decision #11 — an archived project serves neither snapshots nor monitoring logs).

  **The environment is not decided here** (2026-09-01): keys are not bound to an environment, so
  there is no `assigns.current_environment` either — the controller picks it from the request
  parameter (`environment`, default `"production"`). The project's environment **list**, however,
  is read here **together** with the project (`project: [:environments]`): config-fetch polling
  should touch the DB as little as possible after authentication, yet environment slug → id is
  needed on every request. The project is read anyway for the archive check, so the environments
  ride along on that round trip — `PromptOnWeb.API.V1.RequestEnvironment` picks from that list and
  never hits the DB again.

  Failure response: 401 `{"error": {"code": "unauthorized", ...}}`.
  """

  import Plug.Conn

  alias PromptOn.Projects

  @touch_interval_seconds 300

  def init(opts), do: opts

  def call(conn, _opts) do
    # `:by_raw_key` is bypassed without an actor, but `project` goes through policies, so load it
    # with the key itself as the actor (an ApiKey reads only its own project).
    # The environment list rides on the same load — the controller finds the environment picked by
    # the request parameter without touching the DB.
    with {:ok, raw} <- bearer(conn),
         {:ok, %Projects.ApiKey{} = key} <- Projects.api_key_by_raw_key(raw),
         {:ok, %Projects.ApiKey{} = key} <-
           Ash.load(key, [project: [:environments]], actor: key, tenant: key.project_id),
         false <- archived?(key) do
      maybe_touch(key)

      conn
      |> Ash.PlugHelpers.set_actor(key)
      |> Ash.PlugHelpers.set_tenant(key.project_id)
      |> assign(:api_key, key)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.put_view(json: PromptOnWeb.API.V1.ErrorJSON)
        |> Phoenix.Controller.render(:error,
          code: "unauthorized",
          message: "invalid or missing API key"
        )
        |> halt()
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] when byte_size(raw) > 8 -> {:ok, String.trim(raw)}
      ["bearer " <> raw] when byte_size(raw) > 8 -> {:ok, String.trim(raw)}
      _ -> {:error, :missing}
    end
  end

  defp archived?(%{project: %{archived_at: nil}}), do: false
  defp archived?(_), do: true

  defp maybe_touch(%{last_used_at: nil} = key), do: touch(key)

  defp maybe_touch(%{last_used_at: at} = key) do
    if DateTime.diff(DateTime.utc_now(), at, :second) > @touch_interval_seconds,
      do: touch(key),
      else: :ok
  end

  # Only once per 5 minutes, so update synchronously inside the request (a failure is not promoted
  # to a request failure). Moving it to an async Task gains nothing and gets noisy in the test
  # sandbox / at shutdown, where the connection owner disappears first.
  defp touch(key) do
    _ = Projects.touch_api_key(key, actor: key)
    :ok
  rescue
    _ -> :ok
  end
end
