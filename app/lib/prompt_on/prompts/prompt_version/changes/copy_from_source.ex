defmodule PromptOn.Prompts.PromptVersion.Changes.CopyFromSource do
  @moduledoc """
  `:fork`: copies `engine/messages/text_template` from the source version (`source_version_id`) and
  records `parent_version_id`. The target prompt is the `prompt_id` argument (the source's prompt
  when absent). The number is assigned afterwards by `AssignNumber`. The source is looked up in the
  same tenant only.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Prompts.PromptVersion

  @impl true
  def change(changeset, _opts, _context) do
    source_id = Ash.Changeset.get_argument(changeset, :source_version_id)
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    PromptVersion
    |> Ash.Query.filter(id == ^source_id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %PromptVersion{} = source} ->
        target_prompt_id = Ash.Changeset.get_argument(changeset, :prompt_id) || source.prompt_id

        Ash.Changeset.force_change_attributes(changeset, %{
          prompt_id: target_prompt_id,
          parent_version_id: source.id,
          engine: source.engine,
          messages: Enum.map(source.messages || [], &Map.from_struct/1),
          text_template: source.text_template
        })

      {:ok, nil} ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidArgument.exception(
            field: :source_version_id,
            message: "source version not found in this project"
          )
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end
end
