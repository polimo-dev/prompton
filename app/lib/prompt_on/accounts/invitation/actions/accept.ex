defmodule PromptOn.Accounts.Invitation.Actions.Accept do
  @moduledoc """
  Accepts one invitation exactly once.

  Lock order is Invitation row first, Organization row second, then Membership insert. The inviter's
  current permission is re-evaluated after the locks and before any membership is created.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias PromptOn.Accounts
  alias PromptOn.Accounts.Invitation
  alias PromptOn.Accounts.Invitation.Actions.Preview
  alias PromptOn.Accounts.Organization
  alias PromptOn.Projects
  alias PromptOn.Repo

  @notifications {__MODULE__, :notifications}

  @impl true
  def run(input, opts, context) do
    token = Ash.ActionInput.get_argument(input, :token)
    actor = context.actor

    result = transaction(token, actor, opts)

    # A competing invitation or code sign-in can create this email after our lookup. Ash's
    # registration rolls back the transaction on a unique conflict; retry once from fresh locks
    # so we can reuse the committed account and re-check the invitation and seat limit.
    result =
      if registration_conflict?(result),
        do: transaction(token, actor, opts),
        else: result

    case result do
      {:ok, {%Invitation{} = invitation, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, invitation}

      {:error, error} ->
        {:error, error}
    end
  after
    Process.delete(@notifications)
  end

  defp transaction(token, actor, opts) do
    Repo.transaction(fn ->
      Process.put(@notifications, [])

      case accept(token, actor, opts) do
        {:ok, invitation} -> {invitation, Process.get(@notifications)}
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp registration_conflict?({:error, %{errors: errors}}) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{private_vars: vars} ->
        Keyword.get(vars || [], :constraint) == "users_unique_email_index"

      _other ->
        false
    end)
  end

  defp registration_conflict?(_result), do: false

  defp accept(token, actor, opts) do
    with {:ok, invitation} <- locked_invitation(token),
         :ok <- Preview.validate_pending(invitation),
         :ok <- Preview.validate_actor(invitation, actor, opts),
         {:ok, _organization} <- lock_team_organization(invitation.organization_id),
         :ok <- authorize_current_inviter(invitation),
         {:ok, actor} <- invited_user(invitation, actor, opts),
         :ok <- ensure_membership(invitation, actor),
         :ok <- grant_projects(invitation, actor),
         {:ok, accepted} <- mark_accepted(invitation, actor) do
      accepted
      |> Ash.Resource.put_metadata(:accepted_user, actor)
      |> Preview.load_preview()
    end
  end

  defp invited_user(invitation, actor, opts) do
    if Keyword.get(opts, :email_proof?, false) do
      # The address comes only from the locked invitation, never from request parameters.
      case Accounts.get_user_by_email(invitation.email, actor: PromptOn.SystemActor.new()) do
        {:ok, %Accounts.User{} = user} -> {:ok, user}
        {:ok, nil} -> register_invited_user(invitation.email)
        {:error, error} -> {:error, error}
      end
    else
      {:ok, actor}
    end
  end

  defp register_invited_user(email) do
    Accounts.register_user(%{email: email},
      actor: PromptOn.SystemActor.new(),
      return_notifications?: true
    )
    |> ok()
  end

  defp locked_invitation(token) do
    Invitation
    |> Ash.Query.filter(token_hash == ^Invitation.hash(token))
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: PromptOn.SystemActor.new())
    |> case do
      {:ok, %Invitation{} = invitation} -> {:ok, invitation}
      {:ok, nil} -> {:error, Preview.invalid(:token, "is not valid")}
      {:error, error} -> {:error, error}
    end
  end

  defp lock_team_organization(organization_id) do
    Organization
    |> Ash.Query.filter(id == ^organization_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: PromptOn.SystemActor.new())
    |> case do
      {:ok, %Organization{personal?: true}} ->
        {:error,
         Preview.invalid(
           :organization_id,
           "personal organizations cannot invite members. Convert it to a team organization first."
         )}

      {:ok, %Organization{} = organization} ->
        {:ok, organization}

      {:ok, nil} ->
        {:error, Preview.invalid(:organization_id, "is not accessible")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp authorize_current_inviter(%Invitation{inviter_id: nil}),
    do: {:error, Preview.invalid(:inviter_id, "is no longer active")}

  defp authorize_current_inviter(%Invitation{} = invitation) do
    case Ash.get(PromptOn.Accounts.User, invitation.inviter_id, actor: PromptOn.SystemActor.new()) do
      {:ok, nil} ->
        {:error, Preview.invalid(:inviter_id, "is no longer active")}

      {:ok, inviter} ->
        Invitation.Policy.authorize_invite(
          inviter,
          invitation.organization_id,
          invitation.role,
          invitation.project_ids
        )

      {:error, error} ->
        {:error, error}
    end
  end

  defp ensure_membership(invitation, actor) do
    case current_membership(invitation.organization_id, actor.id) do
      %PromptOn.Accounts.Membership{} ->
        :ok

      nil ->
        %{
          organization_id: invitation.organization_id,
          user_id: actor.id,
          role: invitation.role
        }
        |> Accounts.add_member(actor: PromptOn.SystemActor.new(), return_notifications?: true)
        |> ok()
        |> case do
          {:ok, _membership} -> :ok
          {:error, error} -> {:error, error}
        end
    end
  end

  defp grant_projects(%Invitation{project_ids: project_ids}, actor) do
    Enum.reduce_while(project_ids, :ok, fn project_id, :ok ->
      if existing_project_membership?(project_id, actor.id) do
        {:cont, :ok}
      else
        case Projects.grant_project_membership(
               %{project_id: project_id, user_id: actor.id},
               actor: PromptOn.SystemActor.new(),
               return_notifications?: true
             )
             |> ok() do
          {:ok, _grant} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end
    end)
  end

  defp current_membership(organization_id, user_id) do
    PromptOn.Accounts.Membership
    |> Ash.Query.filter(organization_id == ^organization_id and user_id == ^user_id)
    |> Ash.read_one!(actor: PromptOn.SystemActor.new())
  end

  defp existing_project_membership?(project_id, user_id) do
    PromptOn.Projects.ProjectMembership
    |> Ash.Query.filter(project_id == ^project_id and user_id == ^user_id)
    |> Ash.exists?(actor: PromptOn.SystemActor.new())
  end

  defp mark_accepted(invitation, actor) do
    invitation
    |> Ash.Changeset.for_update(
      :mark_accepted,
      %{accepted_at: DateTime.utc_now(), accepted_by_id: actor.id},
      actor: PromptOn.SystemActor.new()
    )
    |> Ash.update(return_notifications?: true)
    |> ok()
  end

  defp ok({:ok, record, notifications}) do
    Process.put(@notifications, notifications ++ (Process.get(@notifications) || []))
    {:ok, record}
  end

  defp ok({:ok, {record, notifications}}) do
    Process.put(@notifications, notifications ++ (Process.get(@notifications) || []))
    {:ok, record}
  end

  defp ok(other), do: other
end
