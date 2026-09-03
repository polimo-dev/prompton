defmodule PromptOn.Deployments.Deployment.Changes.SetCommitter do
  @moduledoc """
  Records the actor's id in `committed_by` when it was not given explicitly and the actor is a
  `%PromptOn.Accounts.User{}` (ApiKey/System actors leave it nil: the committer is not a person).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %PromptOn.Accounts.User{id: id}}) do
    case Ash.Changeset.get_attribute(changeset, :committed_by) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :committed_by, id)
      _ -> changeset
    end
  end

  def change(changeset, _opts, _context), do: changeset
end
