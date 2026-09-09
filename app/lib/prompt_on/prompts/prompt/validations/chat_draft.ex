defmodule PromptOn.Prompts.Prompt.Validations.ChatDraft do
  @moduledoc "Validates the mutable draft slot accepts chat message drafts only."

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :draft) do
      nil -> :ok
      %{} = draft -> validate_draft(draft)
      _other -> invalid(:draft, "draft must be an object")
    end
  end

  defp validate_draft(draft) do
    messages = Map.get(draft, "messages")
    text_template = Map.get(draft, "text_template")

    cond do
      not is_nil(text_template) ->
        invalid(:draft, "chat drafts use messages, not text_template")

      not is_list(messages) ->
        invalid(:draft, "chat drafts need messages")

      not Enum.all?(messages, &message?/1) ->
        invalid(:draft, "draft messages must include role and content")

      true ->
        :ok
    end
  end

  defp message?(%{"role" => role, "content" => content})
       when role in ["system", "user", "assistant"] and is_binary(content),
       do: true

  defp message?(_message), do: false

  defp invalid(field, message),
    do: {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
end
