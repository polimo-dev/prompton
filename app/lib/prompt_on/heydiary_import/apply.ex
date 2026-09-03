defmodule PromptOn.HeyDiaryImport.Apply do
  @moduledoc """
  Runs a migration plan (`PromptOn.HeyDiaryImport.Plan`) through the domain code interfaces in
  **one transaction** (plan.md §12.2 steps 2-7, ADR 0007 + revision 2026-09-01 "deployments are
  pins"). It never writes to resources directly — the order is Project `:create`,
  Model `:register`, UseCase `:define`, Prompt `:open`, PromptVersion `:commit`,
  Deployment `:commit`. The last step swaps the plan's `prompt_names` for the version ids committed
  by this run to build `prompt_pins: %{name => version_id}`.

  ## Idempotency / re-runs

  - The project is looked up by slug within the organization. Created when missing. When it
    exists, **a project with at least one UseCase is not imported into without `force: true`**
    (`{:error, {:project_not_empty, slug}}`).
  - On a `force: true` re-run, Models are reused by `(provider, model_id)`, UseCases by `key` and
    Prompts by name, while PromptVersions are committed under new numbers (versions are immutable
    and are never overwritten). Deployments are committed as new revisions too — the commit is what
    goes live, so there is no activate/discard step.
  - A missing environment is created with `add_environment`.

  On failure the whole transaction rolls back and `{:error, reason}` is returned.
  """

  alias PromptOn.{Catalog, Deployments, Projects, Prompts, Repo}
  alias PromptOn.HeyDiaryImport.Plan

  @notifications {__MODULE__, :notifications}

  @type summary :: %{
          project_id: String.t(),
          project_slug: String.t(),
          environment_id: String.t(),
          environment: String.t(),
          reused_project?: boolean(),
          counts: map(),
          warnings: [Plan.warning()]
        }

  @doc """
  Runs the plan. `opts`:

  - `:actor` (required) — usually `%PromptOn.SystemActor{}`
  - `:organization_id` (required) — the organization in which to create/find the project
  - `:force` — import even into a project that already has UseCases (default false)
  """
  @spec apply(Plan.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def apply(%Plan{} = plan, opts) do
    actor = Keyword.fetch!(opts, :actor)
    organization_id = Keyword.fetch!(opts, :organization_id)
    force? = Keyword.get(opts, :force, false)

    Process.put(@notifications, [])

    result =
      Repo.transaction(fn ->
        case run(plan, actor, organization_id, force?) do
          {:ok, summary} -> summary
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    # Notifications collected inside the transaction are sent after the commit (avoids the Ash
    # "missed notifications" warning).
    notifications = Process.delete(@notifications) || []
    if match?({:ok, _}, result), do: Ash.Notifier.notify(notifications)
    result
  end

  # Write actions are called with `return_notifications?: true`; `{:ok, record, notifications}` is
  # unpacked and the notifications are stashed.
  defp ok({:ok, record, notifications}) do
    Process.put(@notifications, notifications ++ (Process.get(@notifications) || []))
    {:ok, record}
  end

  defp ok(other), do: other

  defp write(scope), do: Keyword.put(scope, :return_notifications?, true)

  defp run(plan, actor, organization_id, force?) do
    with {:ok, project, reused?} <- ensure_project(plan, actor, organization_id, force?),
         scope = [actor: actor, tenant: project.id],
         {:ok, environment} <- ensure_environment(plan.environment, scope),
         {:ok, models} <- ensure_models(plan.models, scope),
         {:ok, use_cases} <- ensure_use_cases(plan.use_cases, scope),
         {:ok, prompts} <- ensure_prompts(plan.prompts, use_cases, scope),
         {:ok, versions} <- commit_versions(plan.prompt_versions, prompts, scope),
         {:ok, deployments} <-
           commit_deployments(plan.deployments, use_cases, versions, models, environment, scope) do
      {:ok,
       %{
         project_id: project.id,
         project_slug: project.slug,
         environment_id: environment.id,
         environment: environment.slug,
         reused_project?: reused?,
         counts: %{
           models: map_size(models),
           use_cases: map_size(use_cases),
           prompts: map_size(prompts),
           prompt_versions: map_size(versions),
           deployments: length(deployments),
           pins: deployments |> Enum.map(&map_size(&1.prompt_pins)) |> Enum.sum()
         },
         warnings: plan.warnings
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # project / environment

  defp ensure_project(plan, actor, organization_id, force?) do
    slug = plan.project.slug

    case Projects.get_project_by_slug(organization_id, slug, actor: actor) do
      {:ok, nil} ->
        with {:ok, project} <-
               ok(
                 Projects.create_project(
                   %{organization_id: organization_id, name: plan.project.name, slug: slug},
                   actor: actor,
                   return_notifications?: true
                 )
               ) do
          {:ok, project, false}
        end

      {:ok, project} ->
        with :ok <- check_empty_or_forced(project, actor, force?), do: {:ok, project, true}

      {:error, error} ->
        {:error, error}
    end
  end

  defp check_empty_or_forced(project, actor, force?) do
    case Prompts.list_all_use_cases(actor: actor, tenant: project.id) do
      {:ok, []} -> :ok
      {:ok, _existing} when force? -> :ok
      {:ok, _existing} -> {:error, {:project_not_empty, project.slug}}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_environment(slug, scope) do
    case Projects.get_environment_by_slug(slug, scope) do
      {:ok, nil} -> ok(Projects.add_environment(%{slug: slug, name: slug}, write(scope)))
      {:ok, env} -> {:ok, env}
      {:error, error} -> {:error, error}
    end
  end

  # ---------------------------------------------------------------------------
  # models / use cases / prompts

  defp ensure_models(models, scope) do
    reduce_ok(models, %{}, fn m, acc ->
      key = {m.provider, m.model_id}

      result =
        case Catalog.get_model_by_provider_model(m.provider, m.model_id, scope) do
          {:ok, nil} ->
            ok(
              Catalog.register_model(
                %{
                  provider: m.provider,
                  model_id: m.model_id,
                  display_name: m.display_name,
                  metadata: m.metadata,
                  provider_options: m.provider_options
                },
                write(scope)
              )
            )

          other ->
            other
        end

      with {:ok, model} <- result, do: {:ok, Map.put(acc, key, model)}
    end)
  end

  defp ensure_use_cases(use_cases, scope) do
    reduce_ok(use_cases, %{}, fn uc, acc ->
      result =
        case Prompts.get_use_case_by_key(uc.key, scope) do
          {:ok, nil} ->
            ok(
              Prompts.define_use_case(
                %{
                  key: uc.key,
                  name: uc.name,
                  description: uc.description,
                  kind: uc.kind,
                  input_schema: uc.input_schema,
                  default_params: uc.default_params
                },
                write(scope)
              )
            )

          other ->
            other
        end

      with {:ok, use_case} <- result, do: {:ok, Map.put(acc, uc.key, use_case)}
    end)
  end

  defp ensure_prompts(prompts, use_cases, scope) do
    reduce_ok(prompts, %{}, fn p, acc ->
      use_case = Map.fetch!(use_cases, p.use_case_key)

      with {:ok, existing} <- Prompts.list_prompts(use_case.id, scope),
           {:ok, prompt} <- find_or_open_prompt(existing, use_case, p, scope) do
        {:ok, Map.put(acc, {p.use_case_key, p.name}, prompt)}
      end
    end)
  end

  defp find_or_open_prompt(existing, use_case, p, scope) do
    case Enum.find(existing, &(&1.name == p.name)) do
      nil ->
        ok(
          Prompts.open_prompt(
            %{use_case_id: use_case.id, name: p.name, description: p.description},
            write(scope)
          )
        )

      prompt ->
        {:ok, prompt}
    end
  end

  defp commit_versions(versions, prompts, scope) do
    reduce_ok(versions, %{}, fn v, acc ->
      prompt = Map.fetch!(prompts, {v.use_case_key, v.prompt_name})

      with {:ok, version} <-
             ok(Prompts.commit_prompt_version(version_input(v, prompt), write(scope))) do
        {:ok, Map.put(acc, {v.use_case_key, v.prompt_name}, version)}
      end
    end)
  end

  defp version_input(%{text_template: nil} = v, prompt),
    do: %{
      prompt_id: prompt.id,
      engine: v.engine,
      commit_message: v.commit_message,
      messages: v.messages
    }

  defp version_input(v, prompt),
    do: %{
      prompt_id: prompt.id,
      engine: v.engine,
      commit_message: v.commit_message,
      text_template: v.text_template
    }

  # ---------------------------------------------------------------------------
  # deployments (ADR 0007 revision 2026-09-01: one revision = one pin, and the commit is live)

  defp commit_deployments(deployments, use_cases, versions, models, environment, scope) do
    reduce_ok(deployments, [], fn d, acc ->
      use_case = Map.fetch!(use_cases, d.use_case_key)

      pins =
        Map.new(d.prompt_names, fn name ->
          {name, Map.fetch!(versions, {d.use_case_key, name}).id}
        end)

      with {:ok, deployment} <-
             ok(
               Deployments.commit_deployment(
                 %{
                   use_case_id: use_case.id,
                   environment_id: environment.id,
                   model_id: Map.fetch!(models, d.model).id,
                   params: d.params,
                   provider_options: d.provider_options,
                   prompt_pins: pins
                 },
                 write(scope)
               )
             ) do
        {:ok, acc ++ [deployment]}
      end
    end)
  end

  # ---------------------------------------------------------------------------

  defp reduce_ok(items, initial, fun) do
    Enum.reduce_while(items, {:ok, initial}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
