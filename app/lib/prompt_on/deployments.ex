defmodule PromptOn.Deployments do
  @moduledoc """
  Deployment and resolution domain (ADR 0007, revised 2026-09-01): `Deployment` (the immutable
  revision of a use_case x env) and snapshot assembly (`PromptOn.Deployments.Snapshot`).

  A revision is a **pin, not a router**: rules, conditions, targets, weights, A/B and
  context-dimension routing are all gone. One revision is one model
  (`model_id`/`params`/`provider_options`) plus a version pin per prompt name (`prompt_pins`).
  Selection at request time is by a single prompt name (`prompt`, default `"default"`) and nothing
  else.

  - `commit_deployment/2`: commits a new revision. The moment it is committed it is the live
    configuration of that (use_case, env).
  - `rollback_deployment/3`: commits a new revision with the pins of a past revision.
  - `current_deployment/3`: the live deployment (highest revision) of (use_case, env), or nil.
  - `current_deployments_for_environment/2`: the live deployments of every use case in one
    environment (for snapshot assembly).
  - `deployment_history/3`: every revision of (use_case, env), newest first.
  - `resolve_deployment/3`: runs the SDK Resolver over a snapshot with that revision slotted into
    the live position.

  Plain functions other domains call as hooks (run as the system actor):

  - `referencing_prompt_version?/2`: PromptVersion reference guard
  - `referencing_model?/2`: Model `:archive` guard (`:deprecate` is not blocked; the model stays in
    the snapshot)

  Both look at **live revisions only** (the highest revision per use_case x environment); past
  revisions are just history.
  """

  use Ash.Domain,
    otp_app: :prompton,
    extensions: [AshAdmin.Domain]

  alias PromptOn.Deployments.Deployment

  admin do
    show? true
  end

  resources do
    resource PromptOn.Deployments.Deployment do
      define :commit_deployment, action: :commit
      define :rollback_deployment, action: :rollback, args: [:source_deployment_id]
      define :get_deployment, action: :read, get_by: [:id], not_found_error?: false

      define :current_deployment,
        action: :current,
        args: [:use_case_id, :environment_id],
        not_found_error?: false

      define :current_deployments_for_environment,
        action: :current_for_environment,
        args: [:environment_id]

      define :deployment_history, action: :history, args: [:use_case_id, :environment_id]
      define :current_deployments_in_project, action: :current_in_project
      define :resolve_deployment, action: :resolve, args: [:deployment_id]
    end
  end

  @doc "Does any **live** deployment of the project pin this PromptVersion?"
  @spec referencing_prompt_version?(Ash.UUID.t(), Ash.UUID.t()) :: boolean()
  def referencing_prompt_version?(project_id, prompt_version_id) do
    project_id
    |> live_deployments()
    |> Enum.any?(&(prompt_version_id in Deployment.prompt_version_ids(&1)))
  end

  @doc "Does any **live** deployment of the project point at this Model?"
  @spec referencing_model?(Ash.UUID.t(), Ash.UUID.t()) :: boolean()
  def referencing_model?(project_id, model_id) do
    project_id
    |> live_deployments()
    |> Enum.any?(&(model_id in Deployment.model_ids(&1)))
  end

  # Pins are jsonb, so they are not scanned in SQL: read only the project's live revisions and check
  # them in memory (one row per use_case x environment, bounded by project size).
  defp live_deployments(project_id) do
    case current_deployments_in_project(tenant: project_id, actor: PromptOn.SystemActor.new()) do
      {:ok, deployments} -> deployments
      {:error, _} -> []
    end
  end
end
