defmodule PromptOnWeb.API.V1.Management.OrgController do
  @moduledoc """
  `GET /api/v1/orgs` and `GET /api/v1/orgs/:org` - the organizations this **user** can provision.

  With management keys gone (2026-09-02), a credential is no longer bound to a single organization -
  a user can belong to one personal organization and several team organizations, so a listing is
  needed, and the value chosen from it becomes the `:org` segment of every path from then on. The
  CLI writes it to `"org"` in `~/.config/prompton/config.json`.

  The personal organization has no slug (`"slug": null`, `"personal": true`) - its address is the
  reserved segment `personal`.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Accounts
  alias PromptOnWeb.API.V1.Management.JSON
  alias PromptOnWeb.API.V1.Management.Scope

  action_fallback PromptOnWeb.API.V1.FallbackController

  def index(conn, _params) do
    user = Scope.user(conn)

    with {:ok, organizations} <- Accounts.list_organizations_for(user.id, actor: user) do
      json(conn, %{"organizations" => Enum.map(organizations, &JSON.organization/1)})
    end
  end

  def show(conn, _params), do: json(conn, JSON.organization(Scope.organization(conn)))
end
