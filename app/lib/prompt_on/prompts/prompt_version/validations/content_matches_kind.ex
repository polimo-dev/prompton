defmodule PromptOn.Prompts.PromptVersion.Validations.ContentMatchesKind do
  @moduledoc """
  Checks that active prompt versions are chat templates: `messages` must be non-empty and
  `text_template` is rejected. Historical text/embedding rows remain readable, but no new versions
  can be created for them. The Prompt is looked up in the same tenant only (a prompt_id of another
  project is "not found").
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Prompts.Prompt

  @impl true
  def validate(changeset, _opts, _context) do
    prompt_id = Ash.Changeset.get_attribute(changeset, :prompt_id)
    messages = Ash.Changeset.get_attribute(changeset, :messages) || []
    text_template = Ash.Changeset.get_attribute(changeset, :text_template)

    case prompt_context(prompt_id, changeset) do
      {:ok, kind} -> check(kind, messages, text_template)
      {:error, error} -> {:error, error}
    end
  end

  defp check(:chat, [], _text), do: invalid(:messages, "chat use case needs at least one message")

  defp check(:chat, _messages, text) when not is_nil(text),
    do: invalid(:text_template, "chat use case takes messages, not text_template")

  defp check(:chat, _messages, _text), do: :ok

  defp check(:text, _messages, _text),
    do: invalid(:prompt_id, "text use cases are no longer supported for prompt versions")

  defp check(:embedding, _messages, _text),
    do: invalid(:prompt_id, "embedding use cases are no longer supported for prompt versions")

  defp prompt_context(nil, _changeset),
    do:
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(field: :prompt_id, message: "is required")}

  defp prompt_context(prompt_id, changeset) do
    Prompt
    |> Ash.Query.filter(id == ^prompt_id)
    |> Ash.Query.load(use_case: [:kind, :archived_at])
    |> Ash.read_one(
      tenant: changeset.to_tenant || changeset.tenant,
      actor: PromptOn.SystemActor.new()
    )
    |> case do
      {:ok, %Prompt{name: name}} when name != "default" ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :prompt_id,
           message: "only the default prompt can be versioned"
         )}

      {:ok, %Prompt{archived_at: archived_at}} when not is_nil(archived_at) ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :prompt_id,
           message: "archived prompts cannot be versioned"
         )}

      {:ok, %Prompt{use_case: %{archived_at: archived_at}}} when not is_nil(archived_at) ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :prompt_id,
           message: "archived use cases cannot receive prompt versions"
         )}

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
