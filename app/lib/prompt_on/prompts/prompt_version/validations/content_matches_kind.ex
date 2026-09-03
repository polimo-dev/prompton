defmodule PromptOn.Prompts.PromptVersion.Validations.ContentMatchesKind do
  @moduledoc """
  Checks that the template shape matches the use case `kind` (plan.md §5.5 "messages and
  text_template are mutually exclusive"): `:chat` -> `messages` non-empty and no `text_template`,
  `:text` -> `text_template` present and `messages` empty, `:embedding` -> no prompt version can be
  created at all. The Prompt is looked up in the same tenant only (a prompt_id of another project
  is "not found").
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Prompts.Prompt

  @impl true
  def validate(changeset, _opts, _context) do
    prompt_id = Ash.Changeset.get_attribute(changeset, :prompt_id)
    messages = Ash.Changeset.get_attribute(changeset, :messages) || []
    text_template = Ash.Changeset.get_attribute(changeset, :text_template)

    case use_case_kind(prompt_id, changeset) do
      {:ok, kind} -> check(kind, messages, text_template)
      {:error, error} -> {:error, error}
    end
  end

  defp check(:chat, [], _text), do: invalid(:messages, "chat use case needs at least one message")

  defp check(:chat, _messages, text) when not is_nil(text),
    do: invalid(:text_template, "chat use case takes messages, not text_template")

  defp check(:chat, _messages, _text), do: :ok

  defp check(:text, _messages, nil),
    do: invalid(:text_template, "text use case needs text_template")

  defp check(:text, [_ | _], _text),
    do: invalid(:messages, "text use case takes text_template, not messages")

  defp check(:text, _messages, _text), do: :ok

  defp check(:embedding, _messages, _text),
    do: invalid(:prompt_id, "embedding use cases have no prompt versions")

  defp use_case_kind(nil, _changeset),
    do:
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(field: :prompt_id, message: "is required")}

  defp use_case_kind(prompt_id, changeset) do
    Prompt
    |> Ash.Query.filter(id == ^prompt_id)
    |> Ash.Query.load(use_case: [:kind])
    |> Ash.read_one(
      tenant: changeset.to_tenant || changeset.tenant,
      actor: PromptOn.SystemActor.new()
    )
    |> case do
      {:ok, %Prompt{use_case: %{kind: kind}}} ->
        {:ok, kind}

      {:ok, nil} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :prompt_id,
           message: "prompt not found in this project"
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp invalid(field, message),
    do: {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
end
