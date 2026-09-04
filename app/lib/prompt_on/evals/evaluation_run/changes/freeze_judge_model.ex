defmodule PromptOn.Evals.EvaluationRun.Changes.FreezeJudgeModel do
  @moduledoc """
  `EvaluationRun.:start`: resolves the judge model and freezes it onto the run, together with the
  display copies of the rubric number and the deployment revision (ADR 0010 §4.4).

  Freezing matters: changing the organization's default judge model halfway through a run would
  otherwise make the run's own numbers incomparable with themselves. The resolution order is the
  rubric's override, then the organization's default, then `config :prompton, :judge_model`.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Deployments.Deployment
  alias PromptOn.Evals.{Judge, Rubric}

  @impl true
  def change(changeset, _opts, _context) do
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    with {:ok, %Rubric{} = rubric} <-
           read(Rubric, Ash.Changeset.get_attribute(changeset, :rubric_id), opts),
         {:ok, %Deployment{} = deployment} <-
           read(Deployment, Ash.Changeset.get_attribute(changeset, :deployment_id), opts),
         {:ok, organization_id} <- organization_id(opts) do
      Ash.Changeset.force_change_attributes(changeset, %{
        judge_model: Judge.model(rubric, organization_id),
        rubric_number: rubric.number,
        deployment_revision: deployment.revision
      })
    else
      _other -> changeset
    end
  end

  defp read(_resource, nil, _opts), do: :error

  defp read(resource, id, opts) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} -> :error
      {:ok, record} -> {:ok, record}
      {:error, _error} -> :error
    end
  end

  defp organization_id(opts) do
    case PromptOn.Projects.get_project(opts[:tenant], actor: opts[:actor]) do
      {:ok, %{organization_id: organization_id}} -> {:ok, organization_id}
      _other -> :error
    end
  end
end
