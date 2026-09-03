defmodule PromptOn.Checks.ApiKeyActor do
  @moduledoc "Is the actor a `%PromptOn.Projects.ApiKey{}`? (for policy conditions)."

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_), do: "actor is an API key"

  @impl true
  def match?(%PromptOn.Projects.ApiKey{}, _context, _opts), do: true
  def match?(_, _, _), do: false
end
