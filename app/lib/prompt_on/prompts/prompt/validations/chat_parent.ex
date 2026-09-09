defmodule PromptOn.Prompts.Prompt.Validations.ChatParent do
  @moduledoc "Rejects writes to prompts whose parent use case is archived or not chat."

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Prompts.UseCase

  @impl true
  def validate(changeset, _opts, _context) do
    use_case_id = Ash.Changeset.get_attribute(changeset, :use_case_id)
    tenant = changeset.to_tenant || changeset.tenant

    if is_nil(use_case_id) or is_nil(tenant) do
      :ok
    else
      UseCase
      |> Ash.Query.filter(id == ^use_case_id and kind == :chat and is_nil(archived_at))
      |> Ash.read_one(tenant: tenant, actor: PromptOn.SystemActor.new())
      |> case do
        {:ok, %UseCase{}} ->
          :ok

        {:ok, nil} ->
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :use_case_id,
             message: "use case not found in this project (or not chat/archived)"
           )}

        {:error, error} ->
          {:error, error}
      end
    end
  end
end
