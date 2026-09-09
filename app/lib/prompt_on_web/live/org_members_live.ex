defmodule PromptOnWeb.OrgMembersLive do
  @moduledoc """
  Organization member management (`/:org_slug/members`).

  Invitations and member mutations are rendered from permission helpers, then enforced again by the
  Accounts domain events. Members can invite to projects they created, admins can invite and
  promote members, and owner-only organization powers stay outside this screen.
  """

  use PromptOnWeb, :live_view

  alias PromptOn.Accounts
  alias PromptOn.Accounts.Permissions
  alias PromptOnWeb.ErrorText
  alias PromptOnWeb.SettingsComponents, as: SC

  require Ash.Query

  @cols [
    %{label: "email", w: "minmax(0,2fr)"},
    %{label: "role", w: "155px"},
    %{label: "projects", w: "minmax(0,2fr)"},
    %{label: "joined", w: "118px", align: "right"},
    %{label: "", w: "168px", align: "right"}
  ]

  @invitation_cols [
    %{label: "email", w: "minmax(0,2fr)"},
    %{label: "role", w: "110px"},
    %{label: "projects", w: "minmax(0,2fr)"},
    %{label: "", w: "96px", align: "right"}
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Members · #{Layouts.org_label(socket.assigns.organization)}",
       cols: @cols,
       invitation_cols: @invitation_cols,
       invitation_form: invitation_form(),
       project_editor: nil
     )
     |> load_members_page()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :project_editor, project_editor(params, socket.assigns))}
  end

  defp load_members_page(socket) do
    socket
    |> assign(:permission, permission(socket))
    |> assign(:members, members(socket))
    |> assign_member_projects()
    |> assign(:invitations, invitations(socket))
  end

  defp permission(socket) do
    %{organization: organization, current_user: user, projects: projects} = socket.assigns
    role = ok_or_value(Permissions.role(user, organization.id), :member)
    invitable_projects = ok_or_value(Permissions.invitable_projects(user, organization.id), [])

    %{
      role: role,
      manage?: ok_or_value(Permissions.manage?(user, organization.id), false),
      owner?: ok_or_value(Permissions.owner?(user, organization.id), false),
      invitable_projects: sort_projects(invitable_projects),
      projects: sort_projects(projects),
      can_grant_admin?: role in [:admin, :owner],
      can_invite?:
        not organization.personal? and (role in [:admin, :owner] or invitable_projects != [])
    }
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

  defp invitations(socket) do
    %{organization: organization, current_user: user} = socket.assigns

    case Accounts.list_invitations(
           actor: user,
           query: [filter: [organization_id: organization.id]]
         ) do
      {:ok, invitations} ->
        invitations
        |> Enum.filter(&pending_invitation?/1)
        |> Enum.sort_by(&to_string(field(&1, :inserted_at)))

      {:error, _error} ->
        []
    end
  end

  defp invitation_form(params \\ %{}) do
    params =
      Map.merge(%{"email" => "", "role" => "member", "project_ids" => []}, stringify_keys(params))

    to_form(params, as: :invitation)
  end

  @impl Phoenix.LiveView
  def handle_event("validate_invitation", %{"invitation" => params}, socket) do
    {:noreply, assign(socket, :invitation_form, invitation_form(params))}
  end

  def handle_event("invite_member", %{"invitation" => params}, socket) do
    role = role_param(params["role"], socket.assigns.permission)

    attrs = %{
      organization_id: socket.assigns.organization.id,
      email: String.trim(params["email"] || ""),
      role: role,
      project_ids: invitation_project_ids(role, params, socket.assigns.permission)
    }

    case Accounts.invite_member(attrs, actor: socket.assigns.current_user) do
      {:ok, _invitation} ->
        {:noreply,
         socket
         |> assign(:invitation_form, invitation_form())
         |> load_members_page()
         |> put_flash(:info, "Invitation sent")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:invitation_form, invitation_form(params))
         |> put_flash(:error, ErrorText.message(error))}
    end
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    case find_by_id(socket.assigns.invitations, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Invitation not found.")}

      invitation ->
        case Accounts.revoke_invitation(invitation, actor: socket.assigns.current_user) do
          {:ok, _invitation} ->
            {:noreply, socket |> load_members_page() |> put_flash(:info, "Invitation revoked")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, ErrorText.message(error))}
        end
    end
  end

  def handle_event("change_role", %{"id" => id, "membership" => params}, socket) do
    with membership when not is_nil(membership) <- find_by_id(socket.assigns.members, id),
         role <- role_param(params["role"], socket.assigns.permission),
         true <- role_change_visible?(membership, role, socket.assigns.permission),
         {:ok, _membership} <-
           Accounts.change_member_role(membership, %{role: role},
             actor: socket.assigns.current_user
           ) do
      {:noreply, socket |> load_members_page() |> put_flash(:info, "Member role saved")}
    else
      nil -> {:noreply, put_flash(socket, :error, "Member not found.")}
      false -> {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
      {:error, error} -> {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    with membership when not is_nil(membership) <- find_by_id(socket.assigns.members, id),
         true <- remove_visible?(membership, socket.assigns.permission),
         {:ok, _membership} <- remove_membership(membership, socket.assigns.current_user) do
      {:noreply, socket |> load_members_page() |> put_flash(:info, "Member removed")}
    else
      nil -> {:noreply, put_flash(socket, :error, "Member not found.")}
      false -> {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
      {:error, error} -> {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  def handle_event("assign_projects", %{"id" => id, "membership" => params}, socket) do
    with membership when not is_nil(membership) <- find_by_id(socket.assigns.members, id),
         true <- project_assignment_visible?(membership, socket.assigns.permission),
         project_ids <- selected_project_ids(params, socket.assigns.permission.projects),
         {:ok, _membership} <-
           Accounts.assign_member_projects(membership, %{project_ids: project_ids},
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> load_members_page()
       |> push_patch(to: members_path(socket.assigns))
       |> put_flash(:info, "Project access saved")}
    else
      nil -> {:noreply, put_flash(socket, :error, "Member not found.")}
      false -> {:noreply, put_flash(socket, :error, "You don't have permission to do that.")}
      {:error, error} -> {:noreply, put_flash(socket, :error, ErrorText.message(error))}
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
  Join date as an absolute date.

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
        max_w={980}
      >
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <.invite_card :if={@permission.can_invite?} form={@invitation_form} permission={@permission} />

        <h2 id="members-heading" style="font-size:15px;font-weight:500;margin:16px 0 8px;">
          Members
        </h2>

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

            <.role_form membership={membership} permission={@permission} />
            <span style="font-size:12.5px;color:var(--tx-2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
              {project_list(membership, @member_projects)}
            </span>

            <span class="font-mono" style="font-size:12px;color:var(--tx-2);text-align:right;">
              {joined_on(membership.inserted_at)}
            </span>

            <div style="display:flex;justify-content:flex-end;gap:6px;">
              <DS.btn_link
                :if={project_assignment_visible?(membership, @permission)}
                id={"edit-projects-#{membership.id}"}
                variant="ghost"
                size="sm"
                patch={~p"/#{@org_slug}/members?projects=#{membership.id}"}
              >
                Projects
              </DS.btn_link>
              <DS.btn
                :if={remove_visible?(membership, @permission)}
                id={"remove-member-#{membership.id}"}
                variant="danger"
                size="sm"
                phx-click="remove_member"
                phx-value-id={membership.id}
                data-confirm={"Remove #{member_email(membership)} from this organization?"}
              >
                Remove
              </DS.btn>
            </div>
          </DS.row>
        </DS.table>

        <.pending_invitations
          :if={@invitations != []}
          invitations={@invitations}
          projects={@permission.projects}
          permission={@permission}
          cols={@invitation_cols}
        />

        <.project_editor_modal
          :if={@project_editor}
          editor={@project_editor}
          projects={@permission.projects}
          member_projects={@member_projects}
          org_slug={@org_slug}
        />
      </DS.screen>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :permission, :map, required: true

  defp invite_card(assigns) do
    ~H"""
    <SC.setting_card
      id="invite-member-card"
      title="Invite member"
      desc="Email an invitation link. The recipient must sign in with that address and click Join."
    >
      <.form
        for={@form}
        id="invite-member-form"
        phx-change="validate_invitation"
        phx-submit="invite_member"
      >
        <div style="display:grid;grid-template-columns:minmax(0,1fr) 150px;gap:10px;">
          <div>
            <SC.form_label text="email" />
            <DS.ds_input
              field={@form[:email]}
              type="email"
              placeholder="teammate@example.com"
              required
            />
          </div>
          <div>
            <SC.form_label text="role" />
            <DS.ds_select
              id="invite-role"
              field={@form[:role]}
              options={role_options(@permission)}
              mono
              w="100%"
            />
          </div>
        </div>

        <SC.form_label text="projects" style="margin-top:14px;" />
        <div id="invite-project-options" style="display:flex;flex-wrap:wrap;gap:6px;">
          <SC.checkbox_option
            :for={project <- @permission.invitable_projects}
            id={"invite-project-#{project.id}"}
            name="invitation[project_ids][]"
            value={project.id}
            label={project_label(project)}
            checked={to_string(project.id) in List.wrap(@form[:project_ids].value)}
          />
        </div>
      </.form>
      <:footer>
        <span style="font-size:12px;color:var(--tx-3);line-height:1.45;">
          Admin invitations grant all projects. Member invitations use the selected projects.
        </span>
        <DS.btn
          id="send-invitation"
          variant="primary"
          icon="send"
          form="invite-member-form"
          type="submit"
          style="margin-left:auto;"
        >
          Send invitation
        </DS.btn>
      </:footer>
    </SC.setting_card>
    """
  end

  attr :membership, :map, required: true
  attr :permission, :map, required: true

  defp role_form(assigns) do
    assigns =
      assigns
      |> assign(:current_role, field(assigns.membership, :role) || :member)
      |> assign(:can_change?, role_form_visible?(assigns.membership, assigns.permission))

    ~H"""
    <%= if @can_change? do %>
      <.form
        for={to_form(%{"role" => to_string(@current_role)}, as: :membership)}
        id={"member-role-form-#{@membership.id}"}
        phx-submit="change_role"
        phx-value-id={@membership.id}
        style="display:flex;align-items:center;gap:6px;"
      >
        <DS.ds_select
          id={"member-role-#{@membership.id}"}
          name="membership[role]"
          value={to_string(@current_role)}
          options={role_options(@permission)}
          mono
          w={96}
        />
        <DS.icon_btn
          name="check"
          size={28}
          title="Save role"
          form={"member-role-form-#{@membership.id}"}
          type="submit"
        />
      </.form>
    <% else %>
      <DS.badge tone={role_tone(@current_role)} mono>{@current_role}</DS.badge>
    <% end %>
    """
  end

  attr :invitations, :list, required: true
  attr :projects, :list, required: true
  attr :permission, :map, required: true
  attr :cols, :list, required: true

  defp pending_invitations(assigns) do
    ~H"""
    <div style="margin-top:14px;">
      <h2
        id="pending-invitations-heading"
        style="font-size:15px;font-weight:500;margin:0 0 8px;"
      >
        Pending invitations
      </h2>

      <DS.table id="pending-invitations-table" cols={@cols}>
        <DS.row
          :for={{invitation, index} <- Enum.with_index(@invitations)}
          id={"invitation-row-#{field(invitation, :id)}"}
          cols={@cols}
          index={index}
        >
          <span
            class="font-mono"
            style="font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
          >
            {field(invitation, :email)}
          </span>
          <DS.badge tone={role_tone(field(invitation, :role))} mono>
            {field(invitation, :role)}
          </DS.badge>
          <span style="font-size:12.5px;color:var(--tx-2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
            {invitation_project_list(invitation, @projects)}
          </span>
          <div style="display:flex;justify-content:flex-end;">
            <DS.btn
              :if={invitation_revoke_visible?(invitation, @permission)}
              id={"revoke-invitation-#{field(invitation, :id)}"}
              variant="ghost"
              size="sm"
              phx-click="revoke_invitation"
              phx-value-id={field(invitation, :id)}
            >
              Revoke
            </DS.btn>
          </div>
        </DS.row>
      </DS.table>
    </div>
    """
  end

  attr :editor, :map, required: true
  attr :projects, :list, required: true
  attr :member_projects, :map, required: true
  attr :org_slug, :string, required: true

  defp project_editor_modal(assigns) do
    assigns =
      assigns
      |> assign(:membership, assigns.editor.membership)
      |> assign(
        :assigned_ids,
        assigned_project_ids(assigns.editor.membership, assigns.member_projects)
      )

    ~H"""
    <DS.modal
      id="member-projects-modal"
      title={"Project access for #{member_email(@membership)}"}
      icon="folder"
      width={520}
      on_close={~p"/#{@org_slug}/members"}
    >
      <.form
        for={to_form(%{"project_ids" => @assigned_ids}, as: :membership)}
        id="member-projects-form"
        phx-submit="assign_projects"
        phx-value-id={@membership.id}
      >
        <p style="margin:0 0 12px;color:var(--tx-2);font-size:13px;line-height:1.45;">
          Select the projects this member can access. Admins and owners automatically have every project.
        </p>
        <div id="member-project-options" style="display:flex;flex-direction:column;gap:7px;">
          <SC.checkbox_option
            :for={project <- @projects}
            id={"member-project-#{project.id}"}
            name="membership[project_ids][]"
            value={project.id}
            label={project_label(project)}
            checked={to_string(project.id) in @assigned_ids}
          />
          <span :if={@projects == []} style="font-size:13px;color:var(--tx-3);">
            This organization has no active projects yet.
          </span>
        </div>
      </.form>
      <:footer>
        <DS.btn_link variant="ghost" patch={~p"/#{@org_slug}/members"}>Cancel</DS.btn_link>
        <DS.btn
          id="save-member-projects"
          variant="primary"
          icon="check"
          form="member-projects-form"
          type="submit"
          style="margin-left:auto;"
        >
          Save project access
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end

  defp remove_membership(membership, actor), do: Accounts.remove_member(membership, actor: actor)

  defp pending_invitation?(record) do
    is_nil(field(record, :accepted_at)) and is_nil(field(record, :revoked_at)) and
      future?(field(record, :expires_at))
  end

  defp future?(%DateTime{} = datetime), do: DateTime.compare(datetime, DateTime.utc_now()) == :gt
  defp future?(_datetime), do: true

  defp invitation_revoke_visible?(_invitation, %{manage?: true}), do: true

  defp invitation_revoke_visible?(invitation, permission) do
    field(invitation, :role) == :member and
      project_ids_allowed?(field(invitation, :project_ids), permission.invitable_projects)
  end

  defp project_ids_allowed?(project_ids, allowed_projects) when is_list(project_ids) do
    allowed = MapSet.new(allowed_projects, &to_string(&1.id))

    project_ids != [] and Enum.all?(project_ids, &MapSet.member?(allowed, to_string(&1)))
  end

  defp project_ids_allowed?(_project_ids, _allowed_projects), do: false

  defp assign_member_projects(socket) do
    grants = project_memberships(socket.assigns.members, socket.assigns.current_user)

    assign(socket, :member_projects, grants)
  end

  defp project_memberships(memberships, actor) do
    user_ids =
      memberships
      |> Enum.map(&field(&1, :user_id))
      |> Enum.reject(&is_nil/1)

    case read_project_memberships(user_ids, actor) do
      {:ok, grants} ->
        grants
        |> Enum.group_by(&field(&1, :user_id), &field(&1, :project))
        |> Map.new(fn {user_id, projects} ->
          {to_string(user_id), Enum.reject(projects, &is_nil/1)}
        end)

      {:error, _error} ->
        %{}
    end
  end

  defp read_project_memberships([], _actor), do: {:ok, []}

  defp read_project_memberships(user_ids, actor) do
    PromptOn.Projects.ProjectMembership
    |> Ash.Query.filter(user_id in ^user_ids)
    |> Ash.Query.load(:project)
    |> Ash.read(actor: actor)
  end

  defp role_options(%{can_grant_admin?: true}), do: [{"member", "member"}, {"admin", "admin"}]
  defp role_options(_permission), do: [{"member", "member"}]

  defp role_param("admin", %{can_grant_admin?: true}), do: :admin
  defp role_param(_role, _permission), do: :member

  defp role_form_visible?(membership, permission) do
    current = field(membership, :role)

    cond do
      current == :owner -> false
      permission.owner? -> true
      permission.can_grant_admin? and current == :member -> true
      true -> false
    end
  end

  defp role_change_visible?(membership, role, permission) do
    current = field(membership, :role)

    cond do
      current == :owner -> false
      permission.owner? -> role in [:member, :admin]
      permission.can_grant_admin? and current == :member -> role == :admin
      true -> false
    end
  end

  defp remove_visible?(membership, permission) do
    current = field(membership, :role)

    cond do
      current == :owner -> false
      permission.owner? -> true
      permission.manage? and current == :member -> true
      true -> false
    end
  end

  defp project_assignment_visible?(membership, permission) do
    permission.manage? and Permissions.normalize_role(field(membership, :role)) == :member
  end

  defp invitation_project_ids(:admin, _params, permission),
    do: Enum.map(permission.projects, & &1.id)

  defp invitation_project_ids(:member, params, permission),
    do: selected_project_ids(params, permission.invitable_projects)

  defp selected_project_ids(params, allowed_projects) do
    allowed = MapSet.new(Enum.map(allowed_projects, &to_string(&1.id)))

    params
    |> Map.get("project_ids", [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&MapSet.member?(allowed, &1))
  end

  defp project_list(record, member_projects) do
    projects = Map.get(member_projects, to_string(field(record, :user_id)), [])

    cond do
      field(record, :role) in [:admin, :owner] -> "All projects"
      projects != [] -> Enum.map_join(projects, ", ", &project_label/1)
      true -> "No projects"
    end
  end

  defp invitation_project_list(record, organization_projects) do
    projects = field(record, :projects)
    ids = field(record, :project_ids)
    metadata_projects = invitation_projects(record)

    cond do
      metadata_projects != [] -> Enum.map_join(metadata_projects, ", ", &project_label/1)
      is_list(projects) and projects != [] -> Enum.map_join(projects, ", ", &project_label/1)
      is_list(ids) and ids != [] -> project_labels(ids, organization_projects)
      field(record, :role) in [:admin, :owner] -> "All projects"
      true -> "No projects"
    end
  end

  defp invitation_projects(invitation) do
    case Ash.Resource.get_metadata(invitation, :projects) do
      projects when is_list(projects) -> projects
      _other -> []
    end
  rescue
    _error -> []
  end

  defp project_labels(ids, projects) do
    lookup = Map.new(projects, &{to_string(&1.id), project_label(&1)})

    Enum.map_join(ids, ", ", fn id -> Map.get(lookup, to_string(id), to_string(id)) end)
  end

  defp assigned_project_ids(membership, member_projects) do
    member_projects
    |> Map.get(to_string(field(membership, :user_id)), [])
    |> Enum.map(&to_string(field(&1, :id)))
  end

  defp project_editor(%{"projects" => id}, assigns) do
    membership = find_by_id(assigns.members, id)

    if membership && project_assignment_visible?(membership, assigns.permission) do
      %{membership: membership}
    end
  end

  defp project_editor(_params, _assigns), do: nil

  defp members_path(assigns), do: ~p"/#{assigns.org_slug}/members"

  defp project_label(%{slug: slug}) when is_binary(slug), do: slug
  defp project_label(project), do: to_string(project)

  defp role_tone(:owner), do: :accent
  defp role_tone(:admin), do: :violet
  defp role_tone(_role), do: :neutral

  defp sort_projects(projects), do: Enum.sort_by(List.wrap(projects), &project_label/1)

  defp find_by_id(records, id),
    do: Enum.find(records, &(to_string(field(&1, :id)) == to_string(id)))

  defp ok_or_value({:ok, value}, _default), do: value
  defp ok_or_value(value, _default) when is_boolean(value), do: value
  defp ok_or_value(value, _default) when is_atom(value), do: value
  defp ok_or_value(value, _default) when is_list(value), do: value
  defp ok_or_value(_value, default), do: default

  defp field(nil, _field), do: nil

  defp field(map, field) when is_map(map),
    do: Map.get(map, field) || Map.get(map, to_string(field))

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
