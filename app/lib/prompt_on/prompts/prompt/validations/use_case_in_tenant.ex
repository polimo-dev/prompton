defmodule PromptOn.Prompts.Prompt.Validations.UseCaseInTenant do
  @moduledoc """
  Checks that `use_case_id` points at a non-archived UseCase of the **same project (tenant)**. A FK
  alone does not keep out a UseCase of another project (attribute multitenancy does not restrict
  FKs to the tenant).
  """

  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    use_case_id = Ash.Changeset.get_attribute(changeset, :use_case_id)
    tenant = changeset.to_tenant || changeset.tenant

    if is_nil(use_case_id) or is_nil(tenant) do
      :ok
    else
      PromptOn.Prompts.UseCase
      |> Ash.Query.filter(id == ^use_case_id and is_nil(archived_at))
      |> Ash.read_one(tenant: tenant, actor: PromptOn.SystemActor.new())
      |> case do
        {:ok, %PromptOn.Prompts.UseCase{}} ->
          :ok

        {:ok, nil} ->
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :use_case_id,
             message: "use case not found in this project (or archived)"
           )}

        {:error, error} ->
          {:error, error}
      end
    end
  end
end
