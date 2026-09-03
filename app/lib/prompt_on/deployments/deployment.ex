defmodule PromptOn.Deployments.Deployment do
  @moduledoc """
  Everything about **what runs right now** for a given UseCase x Environment (ADR 0007 + the
  2026-09-01 revision "one pin").

  - **Immutable, append-only**: rows accumulate by revision number (`revision`, monotonically
    increasing from 1 within use_case x env). There is no status column: the **live deployment of
    `(use_case, environment)` is the highest revision**. "activate" is committing a new revision;
    "rollback" is committing a new revision with the contents of a past one (inheriting the
    numbering, history and rollback properties of ADR 0002).
  - **A revision is a pin, not a router**: rules, conditions, targets, weights, A/B and
    context-dimension routing are all gone. One revision is **one** model (`model_id` + `params` +
    `provider_options`) plus a map that pins this use case's prompts by name
    (`prompt_pins`: `%{"default" => version_id, "ko" => version_id}`), and nothing else.
  - **Selection at request time is by prompt name only**: when the app sends `prompt: "ko"` that pin
    is used (default `"default"`). This is now all there is to language branching.
  - The `:commit` validations (`Validations.TargetInTenant` + `Validations.Committable`) replace the
    v1 activation gate: the target UseCase/Environment must be in the same tenant and not archived,
    the model must be in the same project, `active` and not archived, each pin name must be a live
    Prompt name of this use case and its version must belong to that Prompt, `kind :embedding` must
    have empty pins, and every other kind must pin at least the `default` prompt.
  - The `:resolve` generic action delegates to the same `PromptOnSDK.Resolver` the SDK uses (after
    assembling snapshot v3).
  - An ApiKey reads only the Deployments of its own project (tenant-pinned). The environment is
    chosen by a request parameter, so it is not bound to the key. Writes are forbidden.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Deployments,
    fragments: [PromptOn.ProjectScoped]

  alias PromptOn.Deployments.Deployment.{Actions, Changes, Validations}

  postgres do
    table "deployments"
  end

  actions do
    defaults [:read]

    create :commit do
      description """
      Commits a new revision. `revision` is `max+1` after locking use_case x env. The moment it is
      committed it becomes the live configuration of that (use_case, env).
      """

      accept [
        :use_case_id,
        :environment_id,
        :model_id,
        :params,
        :provider_options,
        :prompt_pins,
        :committed_by
      ]

      validate Validations.TargetInTenant
      validate Validations.Committable
      change Changes.SetCommitter
      change Changes.AssignRevision
    end

    create :rollback do
      description """
      **Commits a new revision** with the pins (model, params, provider_options, prompt_pins) of the
      `source_deployment_id` revision (rows are immutable, so this is a re-commit rather than a
      rewind). The source must be in the same tenant and the same (use_case, environment).
      """

      argument :source_deployment_id, :uuid, allow_nil?: false
      accept [:use_case_id, :environment_id, :committed_by]

      change Changes.CopyFromSource
      validate Validations.TargetInTenant
      validate Validations.Committable
      change Changes.SetCommitter
      change Changes.AssignRevision
    end

    read :current do
      description "Live deployment of (use_case, environment) = the highest revision; nil if none."
      argument :use_case_id, :uuid, allow_nil?: false
      argument :environment_id, :uuid, allow_nil?: false
      get? true

      filter expr(use_case_id == ^arg(:use_case_id) and environment_id == ^arg(:environment_id))
      prepare build(sort: [revision: :desc], limit: 1)
    end

    read :current_for_environment do
      description """
      The live deployments of **every use case** in one environment (one row per use_case: its
      highest revision). This is the read snapshot assembly uses.
      """

      argument :environment_id, :uuid, allow_nil?: false

      filter expr(environment_id == ^arg(:environment_id))
      prepare build(distinct: [:use_case_id], distinct_sort: [revision: :desc])
    end

    read :current_in_project do
      description """
      One row per (use_case, environment) across the whole project (its highest revision). Used by
      the archive guards (model/version reference checks) when they ask "what is live right now".
      """

      prepare build(distinct: [:use_case_id, :environment_id], distinct_sort: [revision: :desc])
    end

    read :history do
      description "Every revision of (use_case, environment), newest first."
      argument :use_case_id, :uuid, allow_nil?: false
      argument :environment_id, :uuid, allow_nil?: false

      filter expr(use_case_id == ^arg(:use_case_id) and environment_id == ^arg(:environment_id))
      prepare build(sort: [revision: :desc])
    end

    action :resolve, :map do
      description """
      Assembles the environment snapshot (v3) with the `deployment_id` revision slotted into the
      live position and resolves it with `PromptOnSDK.Resolver.resolve/3` (the same code as the
      SDK). Passing a past revision is a simulation. `prompt` is the prompt name to select (default
      `"default"`; ignored for `kind :embedding`). The result is a `%PromptOnSDK.Resolution{}`
      unpacked into a map.
      """

      argument :deployment_id, :uuid, allow_nil?: false
      argument :prompt, :string
      run Actions.Resolve
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    bypass [PromptOn.Checks.ApiKeyActor, action_type(:read)] do
      description """
      ApiKey reads are always tenant-pinned: trusting the tenant option alone would let another
      project id through. The environment is not pinned: keys are not bound to an environment
      (2026-09-01) and the environment is chosen by a request parameter.
      """

      authorize_if expr(project_id == ^actor(:project_id))
    end

    policy [PromptOn.Checks.ApiKeyActor, action_type([:create, :update, :destroy])] do
      forbid_if always()
    end

    policy [PromptOn.Checks.ApiKeyActor, action(:resolve)] do
      authorize_if {PromptOn.Checks.ApiKeyScope, scope: :resolve}
    end

    policy action(:resolve) do
      description "Visibility is enforced by the inner Deployment read (own project / member)."
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if PromptOn.Checks.ProjectMember
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if PromptOn.Checks.ProjectMember
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :revision, :integer do
      description "Starts at 1 per use_case x environment and only grows; the highest is live."
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :model_id, :uuid do
      description "Catalog Model this revision calls. **One** per revision (no A/B, no weights)."
      allow_nil? false
      public? true
    end

    attribute :params, :map do
      description "Model call parameters. Layered on top of `UseCase.default_params`."
      allow_nil? false
      public? true
      default %{}
    end

    attribute :provider_options, :map do
      description "Provider options. Layered on top of `Model.provider_options`."
      allow_nil? false
      public? true
      default %{}
    end

    attribute :prompt_pins, :map do
      description """
      Prompt **name -> PromptVersion id**. The name is what the app selects with `prompt: "ko"`.
      `kind :embedding` use cases have an empty map (there is no prompt).
      """

      allow_nil? false
      public? true
      default %{}
    end

    attribute :committed_by, :uuid do
      description "Id of the user who committed. nil for ApiKey/system commits."
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :use_case, PromptOn.Prompts.UseCase do
      allow_nil? false
      public? true
    end

    belongs_to :environment, PromptOn.Projects.Environment do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_revision, [:use_case_id, :environment_id, :revision]
  end

  @doc "PromptVersion ids the pins point at (deduplicated)."
  @spec prompt_version_ids(t()) :: [Ash.UUID.t()]
  def prompt_version_ids(%__MODULE__{prompt_pins: pins}) when is_map(pins),
    do: pins |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.uniq()

  def prompt_version_ids(%__MODULE__{}), do: []

  @doc "Model ids this revision references (0 or 1: a revision has one model)."
  @spec model_ids(t()) :: [Ash.UUID.t()]
  def model_ids(%__MODULE__{model_id: nil}), do: []
  def model_ids(%__MODULE__{model_id: id}), do: [id]

  @doc "Normalizes a pin map to string keys/values (the same shape as a jsonb round trip)."
  @spec normalize_pins(term()) :: %{String.t() => String.t()}
  def normalize_pins(pins) when is_map(pins) do
    Map.new(pins, fn {name, version_id} -> {to_string(name), to_string(version_id)} end)
  end

  def normalize_pins(_pins), do: %{}

  @doc "The snapshot v3 `deployments[use_case_key]` entry."
  @spec to_snapshot_map(t()) :: map()
  def to_snapshot_map(%__MODULE__{} = deployment) do
    %{
      "id" => deployment.id,
      "revision" => deployment.revision,
      "model_id" => deployment.model_id,
      "params" => PromptOnSDK.Params.stringify_keys(deployment.params),
      "provider_options" => PromptOnSDK.Params.stringify_keys(deployment.provider_options),
      "prompt_pins" => normalize_pins(deployment.prompt_pins)
    }
  end
end
