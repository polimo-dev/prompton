defmodule PromptOnWeb.OrgMembersLive do
  @moduledoc """
  Organization member list (`/:org_slug/members`), **read-only**.

  Invite (`Membership :invite`), role change (`:change_role`) and removal UI are not in the domain
  yet. So this screen has no buttons, only a one-line roadmap note, exactly per the rule of not
  building dead buttons (CLAUDE.md UI section).

  `role` is a value `PromptOn.Accounts.Membership` really holds (`:owner :admin :editor :viewer`;
  P0 does not branch policies on it), so it is shown as a column. The join date is the membership's
  `inserted_at`.

  The email comes from loading `Membership.user`. The read policy of `PromptOn.Accounts.User` is
  "self + members of the same organization", so users of other organizations do not show up here
  either.
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Accounts
  alias PromptOnWeb.OrgComponents, as: OC
  alias PromptOnWeb.SettingsComponents, as: SC

  @cols [
    %{label: "member", w: "minmax(0,2fr)"},
    %{label: "role", w: "110px"},
    %{label: "joined", w: "150px", align: "right"}
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Members · #{Layouts.org_label(socket.assigns.organization)}",
       cols: @cols
     )
     |> assign(:members, members(socket))}
  end

  defp members(socket) do
    %{organization: organization, current_user: user} = socket.assigns

    case Accounts.list_memberships(
           actor: user,
           query: [filter: [organization_id: organization.id]],
           load: [:user]
         ) do
      {:ok, memberships} -> Enum.sort_by(memberships, & &1.inserted_at)
      {:error, _error} -> []
    end
  end

  @doc """
  Member display name: the email. A row whose `user` did not come along because the policy filtered
  it is drawn with the email hidden (the row stays).

      iex> PromptOnWeb.OrgMembersLive.member_email(%{user: %{email: "a@b.c"}})
      "a@b.c"

      iex> PromptOnWeb.OrgMembersLive.member_email(%{user: nil})
      "—"
  """
  @spec member_email(map()) :: String.t()
  def member_email(%{user: %{email: email}}), do: to_string(email)
  def member_email(_membership), do: "—"

  @doc """
  Join date as an absolute date. The member list asks "since when", so a date beats a relative time
  ("3d ago").

      iex> PromptOnWeb.OrgMembersLive.joined_on(~U[2026-09-01 10:00:00Z])
      "2026-09-01"

      iex> PromptOnWeb.OrgMembersLive.joined_on(nil)
      "—"
  """
  @spec joined_on(DateTime.t() | nil) :: String.t()
  def joined_on(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")
  def joined_on(_other), do: "—"

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      org_slug={@org_slug}
      project={@project}
      projects={@projects}
      organization={@organization}
      organizations={@organizations}
      nav={:members}
    >
      <DS.screen
        id="org-members-screen"
        title="Members"
        sub={Layouts.org_label(@organization)}
        max_w={880}
      >
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <:actions>
          <OC.org_nav org_slug={@org_slug} active={:members} />
        </:actions>

        <DS.table id="members-table" cols={@cols}>
          <DS.row
            :for={{membership, index} <- Enum.with_index(@members)}
            id={"member-row-#{membership.id}"}
            cols={@cols}
            index={index}
          >
            <span style="display:flex;align-items:center;gap:9px;min-width:0;">
              <DSIcons.icon name="user" size={14} class="tx3" />
              <span
                class="font-mono"
                style="font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
              >
                {member_email(membership)}
              </span>
            </span>
            <DS.badge tone={if membership.role == :owner, do: :accent, else: :neutral} mono>
              {membership.role}
            </DS.badge>
            <span class="font-mono" style="font-size:12px;color:var(--tx-2);text-align:right;">
              {joined_on(membership.inserted_at)}
            </span>
          </DS.row>
        </DS.table>

        <SC.info_box id="members-note" icon="info" style="margin-top:12px;">
          Invitations are coming soon. Until then members are added when the organization is created
          or by an operator.
        </SC.info_box>
      </DS.screen>
    </Layouts.app>
    """
  end
end
