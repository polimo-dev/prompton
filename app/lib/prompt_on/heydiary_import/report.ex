defmodule PromptOn.HeyDiaryImport.Report do
  @moduledoc """
  Renders the migration plan / run summary / verification result as human-readable text
  (fixed-width tables). Printed by `mix prompton.import_heydiary`. Pure functions — tests can
  check them as strings.
  """

  alias PromptOn.HeyDiaryImport.Plan

  @doc "The full plan report."
  @spec plan(Plan.t()) :: String.t()
  def plan(%Plan{} = plan) do
    counts = Plan.counts(plan)

    [
      "HeyDiary import plan — project #{plan.project.slug} (#{plan.project.name}), environment #{plan.environment}",
      "",
      "Models (#{counts.models})",
      table(
        ["provider", "model_id", "display_name", "provider_options"],
        Enum.map(
          plan.models,
          &[&1.provider, &1.model_id, &1.display_name, inspect(&1.provider_options)]
        )
      ),
      "",
      "Use cases (#{counts.use_cases})",
      table(
        ["key", "kind", "default_params", "prompts"],
        Enum.map(plan.use_cases, fn uc ->
          [
            uc.key,
            uc.kind,
            inspect(uc.default_params),
            plan.prompts
            |> Enum.filter(&(&1.use_case_key == uc.key))
            |> Enum.map_join(",", & &1.name)
          ]
        end)
      ),
      "",
      "Deployments (#{counts.deployments}; #{counts.pins} pinned prompts — one model each, no rules)",
      table(
        ["use case", "model", "params", "provider_options", "pinned prompts"],
        Enum.map(plan.deployments, fn d ->
          {_provider, model_id} = d.model

          [
            d.use_case_key,
            model_id,
            inspect(d.params),
            inspect(d.provider_options),
            pins(d.prompt_names)
          ]
        end)
      ),
      "",
      warnings(plan)
    ]
    |> Enum.join("\n")
  end

  defp pins([]), do: "(none)"
  defp pins(names), do: Enum.join(names, ",")

  @doc "The list of warnings."
  @spec warnings(Plan.t()) :: String.t()
  def warnings(%Plan{warnings: []}), do: "Warnings: none"

  def warnings(%Plan{warnings: warnings} = plan) do
    confirmations = Plan.confirmations(plan)

    lines =
      Enum.map(warnings, fn w ->
        marker = if w in confirmations, do: "[confirm] ", else: "          "
        marker <> Plan.describe_warning(w)
      end)

    Enum.join(["Warnings (#{length(warnings)}):" | lines], "\n")
  end

  @doc "The run summary."
  @spec summary(map()) :: String.t()
  def summary(summary) do
    c = summary.counts

    [
      "Imported into project #{summary.project_slug} (#{summary.project_id})" <>
        if(summary.reused_project?, do: " [existing project]", else: " [new project]"),
      "environment #{summary.environment} (#{summary.environment_id})",
      "models #{c.models} · use cases #{c.use_cases} · prompts #{c.prompts} · prompt versions #{c.prompt_versions} · " <>
        "deployments #{c.deployments} (#{c.pins} pinned prompts)"
    ]
    |> Enum.join("\n")
  end

  @doc "The verification result."
  @spec mismatches([map()]) :: String.t()
  def mismatches([]),
    do:
      "Verify: OK — HeyDiary build_llm_config == PromptOnSDK.Resolver for every (task, language)"

  def mismatches(mismatches) do
    rows =
      Enum.map(mismatches, fn m ->
        [
          m.use_case,
          inspect(m.language),
          m.prompt,
          m.field,
          inspect(m.heydiary, limit: 8, printable_limit: 60),
          inspect(m.prompton, limit: 8, printable_limit: 60)
        ]
      end)

    "Verify: #{length(mismatches)} mismatch(es)\n" <>
      table(["use_case", "language", "prompt", "field", "heydiary", "prompton"], rows)
  end

  @doc "A fixed-width table (header + rows). Cells are values that `to_string` accepts."
  @spec table([String.t()], [[term()]]) :: String.t()
  def table(headers, rows) do
    rows = Enum.map(rows, fn row -> Enum.map(row, &cell/1) end)
    widths = Enum.map(headers, &String.length/1)

    widths =
      Enum.reduce(rows, widths, fn row, widths ->
        Enum.zip_with(widths, row, fn w, c -> max(w, String.length(c)) end)
      end)

    line = fn cells ->
      "  " <>
        (cells
         |> Enum.zip(widths)
         |> Enum.map_join("  ", fn {c, w} -> String.pad_trailing(c, w) end)
         |> String.trim_trailing())
    end

    separator = "  " <> Enum.map_join(widths, "  ", &String.duplicate("-", &1))

    Enum.join([line.(headers), separator | Enum.map(rows, line)], "\n")
  end

  defp cell(nil), do: "-"
  defp cell(value) when is_binary(value), do: value
  defp cell(value) when is_atom(value), do: Atom.to_string(value)
  defp cell(value), do: to_string(value)
end
