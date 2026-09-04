defmodule PromptOn.Evals.Changes.SetActorId do
  @moduledoc """
  Writes the acting user's id into an attribution column — `sampled_by`, `scored_by`, `authored_by`
  or `requested_by`.

      change {PromptOn.Evals.Changes.SetActorId, attribute: :authored_by}

  Attribution is **derived, not accepted**. An argument would let any caller name any user, including
  one outside the organization, and an audit trail is then only as trustworthy as its most careless
  caller. The system actor writes nil: a job or a mix task is not a person.

  This is the evals rule; `PromptOn.Deployments.Deployment.:commit` still accepts `committed_by`
  because the management API sets it on behalf of an authenticated user. New evals actions with an
  attribution column use this change.
  """

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    case opts[:attribute] do
      attribute when is_atom(attribute) and not is_nil(attribute) -> {:ok, opts}
      _other -> {:error, "SetActorId needs an `:attribute`"}
    end
  end

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.force_change_attribute(changeset, opts[:attribute], actor_id(context.actor))
  end

  defp actor_id(%PromptOn.Accounts.User{id: id}), do: id
  defp actor_id(_other), do: nil
end
