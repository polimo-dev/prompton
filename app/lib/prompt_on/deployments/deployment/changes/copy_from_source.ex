defmodule PromptOn.Deployments.Deployment.Changes.CopyFromSource do
  @moduledoc """
  `:rollback`: copies the use_case/environment/model pins of the `source_deployment_id` revision
  into the new commit (ADR 0007).

  Deployment rows are immutable and append-only, so "reverting" means **committing a new revision**
  with the contents of a past one (inheriting the rollback property of v1 Release, ADR 0002).

  - The source is looked up **in the same tenant only** (a tenant-pinned read: an id from another
    project is simply not visible).
  - If the caller also passes `use_case_id`/`environment_id`, they **must match** the source's.
  - Four things are copied: `model_id`, `params`, `provider_options` and `prompt_pins`. A rollback
    returns to **exactly the versions** that revision pointed at, so the pins are left untouched.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias PromptOn.Deployments.Deployment

  @impl true
  def change(changeset, _opts, _context) do
    source_id = Ash.Changeset.get_argument(changeset, :source_deployment_id)
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    Deployment
    |> Ash.Query.filter(id == ^source_id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %Deployment{} = source} -> copy(changeset, source)
      {:ok, nil} -> invalid(changeset, "source deployment not found in this project")
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp copy(changeset, %Deployment{} = source) do
    with :ok <- same(changeset, :use_case_id, source.use_case_id, "use case"),
         :ok <- same(changeset, :environment_id, source.environment_id, "environment") do
      Ash.Changeset.force_change_attributes(changeset, %{
        use_case_id: source.use_case_id,
        environment_id: source.environment_id,
        model_id: source.model_id,
        params: source.params || %{},
        provider_options: source.provider_options || %{},
        prompt_pins: Deployment.normalize_pins(source.prompt_pins)
      })
    else
      {:error, message} -> invalid(changeset, message)
    end
  end

  defp same(changeset, field, source_value, label) do
    case Ash.Changeset.get_attribute(changeset, field) do
      nil -> :ok
      ^source_value -> :ok
      _ -> {:error, "source deployment belongs to a different #{label}"}
    end
  end

  defp invalid(changeset, message) do
    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidArgument.exception(
        field: :source_deployment_id,
        message: message
      )
    )
  end
end
