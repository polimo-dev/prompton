defmodule PromptOn.Deployments.Deployment.Validations.Committable do
  @moduledoc """
  `:commit` / `:rollback` validation. A commit is live the moment it lands, so this validation
  replaces the v1 release gate (ADR 0007, revised 2026-09-01 "a revision is a pin, not a router").

  ## Rules

  1. **Exactly one model, and it is required**: a `status :active`, non-archived Model of the same
     project.
  2. **The use case must be chat**. Historical text/embedding rows can be loaded but not deployed.
  3. **A chat use case deploys exactly the canonical default prompt**. `prompt_pins` must contain
     only `"default"` and must provide a non-empty version id.
  4. The default prompt version must belong to the same tenant and to this use case's live
     non-archived default Prompt.

  Rollback can read historical revisions that stored multi-prompt or non-default pins, but
  `CopyFromSource` normalizes those through the consolidation lookup before this validation runs.
  If no canonical equivalent exists, rollback fails instead of reactivating unsupported pins.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Catalog.Model
  alias PromptOn.Deployments.Deployment
  alias PromptOn.Prompts.{Prompt, PromptVersion, UseCase}

  @impl true
  def validate(changeset, _opts, _context) do
    tenant = changeset.to_tenant || changeset.tenant
    opts = [tenant: tenant, actor: PromptOn.SystemActor.new()]
    use_case_id = Ash.Changeset.get_attribute(changeset, :use_case_id)
    model_id = Ash.Changeset.get_attribute(changeset, :model_id)
    pins = changeset |> Ash.Changeset.get_attribute(:prompt_pins) |> Deployment.normalize_pins()

    with {:ok, use_case} <- fetch_use_case(use_case_id, opts),
         {:ok, prompts} <- fetch_prompts(use_case_id, opts),
         {:ok, versions} <- fetch_versions(Map.values(pins), opts) do
      case model_errors(model_id, opts) ++ pin_errors(use_case, pins, prompts, versions) do
        [] -> :ok
        errors -> {:error, errors}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # loads

  defp fetch_use_case(nil, _opts), do: {:error, invalid(:use_case_id, "is required")}

  defp fetch_use_case(id, opts) do
    UseCase
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %UseCase{} = use_case} -> {:ok, use_case}
      {:ok, nil} -> {:error, invalid(:use_case_id, "use case not found in this project")}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_prompts(use_case_id, opts) do
    Prompt
    |> Ash.Query.filter(use_case_id == ^use_case_id and is_nil(archived_at) and name == "default")
    |> Ash.read(opts)
    |> case do
      {:ok, prompts} -> {:ok, Map.new(prompts, &{&1.name, &1})}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_versions([], _opts), do: {:ok, %{}}

  defp fetch_versions(ids, opts) do
    PromptVersion
    |> Ash.Query.filter(id in ^Enum.uniq(ids))
    |> Ash.read(opts)
    |> case do
      {:ok, versions} -> {:ok, Map.new(versions, &{&1.id, &1})}
      {:error, error} -> {:error, error}
    end
  end

  # ---------------------------------------------------------------------------
  # model

  defp model_errors(nil, _opts), do: [invalid(:model_id, "is required")]

  defp model_errors(model_id, opts) do
    Model
    |> Ash.Query.filter(id == ^model_id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} ->
        [invalid(:model_id, "model #{model_id} not found in this project")]

      {:ok, %Model{archived_at: at}} when not is_nil(at) ->
        [invalid(:model_id, "model #{model_id} is archived")]

      {:ok, %Model{status: :active}} ->
        []

      {:ok, %Model{status: status}} ->
        [invalid(:model_id, "model #{model_id} is #{status}")]

      {:error, _error} ->
        [invalid(:model_id, "model #{model_id} not found in this project")]
    end
  end

  # ---------------------------------------------------------------------------
  # prompt pins

  defp pin_errors(%UseCase{kind: kind}, _pins, _prompts, _versions) when kind != :chat,
    do: [invalid(:use_case_id, "#{kind} use cases are no longer deployable")]

  defp pin_errors(%UseCase{} = use_case, pins, prompts, _versions) when pins == %{} do
    if map_size(prompts) == 0 do
      [invalid(:prompt_pins, "this use case has no default prompt to pin")]
    else
      [invalid(:prompt_pins, "the default prompt must be pinned for #{use_case.kind} use cases")]
    end
  end

  defp pin_errors(%UseCase{}, pins, prompts, versions) do
    case Map.keys(pins) do
      ["default"] ->
        pin_error(
          "default",
          pins["default"],
          Map.get(prompts, "default"),
          Map.get(versions, pins["default"])
        )

      _other ->
        [invalid(:prompt_pins, ~s|prompt_pins must contain only the "default" prompt|)]
    end
  end

  defp pin_error(name, _version_id, nil, _version),
    do: [invalid(:prompt_pins, "no prompt named #{inspect(name)} in this use case")]

  defp pin_error(name, version_id, %Prompt{}, nil),
    do: [
      invalid(:prompt_pins, "prompt version #{version_id} (#{name}) not found in this project")
    ]

  defp pin_error(_name, _version_id, %Prompt{id: prompt_id}, %PromptVersion{prompt_id: prompt_id}),
       do: []

  defp pin_error(name, version_id, %Prompt{}, %PromptVersion{}),
    do: [
      invalid(
        :prompt_pins,
        "prompt version #{version_id} does not belong to prompt #{inspect(name)}"
      )
    ]

  defp invalid(field, message),
    do: Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)
end
