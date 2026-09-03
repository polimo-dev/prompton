defmodule PromptOn.Deployments.Deployment.Validations.TargetInTenant do
  @moduledoc """
  Checks that `use_case_id` / `environment_id` point at a non-archived UseCase / Environment of the
  **same project (tenant)** (inherited from the validation of the same name on v1 Release).

  A FK alone does not keep out rows of another project: attribute multitenancy does not restrict
  FKs to the tenant.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Projects.Environment
  alias PromptOn.Prompts.UseCase

  @impl true
  def validate(changeset, _opts, _context) do
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    with :ok <-
           check(
             UseCase,
             Ash.Changeset.get_attribute(changeset, :use_case_id),
             :use_case_id,
             "use case",
             opts
           ) do
      check(
        Environment,
        Ash.Changeset.get_attribute(changeset, :environment_id),
        :environment_id,
        "environment",
        opts
      )
    end
  end

  defp check(_resource, nil, field, _label, _opts), do: invalid(field, "is required")

  defp check(resource, id, field, label, opts) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} -> invalid(field, "#{label} not found in this project")
      {:ok, %{archived_at: nil}} -> :ok
      {:ok, _archived} -> invalid(field, "#{label} is archived")
      {:error, error} -> {:error, error}
    end
  end

  defp invalid(field, message),
    do: {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
end
