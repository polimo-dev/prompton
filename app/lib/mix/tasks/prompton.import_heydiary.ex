defmodule Mix.Tasks.Prompton.ImportHeydiary do
  @shortdoc "Migrate a HeyDiary ai_tasks/ai_models/plan_ai_models dump into a PromptOn project (plan.md §12.2)"

  @moduledoc """
      mix prompton.import_heydiary --dump heydiary_dump.json --org <org slug> [options]
      mix prompton.import_heydiary --dump heydiary_dump.json --user <email> [options]

  Options:

  - `--dump PATH` (required) — JSON in the `priv/heydiary/DUMP.md` format
  - `--org SLUG` — the **team** organization in which to create/find the project (one of
    `--org`/`--user` is required unless `--dry-run`)
  - `--user EMAIL` — that user's **personal** organization (personal organizations have no slug)
  - `--project SLUG` — project slug (default `heydiary`)
  - `--env SLUG` — target environment (default `production`; created when missing)
  - `--dry-run` — print the plan only and write nothing
  - `--force` — import even into a project that already has UseCases (re-run)
  - `--yes` — proceed without asking on warnings that need confirmation (per-plan models
    flattened, per-language temperatures flattened, no `default` prompt, no free default row,
    ambiguous default row)
  - `--verify` — after applying, assemble the snapshot (v3) and compare it exhaustively against the
    HeyDiary semantics for every (task, language) (§12.2 step 9)

  Order: load dump → print plan (`PromptOn.HeyDiaryImport.plan/2`) → confirm warnings → apply
  (SystemActor, one transaction) → summary (+ verification). Afterwards, run `mix prompton.export`
  in the HeyDiary repo to refresh `priv/prompton/snapshot.json`.

  **Deployments are pins** (ADR 0007 revision 2026-09-01) — one model per use case plus one version
  per prompt name. HeyDiary's per-plan model hierarchy cannot be represented, so it collapses to the
  free (common) default row and asks for confirmation via `{:plan_models_flattened, …}`. Language
  branching is the prompt name (`default`/`ko` …), which the app picks by sending `prompt` with the
  request.
  """

  use Mix.Task

  alias PromptOn.HeyDiaryImport
  alias PromptOn.HeyDiaryImport.{Dump, Plan, Report, TargetOrg, Verify}

  @switches [
    dump: :string,
    org: :string,
    user: :string,
    project: :string,
    env: :string,
    dry_run: :boolean,
    force: :boolean,
    yes: :boolean,
    verify: :boolean
  ]

  @impl true
  def run(args) do
    {opts, dry_run?} = parse_options!(args)
    dump = load_dump!(opts[:dump])

    plan =
      case HeyDiaryImport.plan(dump,
             project_slug: opts[:project] || "heydiary",
             environment: opts[:env] || "production"
           ) do
        {:ok, plan} -> plan
        {:error, reason} -> Mix.raise("cannot plan import: #{inspect(reason)}")
      end

    info(Report.plan(plan))
    info("")

    if dry_run? do
      info("dry run — nothing written.")
    else
      confirm!(plan, Keyword.get(opts, :yes, false))
      apply!(plan, dump, opts)
    end
  end

  defp parse_options!(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")
    if is_nil(opts[:dump]), do: Mix.raise("--dump is required")

    dry_run? = Keyword.get(opts, :dry_run, false)

    if not dry_run? and not TargetOrg.given?(opts),
      do: Mix.raise("--org SLUG or --user EMAIL is required (unless --dry-run)")

    {opts, dry_run?}
  end

  defp load_dump!(path) do
    case Dump.load_file(path) do
      {:ok, dump} -> dump
      {:error, reason} -> Mix.raise("cannot load dump #{path}: #{inspect(reason)}")
    end
  end

  defp confirm!(plan, yes?) do
    case Plan.confirmations(plan) do
      [] ->
        :ok

      confirmations ->
        info("#{length(confirmations)} warning(s) need confirmation:")
        Enum.each(confirmations, &info("  - " <> Plan.describe_warning(&1)))

        cond do
          yes? -> info("--yes given, proceeding.")
          Mix.shell().yes?("Proceed with the import as planned?") -> :ok
          true -> Mix.raise("aborted")
        end
    end
  end

  defp apply!(plan, dump, opts) do
    Mix.Task.run("app.start")
    actor = PromptOn.SystemActor.new()
    organization = TargetOrg.resolve!(opts)

    summary =
      case HeyDiaryImport.apply(plan,
             actor: actor,
             organization_id: organization.id,
             force: Keyword.get(opts, :force, false)
           ) do
        {:ok, summary} ->
          summary

        {:error, {:project_not_empty, slug}} ->
          Mix.raise(
            "project #{slug} already has use cases — pass --force to import into it anyway"
          )

        {:error, reason} ->
          Mix.raise("import failed (rolled back): #{inspect(reason)}")
      end

    info("")
    info(Report.summary(summary))

    if Keyword.get(opts, :verify, false), do: verify!(dump, summary, actor)

    info("")

    info(
      "Next: in the HeyDiary repo run `mix prompton.export` to refresh priv/prompton/snapshot.json."
    )
  end

  defp verify!(dump, summary, actor) do
    case PromptOn.Projects.config_snapshot(summary.environment_id,
           actor: actor,
           tenant: summary.project_id
         ) do
      {:ok, %{map: map}} ->
        mismatches = Verify.compare(dump, map)
        info("")
        info(Report.mismatches(mismatches))
        if mismatches != [], do: Mix.raise("verification failed")

      {:error, reason} ->
        Mix.raise("cannot build snapshot for verification: #{inspect(reason)}")
    end
  end

  defp info(message), do: Mix.shell().info(message)
end
