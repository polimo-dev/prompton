defmodule PromptOn.Accounts.User.Changes.CreatePersonalOrganization do
  @moduledoc """
  After a user is created, creates a personal `Organization` (no slug, `personal?: true`) and a
  `Membership(role: :owner)` in the same transaction. plan.md §4.7 "auto-created at sign-up".

  A personal organization is resolved in the URL via the reserved segment `/personal` (relative
  to the current user), so it needs no slug. **There must be one personal organization per
  user**; an organization has no user_id, so this cannot be expressed as a DB identity, and
  instead we check here, through the membership, whether one already exists and do not create
  another if so (**idempotent**). `:register` is taken not only by seeds/fixtures but also by the
  first success of email code sign-in (`PromptOn.Accounts.SignIn.verify/3` comes here for an
  unknown address), so the first sign-in is the sign-up, and from the second on the user is only
  looked up and nothing is created.
  """

  use Ash.Resource.Change

  alias PromptOn.Accounts

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      case Accounts.personal_organization_for(user.id, authorize?: false) do
        {:ok, nil} -> create_personal_organization(user)
        {:ok, _existing} -> {:ok, user}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp create_personal_organization(user) do
    email = to_string(user.email)

    with {:ok, org} <-
           Accounts.create_personal_organization(
             %{name: "#{email}'s organization"},
             authorize?: false
           ),
         {:ok, _membership} <-
           Accounts.add_member(
             %{organization_id: org.id, user_id: user.id, role: :owner},
             authorize?: false
           ) do
      {:ok, user}
    end
  end
end
