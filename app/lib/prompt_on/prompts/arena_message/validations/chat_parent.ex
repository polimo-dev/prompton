defmodule PromptOn.Prompts.ArenaMessage.Validations.ChatParent do
  @moduledoc "Rejects new arena writes for archived or non-chat use cases."

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
          invalid(:use_case_id, "use case not found in this project (or not chat/archived)")

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp invalid(field, message),
    do: {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
end
