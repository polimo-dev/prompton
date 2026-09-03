defmodule PromptOn.ReleaseTasks do
  @moduledoc """
  Operator tasks that run inside a release (`mix release`) without Mix (plan.md §11.6). It is named
  `ReleaseTasks` rather than `PromptOn.Release` to keep the release artifact (`mix release`) and the
  domain deployment (`PromptOn.Deployments`) apart by name.

      bin/prompton eval "PromptOn.ReleaseTasks.migrate()"
      bin/prompton eval "PromptOn.ReleaseTasks.seed_admin(\\"you@example.com\\")"
  """

  @app :prompton

  @doc "Runs all Repo migrations (once at container start; assumes a single node)."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Pre-creates an account by email (without mix, idempotent). Same meaning as
  `mix prompton.seed_admin`: there is no password, sign-in is the email code at `/sign-in`
  (ADR 0008). Since sign-up = sign-in, this is usually unnecessary.

  When called via `bin/prompton eval` on a serving pod, the server in the same container already
  holds port 4000, so `PHX_SERVER` is unset before starting the app to keep a second Endpoint from
  booting.
  """
  def seed_admin(email) do
    System.delete_env("PHX_SERVER")
    Application.ensure_all_started(@app)
    actor = PromptOn.SystemActor.new()

    case PromptOn.Accounts.get_user_by_email(email, actor: actor) do
      {:ok, nil} -> PromptOn.Accounts.register_user(%{email: email}, actor: actor)
      {:ok, user} -> {:ok, user}
    end
  end

  @doc "For the container HEALTHCHECK: raises when a DB round-trip fails."
  def health! do
    {:ok, _} = Ecto.Adapters.SQL.query(PromptOn.Repo, "SELECT 1", [])
    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
