defmodule PromptOn.HeyDiaryImport.Plan do
  @moduledoc """
  The result of `PromptOn.HeyDiaryImport.plan/2` — a migration plan computed **deterministically**
  from the dump (plan.md §12.2 steps 2-7, ADR 0007 + revision 2026-09-01 "deployments are pins").
  It never touches the DB, and every reference is a name rather than an id (model
  `{provider, model_id}`, Prompt name). `PromptOn.HeyDiaryImport.Apply` runs this plan through the
  code interfaces and turns the names into ids.

  | Field | Contents |
  |---|---|
  | `project` | `%{slug, name}` (context dimensions were deleted) |
  | `environment` | target environment slug |
  | `models` | `%{provider, model_id, display_name, metadata, provider_options, source_id}` |
  | `use_cases` | `%{key, name, kind, input_schema, default_params, description}` |
  | `prompts` | `%{use_case_key, name, description, language}` (`name` = `"default"` or the language) |
  | `prompt_versions` | `%{use_case_key, prompt_name, engine, messages, text_template, commit_message}` |
  | `deployments` | **one** per use case — `%{use_case_key, model, params, provider_options, prompt_names, description}` |
  | `warnings` | list of warning tuples (`t:warning/0`) |

  ## A deployment = one pin (not rules)

  One revision is **one model** (`model` `{provider, model_id}` + `params` + `provider_options`)
  and **one version pin per prompt name** (`prompt_names` — Apply turns it into
  `%{name => version_id}`). There are no conditions, rules, targets, weights or user-selectable
  lists.

  So two things HeyDiary used to express **collapse**:

  1. **The per-plan model hierarchy** (the free/pro/max rows of `plan_ai_models`) — a revision
     holds one model, so it cannot be represented. Only the free (= common) default row is kept,
     the rest are dropped, and `{:plan_models_flattened, …}` reports it. Per-plan model
     differentiation is now **the app's job** (or a future feature) — PromptOn does not know that
     axis.
  2. **Per-language temperatures** (when `ai_tasks.temperature` differs per language) — `params`
     is also a single map per revision. The common row's temperature is used and
     `{:language_temperatures_flattened, …}` reports it.

  Language itself does not collapse — every language has a Prompt (`default`/`ko` …) and the
  revision pins **all** of them. At request time the app picks with `prompt: "ko"`.

  ## Warnings

  - `{:plan_models_flattened, use_case_key, plans}` — the plans of the task's `plan_ai_models` rows
    that did not become the pin. Per-plan model differentiation is lost. **Needs confirmation**.
  - `{:language_temperatures_flattened, use_case_key, %{language => temperature}}` — temperatures
    differed per language. They collapse to the common row's single temperature. **Needs
    confirmation**.
  - `{:no_default_prompt, use_case_key, languages}` — only language rows exist and there is no
    common (NULL) row, so there is no `default` prompt. A request arriving without a name (`prompt`
    unset) is `unknown_prompt` → 404. **Needs confirmation**.
  - `{:no_free_default, use_case_key, plan}` — no `is_default` row at the free level, so the
    `plan`-level default row is used as the pin. Free users got "no rows" in HeyDiary but now
    resolve. **Needs confirmation**.
  - `{:ambiguous_default, use_case_key, plan, %{insertion_order:, highest_plan:}}` — more than one
    `is_default` row applies at that level, and the HeyDiary Registry (insertion order) and this
    tool (highest plan first) pick differently. **Needs confirmation**.
  - `{:no_plan_models, use_case_key}` — no `plan_ai_models` rows, so no Deployment is created.
  - `{:missing_task, use_case_key, source_task}` — no `ai_tasks` rows, so no prompts/deployment
    are created.
  - `{:unknown_task, task_name}` — a task in the dump that is not a migration target (ignored).
  """

  defstruct project: nil,
            environment: "production",
            models: [],
            use_cases: [],
            prompts: [],
            prompt_versions: [],
            deployments: [],
            warnings: []

  @type warning ::
          {:plan_models_flattened, String.t(), [String.t()]}
          | {:language_temperatures_flattened, String.t(), %{String.t() => float() | nil}}
          | {:no_default_prompt, String.t(), [String.t()]}
          | {:no_free_default, String.t(), String.t()}
          | {:ambiguous_default, String.t(), String.t(), map()}
          | {:no_plan_models, String.t()}
          | {:missing_task, String.t(), String.t()}
          | {:unknown_task, String.t()}

  @type t :: %__MODULE__{
          project: map(),
          environment: String.t(),
          models: [map()],
          use_cases: [map()],
          prompts: [map()],
          prompt_versions: [map()],
          deployments: [map()],
          warnings: [warning()]
        }

  @confirm_kinds [
    :plan_models_flattened,
    :language_temperatures_flattened,
    :no_default_prompt,
    :no_free_default,
    :ambiguous_default
  ]

  @doc "Warnings that need interactive confirmation (cannot proceed without `--yes`)."
  @spec confirmations(t()) :: [warning()]
  def confirmations(%__MODULE__{warnings: warnings}),
    do: Enum.filter(warnings, &(elem(&1, 0) in @confirm_kinds))

  @doc "Item count summary."
  @spec counts(t()) :: map()
  def counts(%__MODULE__{} = plan) do
    %{
      models: length(plan.models),
      use_cases: length(plan.use_cases),
      prompts: length(plan.prompts),
      prompt_versions: length(plan.prompt_versions),
      deployments: length(plan.deployments),
      pins: plan.deployments |> Enum.map(&length(&1.prompt_names)) |> Enum.sum(),
      warnings: length(plan.warnings)
    }
  end

  @doc "A warning as a human-readable sentence."
  @spec describe_warning(warning()) :: String.t()
  def describe_warning({:plan_models_flattened, key, plans}),
    do:
      "#{key}: plan_ai_models rows for #{inspect(plans)} cannot be represented — a deployment revision pins " <>
        "exactly one model, so the free/common default is kept and the rest are dropped; plan-differentiated " <>
        "models are now the app's job"

  def describe_warning({:language_temperatures_flattened, key, temperatures}),
    do:
      "#{key}: ai_tasks temperatures differ per language (#{inspect(temperatures)}) — a deployment revision has " <>
        "one params map, so the common (NULL language) temperature is used for every prompt"

  def describe_warning({:no_default_prompt, key, languages}),
    do:
      "#{key}: language rows #{inspect(languages)} exist but no NULL (common) row — there is no \"default\" " <>
        "prompt, so a request without an explicit prompt name resolves to unknown_prompt (404)"

  def describe_warning({:no_free_default, key, plan}),
    do:
      "#{key}: no is_default row at the free level — the #{plan} default is pinned instead, so free users now " <>
        "resolve (HeyDiary gave them \"no rows\")"

  def describe_warning({:ambiguous_default, key, plan, picks}),
    do:
      "#{key}: plan #{plan} has more than one applicable is_default row — HeyDiary Registry (insertion order) " <>
        "picks #{picks.insertion_order}, this import (highest plan first) pins #{picks.highest_plan}"

  def describe_warning({:no_plan_models, key}),
    do: "#{key}: no plan_ai_models rows — no deployment will be committed"

  def describe_warning({:missing_task, key, task}),
    do: "#{key}: no ai_tasks rows for #{task} — no prompt versions/deployment will be created"

  def describe_warning({:unknown_task, task}),
    do: "#{task}: task in dump is not a known HeyDiary use case — ignored"

  def describe_warning(other), do: inspect(other)
end
