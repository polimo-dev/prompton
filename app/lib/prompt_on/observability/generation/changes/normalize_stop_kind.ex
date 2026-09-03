defmodule PromptOn.Observability.Generation.Changes.NormalizeStopKind do
  @moduledoc """
  When `stop_kind` is empty and `finish_reason` is present, fills it with
  `PromptOnSDK.StopKind.normalize/1` (the plan.md §5.7 normalization table -- the same code as the
  SDK adapter). When both are missing it stays nil (error records, embeddings).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    stop_kind = Ash.Changeset.get_attribute(changeset, :stop_kind)
    finish_reason = Ash.Changeset.get_attribute(changeset, :finish_reason)

    case {stop_kind, finish_reason} do
      {nil, reason} when is_binary(reason) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :stop_kind,
          PromptOnSDK.StopKind.normalize(reason)
        )

      _ ->
        changeset
    end
  end
end
