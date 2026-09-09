defmodule PromptOn.Prompts.Prompt.Validations.UseCaseInTenant do
  @moduledoc """
  Backward-compatible alias for the chat parent prompt write guard.
  """

  use Ash.Resource.Validation

  defdelegate validate(changeset, opts, context),
    to: PromptOn.Prompts.Prompt.Validations.ChatParent
end
