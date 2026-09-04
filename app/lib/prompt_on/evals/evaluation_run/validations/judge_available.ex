defmodule PromptOn.Evals.EvaluationRun.Validations.JudgeAvailable do
  @moduledoc """
  `EvaluationRun.:start`: refuse the run when the organization has no provider key
  (ADR 0010 §4.6).

  Starting a thousand jobs that will each fail with `:no_provider_key` is the worst of the three
  places this can be caught. The Evals panel disables the button before the click, and a key
  revoked mid-run is handled per result; this is the one that keeps a run from being born dead.
  """

  use Ash.Resource.Validation

  alias PromptOn.Evals.Judge

  @impl true
  def validate(changeset, _opts, _context) do
    changeset
    |> organization_id()
    |> Judge.available?()
    |> case do
      true ->
        :ok

      false ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :judge_model,
           message:
             "no provider key — add an OpenRouter key in Organization settings before running " <>
               "an evaluation"
         )}
    end
  end

  defp organization_id(changeset) do
    project_id = changeset.to_tenant || changeset.tenant

    case PromptOn.Projects.get_project(project_id, actor: PromptOn.SystemActor.new()) do
      {:ok, %{organization_id: organization_id}} -> organization_id
      _other -> nil
    end
  end
end
