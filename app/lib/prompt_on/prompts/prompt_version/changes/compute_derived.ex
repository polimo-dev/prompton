defmodule PromptOn.Prompts.PromptVersion.Changes.ComputeDerived do
  @moduledoc """
  Computes the derived values on save: `detected_variables` (the sorted union of the top-level
  variables of every template fragment) and `content_sha256` (the hash of the canonical
  serialization). It uses `PromptOnSDK.Template.variables/1` directly, so the result matches the
  SDK. With `engine: :raw` there are no variables (the text is used verbatim).
  """

  use Ash.Resource.Change

  alias PromptOn.Prompts.PromptVersion

  @impl true
  def change(changeset, _opts, _context) do
    engine = Ash.Changeset.get_attribute(changeset, :engine) || :liquid
    messages = Ash.Changeset.get_attribute(changeset, :messages) || []
    text_template = Ash.Changeset.get_attribute(changeset, :text_template)

    variables =
      case engine do
        :raw -> []
        _ -> detect_variables(messages, text_template)
      end

    changeset
    |> Ash.Changeset.force_change_attribute(:detected_variables, variables)
    |> Ash.Changeset.force_change_attribute(
      :content_sha256,
      PromptVersion.content_hash(engine, messages, text_template)
    )
  end

  defp detect_variables(messages, text_template) do
    sources = Enum.map(messages, &content_of/1) ++ List.wrap(text_template)

    sources
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&PromptOnSDK.Template.variables/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp content_of(%{content: c}), do: c
  defp content_of(%{"content" => c}), do: c
  defp content_of(_), do: nil
end
