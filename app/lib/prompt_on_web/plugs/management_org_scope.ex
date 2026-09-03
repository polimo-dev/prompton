defmodule PromptOnWeb.Plugs.ManagementOrgScope do
  @moduledoc """
  Management API path segment `:org` → `assign(:organization, …)` (`docs/management-api.md`).

  The address is `/api/v1/orgs/:org/…` because the credential is a **user** — a user belongs to
  several organizations, so "which organization" has to be said by the path, not by the key.

  - `:org` == `"personal"` → this user's **personal organization** (it has no slug, so it is
    addressed by a reserved segment. The same rule as the web URL `/{org}/…` —
    `PromptOn.Accounts.ReservedSlugs`).
  - anything else → a team organization slug. The read policy is a membership filter, so **to a
    non-member it is as if it did not exist**.

  When nothing is found the answer is **404**, not 403: someone else's organization does not even
  reveal its existence.

  On paths without an `:org` segment (`/api/v1/me`, `/api/v1/orgs`, `/api/v1/sessions/revoke`) it
  does nothing — so that the same pipeline can be shared.
  """

  alias PromptOn.Accounts
  alias PromptOnWeb.API.V1.Management.Halt

  # The same word as `/personal` in web URLs (`PromptOn.Accounts.ReservedSlugs`).
  @personal "personal"

  def init(opts), do: opts

  def call(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def call(conn, _opts) do
    case conn.path_params do
      %{"org" => slug} -> resolve(conn, slug)
      _other -> conn
    end
  end

  defp resolve(conn, slug) do
    case organization(conn.assigns[:current_user], slug) do
      {:ok, organization} ->
        Plug.Conn.assign(conn, :organization, organization)

      :error ->
        Halt.not_found(conn, "unknown organization: #{slug}", %{"organization" => slug})
    end
  end

  defp organization(nil, _slug), do: :error

  defp organization(user, @personal) do
    case Accounts.personal_organization_for(user.id, actor: user) do
      {:ok, %{} = organization} -> {:ok, organization}
      _other -> :error
    end
  end

  defp organization(user, slug) do
    case Accounts.get_organization_by_slug(slug, actor: user) do
      {:ok, %{} = organization} -> {:ok, organization}
      _other -> :error
    end
  end
end
