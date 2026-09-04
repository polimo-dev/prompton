defmodule PromptOn.Deployments.Snapshot do
  @moduledoc """
  Assembles the **use-cases schema v4** of one environment (ADR 0007 revised 2026-09-01, plan.md
  §6.2 `GET /use-cases`): every live Deployment of that environment + the PromptVersions/Models
  the pins reference + UseCase metadata. It is a derived read result, not a resource.

  What changed from v2 is **the shape of a deployment entry**: rules, conditions and targets are
  gone, and each use_case key holds one
  `{id, revision, model_id, params, provider_options, prompt_pins}`. `dimensions` is dropped
  (context dimensions themselves were deleted). Normalization, canonical JSON, ETag and the polling
  contract are inherited unchanged.

  - The map contract is what `PromptOnSDK.UseCaseDocument.decode/1` reads without warnings (string
    keys, enum values as strings).
  - `prompt_versions/models` are normalized (deduplicated) by id at the top level. Only what the
    pins and models of live Deployments point at is included.
  - **All** non-archived UseCases are included; a use case without a live Deployment has no entry
    in `deployments` (the SDK resolves that use case as `{:error, :unresolved}`).
  - **ETag = sha256 of the canonical JSON body (sorted keys, no whitespace)**
    (`PromptOn.CanonicalJSON`). The body carries no time fields; `last_modified` is the latest
    change time of the Deployments, referenced resources, project and use cases (now when there is
    none) and is for the header.
  - Five round trips: environment(+project), use_cases, current deployments, prompt_versions,
    models. Reads run as the caller's actor: the ApiKey policies (own project, own environment,
    non-archived) are the snapshot rules. **Exception: models** are loaded by the ids the
    deployments point at, as the system actor of the same tenant, **regardless of status** (the
    `status` field is included): if a deprecated (or, defensively, archived) model were missing,
    the SDK would resolve `model: nil`.
  - `override_deployments: [%Deployment{}]` slots those Deployments into the live position of the
    same UseCase (past-revision simulation, internal `Deployment.:resolve`).
  """

  require Ash.Query

  alias PromptOn.CanonicalJSON
  alias PromptOn.Catalog.Model
  alias PromptOn.Deployments
  alias PromptOn.Deployments.Deployment
  alias PromptOn.Observability.PayloadPolicy
  alias PromptOn.Projects.Environment
  alias PromptOn.Prompts.{PromptVersion, UseCase}

  @schema_version 4

  @type result :: %{
          map: map(),
          body: binary(),
          etag: String.t(),
          last_modified: DateTime.t()
        }

  @doc """
  Assembles the snapshot. `opts`: `:actor` (required), `:tenant` (required when an Environment id is
  given), `:override_deployments`. Returns `{:error, :not_found}` when the environment does not
  exist (including when it is out of reach) or the project is archived.
  """
  @spec build(Environment.t() | Ash.UUID.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def build(env_or_id, opts) do
    actor = Keyword.fetch!(opts, :actor)
    tenant = Keyword.get(opts, :tenant) || tenant_of(env_or_id)
    read = [actor: actor, tenant: tenant]
    overrides = Keyword.get(opts, :override_deployments, [])

    with {:ok, env} <- load_environment(env_or_id, read),
         {:ok, use_cases} <- read_all(UseCase, :active, read),
         {:ok, deployments} <- read_current_deployments(env.id, read),
         deployments = apply_overrides(deployments, overrides),
         {:ok, prompt_versions} <-
           read_by_ids(PromptVersion, ids(deployments, &Deployment.prompt_version_ids/1), read),
         {:ok, models} <-
           read_by_ids(Model, ids(deployments, &Deployment.model_ids/1), system_read(env)) do
      map = assemble(env, use_cases, deployments, prompt_versions, models)
      body = CanonicalJSON.encode!(map)

      {:ok,
       %{
         map: map,
         body: body,
         etag: CanonicalJSON.etag(body),
         last_modified:
           last_modified([
             env,
             env.project | use_cases ++ deployments ++ prompt_versions ++ models
           ])
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # loads

  defp tenant_of(%Environment{project_id: project_id}), do: project_id
  defp tenant_of(_), do: nil

  defp load_environment(%Environment{} = env, read) do
    env |> Ash.load([:project], read) |> check_environment()
  end

  defp load_environment(id, read) do
    Environment
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load([:project])
    |> Ash.read_one(read)
    |> check_environment()
  end

  defp check_environment(
         {:ok, %Environment{archived_at: nil, project: %{archived_at: nil}} = env}
       ),
       do: {:ok, env}

  defp check_environment({:ok, _}), do: {:error, :not_found}
  defp check_environment({:error, error}), do: {:error, error}

  defp read_all(resource, action, read) do
    resource |> Ash.Query.for_read(action, %{}, read) |> Ash.read(read)
  end

  defp read_current_deployments(environment_id, read) do
    Deployments.current_deployments_for_environment(environment_id, read)
  end

  # Referenced models must be included regardless of status (deprecated/archived), so they are read
  # as the system actor of the same tenant. The ids came from Deployments the caller could read and
  # are bound to the tenant, so visibility does not widen.
  defp system_read(%Environment{project_id: project_id}),
    do: [actor: PromptOn.SystemActor.new(), tenant: project_id]

  defp read_by_ids(_resource, [], _read), do: {:ok, []}

  defp read_by_ids(resource, ids, read) do
    resource |> Ash.Query.filter(id in ^ids) |> Ash.read(read)
  end

  defp ids(deployments, fun), do: deployments |> Enum.flat_map(fun) |> Enum.uniq()

  defp apply_overrides(deployments, []), do: deployments

  defp apply_overrides(deployments, overrides) do
    overridden = MapSet.new(overrides, & &1.use_case_id)
    Enum.reject(deployments, &MapSet.member?(overridden, &1.use_case_id)) ++ overrides
  end

  # ---------------------------------------------------------------------------
  # assembly (plan.md §6.2, ADR 0007)

  defp assemble(env, use_cases, deployments, prompt_versions, models) do
    project = env.project
    use_case_keys = Map.new(use_cases, &{&1.id, &1.key})

    %{
      "schema_version" => @schema_version,
      "project" => project.slug,
      "environment" => env.slug,
      "use_cases" => Map.new(use_cases, &{&1.key, use_case_map(&1, project)}),
      "deployments" => deployments_map(deployments, use_case_keys),
      "prompt_versions" => Map.new(prompt_versions, &{&1.id, prompt_version_map(&1)}),
      "models" => Map.new(models, &{&1.id, model_map(&1)})
    }
  end

  # Live Deployments are indexed by use_case key. Deployments of archived use cases (no key) are
  # not included.
  defp deployments_map(deployments, use_case_keys) do
    for deployment <- deployments,
        key = Map.get(use_case_keys, deployment.use_case_id),
        not is_nil(key),
        into: %{} do
      {key, Deployment.to_snapshot_map(deployment)}
    end
  end

  defp use_case_map(use_case, project) do
    %{
      "id" => use_case.id,
      "kind" => Atom.to_string(use_case.kind),
      "input_schema" => Enum.map(List.wrap(use_case.input_schema), &variable_map/1),
      "default_params" => PromptOnSDK.Params.stringify_keys(use_case.default_params),
      "payload_policy" =>
        project.payload_policy
        |> PayloadPolicy.effective(use_case.payload_policy)
        |> PayloadPolicy.to_map()
    }
  end

  defp variable_map(variable) do
    %{
      "name" => variable.name,
      "type" => Atom.to_string(variable.type),
      "required" => variable.required? == true
    }
  end

  defp prompt_version_map(version) do
    %{
      "id" => version.id,
      "prompt_id" => version.prompt_id,
      "number" => version.number,
      "engine" => Atom.to_string(version.engine),
      "messages" => Enum.map(List.wrap(version.messages), &message_map/1),
      "text_template" => version.text_template
    }
  end

  defp message_map(message) do
    base = %{"role" => Atom.to_string(message.role), "content" => message.content}
    if is_nil(message.name), do: base, else: Map.put(base, "name", message.name)
  end

  defp model_map(model) do
    %{
      "id" => model.id,
      "provider" => Atom.to_string(model.provider),
      "model_id" => model.model_id,
      "display_name" => model.display_name,
      "metadata" => PromptOnSDK.Params.stringify_keys(model.metadata),
      "provider_options" => PromptOnSDK.Params.stringify_keys(model.provider_options),
      "capabilities" => Enum.map(List.wrap(model.capabilities), &Atom.to_string/1),
      "status" => Atom.to_string(model.status)
    }
  end

  # Deployments are immutable and have no `updated_at`; the commit time (`inserted_at`) stands in.
  defp last_modified(records) do
    records
    |> Enum.map(&(Map.get(&1, :updated_at) || Map.get(&1, :inserted_at)))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> DateTime.utc_now() end)
    |> DateTime.truncate(:second)
  end
end
