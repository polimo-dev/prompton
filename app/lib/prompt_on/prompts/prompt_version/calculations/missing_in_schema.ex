defmodule PromptOn.Prompts.PromptVersion.Calculations.MissingInSchema do
  @moduledoc """
  The names in `detected_variables` that are not declared in the UseCase `input_schema` (for UI
  warnings, plan.md §5.5). Computed by loading `prompt.use_case.input_schema`.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context),
    do: [:detected_variables, prompt: [use_case: [:input_schema]]]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn version ->
      declared =
        version.prompt.use_case.input_schema
        |> List.wrap()
        |> MapSet.new(& &1.name)

      Enum.reject(version.detected_variables || [], &MapSet.member?(declared, &1))
    end)
  end
end
