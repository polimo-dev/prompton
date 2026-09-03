defmodule Mix.Tasks.Prompton.ExportHeydiaryTables do
  @shortdoc "Live snapshot (v3) → HeyDiary ai_tasks/ai_models/plan_ai_models UPSERT SQL (rollback, lossy, plan.md §12.2)"

  @moduledoc """
      mix prompton.export_heydiary_tables --org <org slug> --project heydiary --env production --out heydiary_tables.sql
      mix prompton.export_heydiary_tables --user <email> --project heydiary --env production

  Builds HeyDiary table UPSERT SQL (`PromptOn.HeyDiaryImport.Export`) from the project/environment's
  **snapshot v3** (`PromptOn.Projects.config_snapshot` — every live Deployment). When, during the
  parallel-run period, edits happened only in PromptOn and you roll back to the HeyDiary DB path,
  bring the tables up to date with `psql -f heydiary_tables.sql`.

  **The round trip is asymmetric**: a revision pins exactly one model, so `plan_ai_models` gets the
  same row for every plan (no user-selectable rows, original ids not preserved), and that warning is
  stamped as a comment at the top of the generated SQL. See the `PromptOn.HeyDiaryImport.Export`
  moduledoc for details.

  Options: exactly one of `--org SLUG` (team organization) or `--user EMAIL` (personal
  organization) is required; `--project` (default `heydiary`), `--env` (default `production`),
  `--out` (stdout when omitted).
  """

  use Mix.Task

  alias PromptOn.HeyDiaryImport.{Export, TargetOrg}

  @switches [org: :string, user: :string, project: :string, env: :string, out: :string]

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    project_slug = opts[:project] || "heydiary"
    env_slug = opts[:env] || "production"

    Mix.Task.run("app.start")
    actor = PromptOn.SystemActor.new()
    org = TargetOrg.resolve!(opts)

    with {:ok, %{} = project} <-
           PromptOn.Projects.get_project_by_slug(org.id, project_slug, actor: actor),
         scope = [actor: actor, tenant: project.id],
         {:ok, %{} = env} <- PromptOn.Projects.get_environment_by_slug(env_slug, scope),
         {:ok, %{map: map}} <- PromptOn.Projects.config_snapshot(env.id, scope) do
      sql = Export.sql(map)

      case opts[:out] do
        nil ->
          IO.write(sql)

        path ->
          File.write!(path, sql)
          Mix.shell().info("wrote #{path} (#{byte_size(sql)} bytes)")
      end
    else
      {:ok, nil} ->
        Mix.raise("project/environment not found (#{project_slug}/#{env_slug})")

      {:error, reason} ->
        Mix.raise("export failed: #{inspect(reason)}")
    end
  end
end
