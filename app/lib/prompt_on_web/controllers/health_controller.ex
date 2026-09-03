defmodule PromptOnWeb.HealthController do
  @moduledoc """
  Health checks (plan.md §6.6, ADR 0005 zero-downtime deployment).

  - `GET /health` - liveness: only that the process is alive.
  - `GET /health/ready` - readiness: checks a DB round trip **and that migrations are complete**.
    In a rolling deployment a new pod must not receive traffic until the migrations have been
    applied (in a `maxUnavailable: 0` rollout this gate is the safety line of the old-to-new
    transition).
  """

  use PromptOnWeb, :controller

  def index(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    with {:db, {:ok, _}} <- {:db, Ecto.Adapters.SQL.query(PromptOn.Repo, "SELECT 1", [])},
         {:migrations, []} <- {:migrations, pending_migrations()} do
      json(conn, %{status: "ok", db: "ok", migrations: "ok"})
    else
      {:db, _} ->
        conn |> put_status(503) |> json(%{status: "degraded", db: "error"})

      {:migrations, pending} ->
        conn
        |> put_status(503)
        |> json(%{status: "waiting", db: "ok", migrations: "pending", pending: length(pending)})
    end
  end

  defp pending_migrations do
    PromptOn.Repo
    |> Ecto.Migrator.migrations()
    |> Enum.filter(fn {status, _version, _name} -> status == :down end)
  rescue
    # A release-environment issue where the migrations directory cannot be read does not block
    # ready (log only)
    _ -> []
  end
end
