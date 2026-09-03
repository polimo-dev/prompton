defmodule PromptOn.Checks.SystemActor do
  @moduledoc "Is the actor a `%PromptOn.SystemActor{}`?"

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_), do: "actor is the system actor"

  @impl true
  def match?(%PromptOn.SystemActor{}, _context, _opts), do: true
  def match?(_, _, _), do: false
end
