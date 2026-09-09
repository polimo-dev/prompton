defmodule PromptOn.Prompts.UseCase.Validations.ChatOnly do
  @moduledoc """
  Keeps authoring actions chat-only while legacy text/embedding rows remain readable.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :kind) || existing_kind(changeset) || :chat

    if kind == :chat do
      :ok
    else
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :kind,
         message: "only chat use cases are supported"
       )}
    end
  end

  defp existing_kind(%{data: %{kind: kind}}), do: kind
  defp existing_kind(_changeset), do: nil
end
