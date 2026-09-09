defmodule PromptOn.PromptConsolidation do
  @moduledoc """
  Idempotent data upgrade from named prompts to one prompt per use case.

  Every old version and deployment remains immutable. Historical pin combinations receive
  equivalent canonical versions so rollback remains available. Current environments get new
  revisions with the same model/options, while unpublished drafts are merged independently.
  """

  require Ash.Query

  alias PromptOn.Deployments.Deployment
  alias PromptOn.PromptConsolidation.Template
  alias PromptOn.Prompts
  alias PromptOn.Prompts.{Prompt, PromptVersion, UseCase}
  alias PromptOn.Repo

  @notifications {__MODULE__, :notifications}

  @doc "Preflights and upgrades all active chat use cases. Pass dry_run: true to report only."
  def run!(opts \\ []) do
    Process.put(@notifications, [])

    case Repo.transaction(
           fn ->
             Repo.query!("SELECT pg_advisory_xact_lock(756219, 1)", [])

             Repo.query!(
               "SELECT id, project_id FROM use_cases WHERE kind = 'chat' AND archived_at IS NULL ORDER BY id",
               []
             ).rows
             |> Enum.flat_map(&upgrade(&1, opts))
           end,
           timeout: :infinity
         ) do
      {:ok, report} ->
        Ash.Notifier.notify(Process.get(@notifications, []))
        report

      {:error, error} ->
        raise "prompt consolidation failed: #{inspect(error)}"
    end
  after
    Process.delete(@notifications)
  end

  defp upgrade([id, project_id], opts) do
    scope = scope(Ecto.UUID.load!(project_id))

    use_case =
      UseCase
      |> Ash.Query.filter(id == ^Ecto.UUID.load!(id))
      |> Ash.Query.lock("FOR UPDATE")
      |> Ash.read_one!(scope)

    case plan(use_case, scope) do
      nil ->
        []

      plan ->
        unless Keyword.get(opts, :dry_run, false), do: apply_plan(plan, scope)

        [
          %{
            use_case: use_case.key,
            archived_prompts: length(plan.extras),
            environments: length(plan.current),
            variables: Enum.map(plan.fields, & &1.name)
          }
        ]
    end
  end

  @doc "Read-only conversion of a historical revision's pins, for authorized rollback."
  def pins_for(%Deployment{prompt_pins: %{"default" => _} = pins}, _opts)
      when map_size(pins) == 1,
      do: {:ok, pins}

  def pins_for(%Deployment{} = deployment, opts) do
    prompts = all_prompts(deployment.use_case_id, opts)
    canonical = Enum.find(prompts, &(&1.name == "default" and is_nil(&1.archived_at)))

    if canonical do
      versions = all_versions(prompts, opts)
      deployments = all_deployments(deployment.use_case_id, opts)
      strategy = strategy(prompts, deployments, versions)
      attrs = merge_pins!(deployment.prompt_pins, prompts, versions, strategy)
      hash = hash(attrs)

      case Enum.find(versions, &(&1.prompt_id == canonical.id and &1.content_sha256 == hash)) do
        nil -> {:error, "historical prompt pins have not been consolidated; run the data upgrade"}
        version -> {:ok, %{"default" => version.id}}
      end
    else
      {:error, "use case has no active prompt"}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp plan(use_case, opts) do
    prompts = all_prompts(use_case.id, opts)
    active = Enum.filter(prompts, &is_nil(&1.archived_at))
    extras = Enum.reject(active, &(&1.name == "default"))
    deployments = all_deployments(use_case.id, opts)

    current =
      deployments
      |> Enum.group_by(& &1.environment_id)
      |> Enum.map(fn {_id, revisions} -> Enum.max_by(revisions, & &1.revision) end)

    if extras != [] or Enum.any?(deployments, &(Map.keys(&1.prompt_pins) != ["default"])) do
      canonical =
        Enum.find(active, &(&1.name == "default")) ||
          raise ArgumentError, "#{use_case.key}: no active default prompt"

      versions = all_versions(prompts, opts)
      strategy = strategy(prompts, deployments, versions)

      compiled =
        Map.new(deployments, fn deployment ->
          {deployment.id, merge_pins!(deployment.prompt_pins, prompts, versions, strategy)}
        end)

      hashes =
        versions
        |> Enum.filter(&(&1.prompt_id == canonical.id))
        |> MapSet.new(& &1.content_sha256)

      missing_history? =
        Enum.any?(compiled, fn {_id, attrs} -> not MapSet.member?(hashes, hash(attrs)) end)

      if extras != [] or missing_history? or
           Enum.any?(current, &(Map.keys(&1.prompt_pins) != ["default"])) do
        fields = Template.fields(strategy)
        validate_fields!(use_case, fields)
        effective = Map.new(active, &{&1.name, effective_draft!(&1, versions)})
        if extras != [], do: validate_draft_inputs!(effective, strategy)

        %{
          use_case: use_case,
          canonical: canonical,
          extras: extras,
          draft: Template.merge!(effective, strategy),
          compiled: compiled,
          current: current,
          fields: fields
        }
      end
    end
  end

  defp validate_fields!(use_case, additions) do
    names = MapSet.new(additions, & &1.name)

    for field <- use_case.input_schema || [], MapSet.member?(names, field.name) do
      unless field.type in [:string, "string"],
        do:
          raise(
            ArgumentError,
            "#{use_case.key}: selector #{field.name} conflicts with existing #{field.type} variable"
          )
    end
  end

  defp all_prompts(use_case_id, opts),
    do: Prompt |> Ash.Query.filter(use_case_id == ^use_case_id) |> Ash.read!(opts)

  defp all_deployments(use_case_id, opts),
    do: Deployment |> Ash.Query.filter(use_case_id == ^use_case_id) |> Ash.read!(opts)

  defp strategy(prompts, deployments, versions) do
    names = Enum.map(prompts, & &1.name) ++ Enum.flat_map(deployments, &Map.keys(&1.prompt_pins))
    legacy_pins = deployments |> Enum.reject(&(Map.keys(&1.prompt_pins) == ["default"]))
    version_ids = legacy_pins |> Enum.flat_map(&Map.values(&1.prompt_pins)) |> MapSet.new()
    extras = Enum.reject(prompts, &(&1.name == "default"))
    extra_ids = MapSet.new(extras, & &1.id)

    # These sources remain immutable after upgrade. New canonical versions must not change the
    # selector mapping used to render and roll back historical revisions.
    sources =
      Enum.filter(
        versions,
        &(MapSet.member?(version_ids, &1.id) or MapSet.member?(extra_ids, &1.prompt_id))
      )

    sources = sources ++ Enum.flat_map(extras, &if(is_map(&1.draft), do: [&1.draft], else: []))
    inputs = Enum.flat_map(sources, &inputs/1)
    names |> Template.strategy() |> Template.reserve_inputs(inputs)
  end

  defp inputs(source) do
    case Template.content(source) do
      %{engine: :raw} ->
        []

      %{messages: messages} ->
        Enum.flat_map(messages, &PromptOnSDK.Template.variables(&1.content))
    end
  end

  defp validate_draft_inputs!(effective, strategy) do
    inputs = effective |> Map.values() |> Enum.flat_map(&inputs/1) |> MapSet.new()

    for {name, _default} <- strategy.dimensions, MapSet.member?(inputs, name) do
      raise ArgumentError,
            "draft input #{name} conflicts with the inferred selector; choose a distinct input before consolidation"
    end
  end

  defp all_versions(prompts, opts) do
    ids = Enum.map(prompts, & &1.id)
    PromptVersion |> Ash.Query.filter(prompt_id in ^ids) |> Ash.read!(opts)
  end

  defp effective_draft!(%{draft: draft}, _versions) when is_map(draft),
    do: Template.content(draft)

  defp effective_draft!(prompt, versions) do
    case versions
         |> Enum.filter(&(&1.prompt_id == prompt.id))
         |> Enum.max_by(& &1.number, fn -> nil end) do
      nil ->
        raise ArgumentError,
              "#{prompt.name}: an empty uncommitted prompt needs content before consolidation"

      version ->
        Template.content(version)
    end
  end

  defp merge_pins!(pins, prompts, versions, strategy) do
    versions = Map.new(versions, &{&1.id, &1})
    prompt_ids = MapSet.new(prompts, & &1.id)

    sources =
      Map.new(pins, fn {name, id} ->
        version = Map.get(versions, id)

        unless version && MapSet.member?(prompt_ids, version.prompt_id),
          do:
            raise(
              ArgumentError,
              "historical pin #{inspect(name)} does not belong to this use case"
            )

        {name, version}
      end)

    Template.merge!(sources, strategy)
  end

  defp apply_plan(plan, opts) do
    if plan.extras != [] and is_map(plan.canonical.draft) do
      ensure_version!(
        plan.canonical,
        Template.content(plan.canonical.draft),
        "Preserve unpublished draft before prompt consolidation",
        opts
      )
    end

    normalized =
      Map.new(plan.compiled, fn {deployment_id, attrs} ->
        version =
          ensure_version!(
            plan.canonical,
            attrs,
            "Consolidated source deployment #{deployment_id}",
            opts
          )

        {deployment_id, version.id}
      end)

    # Keep a draft distinct from the per-environment versions even when it has never been deployed.
    if plan.extras != [] do
      Prompts.save_prompt_draft(
        plan.canonical,
        %{draft: Prompt.draft_map(plan.draft.engine, plan.draft.messages, nil)},
        write(opts)
      )
      |> written!()
    end

    fields =
      Enum.map(
        plan.use_case.input_schema || [],
        &Map.take(&1, [:name, :type, :required?, :description, :example])
      )

    names = MapSet.new(fields, & &1.name)
    additions = Enum.reject(plan.fields, &MapSet.member?(names, &1.name))

    Prompts.set_use_case_input_schema(
      plan.use_case,
      %{input_schema: fields ++ additions},
      write(opts)
    )
    |> written!()

    Enum.each(plan.extras, fn prompt ->
      Prompts.archive_prompt(prompt, %{}, write(opts)) |> written!()
    end)

    Enum.each(plan.current, fn source ->
      pins = %{"default" => Map.fetch!(normalized, source.id)}
      if source.prompt_pins != pins, do: copy_current_revision!(source, pins)
    end)
  end

  defp ensure_version!(canonical, attrs, message, opts) do
    hash = hash(attrs)

    existing =
      PromptVersion
      |> Ash.Query.filter(prompt_id == ^canonical.id and content_sha256 == ^hash)
      |> Ash.Query.sort(number: :asc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(opts)

    existing ||
      Prompts.commit_prompt_version(
        Map.merge(attrs, %{prompt_id: canonical.id, commit_message: message}),
        write(opts)
      )
      |> written!()
  end

  defp write(opts), do: Keyword.put(opts, :return_notifications?, true)

  defp written!({:ok, record, notifications}) do
    Process.put(@notifications, notifications ++ Process.get(@notifications, []))
    record
  end

  defp written!({:error, error}), do: raise(error)

  # This is a data upgrade of an already-live pin. Copying it directly preserves even deprecated
  # model pins; authoring validation must not force an unrelated model change during the upgrade.
  # The use case lock above is the same lock ordinary deployment commits take for numbering.
  defp copy_current_revision!(source, pins) do
    Repo.query!(
      """
      INSERT INTO deployments (id, project_id, use_case_id, environment_id, revision, model_id,
                               params, provider_options, prompt_pins, committed_by, inserted_at)
      SELECT $1, project_id, use_case_id, environment_id,
             (SELECT max(d.revision) + 1 FROM deployments d
              WHERE d.use_case_id = source.use_case_id AND d.environment_id = source.environment_id),
             model_id, params, provider_options, $2, NULL, (now() AT TIME ZONE 'utc')
      FROM deployments source WHERE id = $3
      """,
      [Ecto.UUID.dump!(Ash.UUIDv7.generate()), pins, Ecto.UUID.dump!(source.id)]
    )
  end

  defp hash(attrs), do: PromptVersion.content_hash(attrs.engine, attrs.messages, nil)
  defp scope(project_id), do: [tenant: project_id, actor: PromptOn.SystemActor.new()]
end
