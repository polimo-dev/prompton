defmodule PromptOn.Prompts.Prompt.Validations.DefaultOnly do
  @moduledoc "Rejects active prompt writes except the canonical default prompt."

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    cond do
      archived?(changeset.data) ->
        invalid(:archived_at, "archived prompts cannot be changed")

      current_name(changeset) != "default" ->
        invalid(:name, "only the default prompt is supported")

      next_name(changeset) != "default" ->
        invalid(:name, next_name_message(changeset))

      true ->
        :ok
    end
  end

  defp archived?(%{archived_at: archived_at}), do: not is_nil(archived_at)
  defp archived?(_), do: false

  defp current_name(%{data: %{name: name}}) when is_binary(name), do: name
  defp current_name(changeset), do: next_name(changeset)

  defp next_name(changeset), do: Ash.Changeset.get_attribute(changeset, :name) || "default"

  defp next_name_message(%{action: %{name: :open}}), do: "only the default prompt is supported"
  defp next_name_message(_changeset), do: "prompt name must remain default"

  defp invalid(field, message),
    do: {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
end
