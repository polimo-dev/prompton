defmodule PromptOn.Projects.Project.Changes.CreateDefaultEnvironments do
  @moduledoc """
  Creates the `production` (protected) / `staging` environments right after project creation
  (plan.md §4.1).
  """

  use Ash.Resource.Change

  alias PromptOn.Projects

  @defaults [
    %{slug: "production", name: "Production", protected?: true, position: 0},
    %{slug: "staging", name: "Staging", protected?: false, position: 1}
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, project ->
      Enum.reduce_while(@defaults, {:ok, project}, fn attrs, acc ->
        case Projects.add_environment(attrs,
               tenant: project.id,
               actor: PromptOn.SystemActor.new()
             ) do
          {:ok, _env} -> {:cont, acc}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end)
  end
end
