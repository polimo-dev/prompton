defmodule PromptOn.Observability.Generation.Changes.TruncateErrorMessage do
  @moduledoc "Truncates `error_message` to 2KB (plan.md §5.7). Respects UTF-8 boundaries."

  use Ash.Resource.Change

  alias PromptOn.Observability.Ingest.Truncation

  @max_bytes 2_048

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :error_message) do
      message when is_binary(message) and byte_size(message) > @max_bytes ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :error_message,
          Truncation.head(message, @max_bytes)
        )

      _ ->
        changeset
    end
  end

  @doc "The error_message cap (bytes)."
  def max_bytes, do: @max_bytes
end
