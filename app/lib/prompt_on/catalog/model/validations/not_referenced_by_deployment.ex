defmodule PromptOn.Catalog.Model.Validations.NotReferencedByDeployment do
  @moduledoc """
  `:archive` is refused when a **live Deployment** target points at this model (ADR 0007): an
  archived model may drop out of snapshot assembly, and the SDK would then resolve `model: nil`.
  `:deprecate` is not blocked (it only cannot be picked by new targets, and stays in the snapshot
  along with `status`).

  The decision is delegated to `PromptOn.Deployments.referencing_model?/2`: rules and targets are
  embedded jsonb, so instead of a SQL join it reads the project's live revisions and checks them in
  memory.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    model = changeset.data

    if PromptOn.Deployments.referencing_model?(model.project_id, model.id) do
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :archived_at,
         message: "model is referenced by a live deployment"
       )}
    else
      :ok
    end
  end
end
