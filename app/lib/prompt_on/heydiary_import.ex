defmodule PromptOn.HeyDiaryImport do
  @moduledoc """
  HeyDiary → PromptOn data migration tooling (plan.md §12.2). A pure API usable without the mix
  task:

  1. `Dump.load_file/1` / `Dump.parse/1` — HeyDiary `ai_tasks`/`ai_models`/`plan_ai_models` JSON
     dump (`priv/heydiary/DUMP.md`).
  2. `plan/2` — dump → deterministic plan (`%PromptOn.HeyDiaryImport.Plan{}`), no DB.
  3. `apply/2` — runs the plan in one transaction (`PromptOn.HeyDiaryImport.Apply`).
  4. `PromptOn.HeyDiaryImport.Verify.compare/2` — reproduction of HeyDiary `build_llm_config` vs
     `PromptOnSDK.Resolver` (every (task, language) — the plan axis is not in the pin, so it is not
     compared).
  5. `PromptOn.HeyDiaryImport.Export.sql/1` — snapshot (v3) →
     `ai_tasks`/`ai_models`/`plan_ai_models` UPSERT SQL (for rollback, **lossy** — the same model
     for every plan).

  Deployments are **pins** (ADR 0007 revision 2026-09-01): one revision per use case = one model
  plus one version per prompt name. HeyDiary's per-plan model hierarchy cannot be represented, so
  it collapses to the free (common) default row and surfaces as a confirmation-gated warning —
  plan differentiation is now the app's job.

  mix entry points: `mix prompton.import_heydiary`, `mix prompton.export_heydiary_tables`.
  """

  alias PromptOn.HeyDiaryImport.{Apply, Dump, Plan, Planner}

  @doc """
  Builds a migration plan from a dump (map or `%Dump{}`). See
  `PromptOn.HeyDiaryImport.Planner.plan/2` for `opts` (`:project_slug`, `:project_name`,
  `:environment`).
  """
  @spec plan(map() | Dump.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(dump, opts \\ []) do
    with {:ok, dump} <- Dump.parse(dump), do: Planner.plan(dump, opts)
  end

  @doc """
  Runs the plan. `opts`: `:actor` (required), `:organization_id` (required), `:force`.
  See `PromptOn.HeyDiaryImport.Apply.apply/2`.
  """
  @spec apply(Plan.t(), keyword()) :: {:ok, Apply.summary()} | {:error, term()}
  def apply(%Plan{} = plan, opts), do: Apply.apply(plan, opts)
end
