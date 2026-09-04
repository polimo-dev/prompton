defmodule PromptOn.Evals.EvaluationRun.Validations.TargetInTenant do
  @moduledoc """
  `EvaluationRun.:start`: the use case, environment, deployment and rubric must all be in this
  tenant and must agree with each other (ADR 0010 §2.6).

  Mirrors `PromptOn.Deployments.Deployment.Validations.TargetInTenant`: a FK alone does not keep
  out rows of another project, because attribute multitenancy does not restrict FKs to the tenant.
  On top of that it checks that the deployment really is a revision of this use case in this
  environment, and that the rubric belongs to the same use case — a number produced by another use
  case's rubric would be meaningless.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Deployments.Deployment
  alias PromptOn.Evals.Rubric
  alias PromptOn.Projects.Environment
  alias PromptOn.Prompts.UseCase

  @impl true
  def validate(changeset, _opts, _context) do
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]
    use_case_id = Ash.Changeset.get_attribute(changeset, :use_case_id)
    environment_id = Ash.Changeset.get_attribute(changeset, :environment_id)

    with {:ok, _use_case} <- fetch(UseCase, use_case_id, :use_case_id, "use case", opts),
         {:ok, _environment} <-
           fetch(Environment, environment_id, :environment_id, "environment", opts),
         {:ok, deployment} <-
           fetch(
             Deployment,
             Ash.Changeset.get_attribute(changeset, :deployment_id),
             :deployment_id,
             "deployment",
             opts
           ),
         :ok <- matches_deployment(deployment, use_case_id, environment_id),
         {:ok, rubric} <-
           fetch(
             Rubric,
             Ash.Changeset.get_attribute(changeset, :rubric_id),
             :rubric_id,
             "rubric",
             opts
           ) do
      matches_rubric(rubric, use_case_id)
    end
  end

  defp fetch(_resource, nil, field, label, _opts), do: invalid(field, "#{label} is required")

  defp fetch(resource, id, field, label, opts) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} ->
        invalid(field, "#{label} not found in this project")

      {:ok, %{archived_at: archived_at}} when not is_nil(archived_at) ->
        invalid(field, "#{label} is archived")

      {:ok, record} ->
        {:ok, record}

      {:error, error} ->
        {:error, error}
    end
  end

  defp matches_deployment(%Deployment{} = deployment, use_case_id, environment_id) do
    cond do
      deployment.use_case_id != use_case_id ->
        invalid(:deployment_id, "deployment belongs to another use case")

      deployment.environment_id != environment_id ->
        invalid(:deployment_id, "deployment belongs to another environment")

      true ->
        :ok
    end
  end

  defp matches_rubric(%Rubric{use_case_id: use_case_id}, use_case_id), do: :ok

  defp matches_rubric(%Rubric{}, _use_case_id),
    do: invalid(:rubric_id, "rubric belongs to another use case")

  defp invalid(field, message),
    do: {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
end
