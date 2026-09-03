defmodule PromptOnWeb.SettingsLive do
  @moduledoc """
  Project settings (`/:org_slug/:project_slug/settings`, mockup `s_settings.jsx` SettingsScreen).

  **The target of the open modal** always travels in the URL as a query parameter (CLAUDE.md
  zero-downtime deployment discipline):

  | URL | Screen |
  |---|---|
  | (none) | General · Environments · Delete project |
  | `?env=new` / `?env=<id>` | add / edit environment |
  | `?delete=1` | project deletion confirmation |

  Models themselves are not registered here; the use case hub's model picker puts them in the
  catalog the moment one is chosen. **Provider keys (BYOK) are not here either**: on 2026-09-01 the
  owning unit moved up to the organization and they gathered in one place,
  `PromptOnWeb.OrgSettingsLive` (`/{org}/settings?tab=providers`). **PromptOn SDK keys are not
  here either**: the sidebar overhaul of the same day moved them out to their own screen
  (`PromptOnWeb.ApiKeysLive`, `/{org}/{project}/api-keys`). **Nor are context dimensions**: when
  deployments turned from routers into pins (ADR 0007 revision 2026-09-01) the rule conditions that
  were the dimensions' only consumer disappeared, and `Project.dimensions` itself was deleted. So
  this screen has no tabs; what remains is what belongs to the project itself (name · environments
  · deletion).

  ## Deliberate differences from the mockup

  - **key (slug) is read-only.** The slug is already baked into URLs, SDK config and issued key
    prefixes, so changing it would stop running apps. Instead of the mockup's editable `key` field
    there is a read-only field plus a note.
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Deployments
  alias PromptOn.Projects
  alias PromptOnWeb.ErrorText
  alias PromptOnWeb.SettingsComponents, as: SC

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Settings · #{socket.assigns.project.slug}",
       modal: nil,
       form: nil,
       general_form: to_form(%{"name" => socket.assigns.project.name}, as: :project),
       env_rows: []
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> load_env_rows() |> apply_modal(params)}
  end

  # ---------------------------------------------------------------------------
  # Data

  defp load_env_rows(socket) do
    assign(socket, :env_rows, Enum.map(socket.assigns.envs, &env_row(&1, socket)))
  end

  defp env_row(env, socket) do
    count =
      case Deployments.current_deployments_for_environment(env.id, scope(socket)) do
        {:ok, deployments} -> length(deployments)
        {:error, _error} -> 0
      end

    %{env: env, deployment_count: count}
  end

  defp scope(socket),
    do: [tenant: socket.assigns.project.id, actor: socket.assigns.current_user]

  defp settings_path(socket) do
    %{org_slug: org_slug, project: project} = socket.assigns
    ~p"/#{org_slug}/#{project.slug}/settings"
  end

  # ---------------------------------------------------------------------------
  # Modal (URL target)

  defp apply_modal(socket, %{"env" => "new"}) do
    params = %{"slug" => "", "name" => "", "protected" => "false"}
    assign(socket, modal: :env_new, form: to_form(params, as: :environment))
  end

  defp apply_modal(socket, %{"env" => id}) do
    case Enum.find(socket.assigns.envs, &(&1.id == id)) do
      nil ->
        close_modal(socket)

      env ->
        params = %{
          "slug" => env.slug,
          "name" => env.name,
          "protected" => to_string(env.protected?)
        }

        assign(socket, modal: {:env, env}, form: to_form(params, as: :environment))
    end
  end

  defp apply_modal(socket, %{"delete" => "1"}) do
    assign(socket, modal: :delete, form: to_form(%{"slug" => ""}, as: :confirm))
  end

  defp apply_modal(socket, _params), do: close_modal(socket)

  defp close_modal(socket), do: assign(socket, modal: nil)

  # ---------------------------------------------------------------------------
  # Events: form recovery (CLAUDE.md zero-downtime deployment discipline)

  # The modal target is in the URL, but **the input values** are revived by Phoenix form recovery.
  # Recovery only replays forms that carry `phx-change`, so every form on the screen must have this
  # handler attached. Validation is done by the domain on save, so here the incoming values are
  # only put into the form as is.
  @impl Phoenix.LiveView
  def handle_event("validate_general", %{"project" => params}, socket) do
    {:noreply, assign(socket, :general_form, to_form(params, as: :project))}
  end

  def handle_event("validate_form", params, socket) do
    {:noreply, assign(socket, :form, restore_form(socket.assigns.form, params))}
  end

  # ---------------------------------------------------------------------------
  # Events: Project tab

  def handle_event("save_project", %{"project" => params}, socket) do
    case Projects.rename_project(
           socket.assigns.project,
           %{name: params["name"]},
           actor: socket.assigns.current_user
         ) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:general_form, to_form(%{"name" => project.name}, as: :project))
         |> put_flash(:info, "Project saved")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  def handle_event("save_environment", %{"environment" => params}, socket) do
    attrs = %{
      name: String.trim(params["name"] || ""),
      protected?: params["protected"] == "true"
    }

    result =
      case socket.assigns.modal do
        {:env, env} -> Projects.rename_environment(env, attrs, scope(socket))
        _new -> Projects.add_environment(add_env_attrs(attrs, params, socket), scope(socket))
      end

    case result do
      {:ok, env} ->
        {:noreply,
         socket
         |> refresh_envs()
         |> put_flash(:info, "Environment #{env.slug} saved")
         |> push_patch(to: settings_path(socket))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  def handle_event("archive_project", %{"confirm" => %{"slug" => typed}}, socket) do
    project = socket.assigns.project

    if String.trim(typed) == project.slug do
      case Projects.archive_project(project, actor: socket.assigns.current_user) do
        {:ok, _project} ->
          {:noreply,
           socket
           |> put_flash(:info, "Project #{project.slug} deleted")
           |> push_navigate(to: ~p"/#{socket.assigns.org_slug}")}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, ErrorText.message(error))}
      end
    else
      {:noreply, put_flash(socket, :error, "Project key does not match.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp restore_form(%Phoenix.HTML.Form{name: name} = form, params) do
    case params do
      %{^name => values} when is_map(values) -> to_form(values, as: name)
      _other -> form
    end
  end

  defp restore_form(form, _params), do: form

  defp refresh_envs(socket) do
    envs =
      PromptOnWeb.LiveProjectScope.list_environments(
        socket.assigns.project,
        socket.assigns.current_user
      )

    socket |> assign(:envs, envs) |> load_env_rows()
  end

  defp add_env_attrs(attrs, params, socket) do
    attrs
    |> Map.put(:slug, String.trim(params["slug"] || ""))
    |> Map.put(:position, length(socket.assigns.envs))
  end

  # ---------------------------------------------------------------------------
  # Render

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
      nav={:settings}
    >
      <DS.screen
        id="settings-screen"
        title="Settings"
        sub={settings_sub(@project, @organization)}
        max_w={880}
      >
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <:crumb label={@project.slug} navigate={~p"/#{@org_slug}/#{@project.slug}"} />
        <.project_settings
          org_slug={@org_slug}
          project={@project}
          general_form={@general_form}
          env_rows={@env_rows}
        />

        <.environment_modal
          :if={@modal == :env_new or match?({:env, _env}, @modal)}
          org_slug={@org_slug}
          project={@project}
          form={@form}
          modal={@modal}
        />
        <.delete_modal :if={@modal == :delete} org_slug={@org_slug} project={@project} form={@form} />
      </DS.screen>
    </Layouts.app>
    """
  end

  # The organization and project are already in the crumbs; the subtitle keeps only the project's
  # human-readable name.
  defp settings_sub(project, _organization), do: project.name

  # --- Project settings ------------------------------------------------------

  attr :org_slug, :string, required: true
  attr :project, :map, required: true
  attr :general_form, :map, required: true
  attr :env_rows, :list, required: true

  defp project_settings(assigns) do
    ~H"""
    <div id="settings-project">
      <SC.setting_card
        id="general-card"
        title="General"
        desc="A project is the tenant boundary — it owns use cases, models, and logs."
      >
        <form
          id="general-form"
          phx-submit="save_project"
          phx-change="validate_general"
          style="display:flex;gap:12px;"
        >
          <div style="flex:1;">
            <SC.form_label text="key" />
            <DS.ds_input id="project-key" name="project[slug]" value={@project.slug} mono readonly />
          </div>
          <div style="flex:1;">
            <SC.form_label text="name" />
            <DS.ds_input id="project-name" field={@general_form[:name]} />
          </div>
        </form>
        <:footer>
          <span style="font-size:12.5px;color:var(--tx-2);margin-right:auto;line-height:1.5;">
            key cannot be changed — it is already baked into SDK config, issued key prefixes, and URLs.
          </span>
          <DS.btn id="save-project" variant="primary" form="general-form" type="submit">Save</DS.btn>
        </:footer>
      </SC.setting_card>

      <SC.setting_card
        id="environments-card"
        title="Environments"
        desc="Deployments are committed per environment. Protected environments require confirmation to commit."
      >
        <div style="display:flex;flex-direction:column;gap:6px;">
          <SC.row_box :for={row <- @env_rows} id={"env-row-#{row.env.slug}"}>
            <DSIcons.icon
              name={if row.env.protected?, do: "lock", else: "globe"}
              size={14}
              class="tx2"
            />
            <span class="font-mono" style="font-size:13.5px;font-weight:500;">{row.env.name}</span>
            <span class="font-mono" style="font-size:12px;color:var(--tx-3);">{row.env.slug}</span>
            <DS.badge :if={row.env.protected?} tone={:accent} mono style="font-size:10px;">
              protected
            </DS.badge>
            <span class="font-mono" style="margin-left:auto;font-size:12px;color:var(--tx-2);">
              {row.deployment_count} live deployments
            </span>
            <DS.icon_btn
              id={"manage-env-#{row.env.slug}"}
              name="more"
              size={24}
              title="Manage"
              patch={~p"/#{@org_slug}/#{@project.slug}/settings?env=#{row.env.id}"}
            />
          </SC.row_box>
        </div>
        <:footer>
          <DS.btn_link
            id="add-environment"
            variant="outline"
            icon="plus"
            style="margin-left:auto;"
            patch={~p"/#{@org_slug}/#{@project.slug}/settings?env=new"}
          >
            Add environment
          </DS.btn_link>
        </:footer>
      </SC.setting_card>

      <SC.setting_card
        id="danger-card"
        title="Delete project"
        danger
        desc="Takes the project and its use cases, deployments, and logs out of service. This cannot be undone."
      >
        <:footer>
          <DS.btn_link
            id="delete-project"
            variant="danger"
            icon="trash"
            style="margin-left:auto;"
            patch={~p"/#{@org_slug}/#{@project.slug}/settings?delete=1"}
          >
            Delete project
          </DS.btn_link>
        </:footer>
      </SC.setting_card>
    </div>
    """
  end

  # --- Modals ----------------------------------------------------------------

  attr :org_slug, :string, required: true
  attr :project, :map, required: true
  attr :form, :map, required: true
  attr :modal, :any, required: true

  defp environment_modal(assigns) do
    assigns = assign(assigns, :env, if(is_tuple(assigns.modal), do: elem(assigns.modal, 1)))

    ~H"""
    <DS.modal
      id="environment-modal"
      on_close={~p"/#{@org_slug}/#{@project.slug}/settings"}
      width={460}
      icon="globe"
      title={if @env, do: "Edit environment", else: "Add environment"}
    >
      <.form
        for={@form}
        id="environment-form"
        phx-submit="save_environment"
        phx-change="validate_form"
      >
        <SC.form_label text="slug" />
        <DS.ds_input
          field={@form[:slug]}
          mono
          placeholder="development"
          readonly={not is_nil(@env)}
          required
        />
        <SC.form_label text="name" style="margin-top:14px;" />
        <DS.ds_input field={@form[:name]} placeholder="Development" required />
        <SC.form_label text="protected" style="margin-top:14px;" />
        <div :if={protected_locked?(@env)} style="display:flex;align-items:center;gap:7px;">
          <DS.badge tone={:accent} mono style="font-size:10px;">protected</DS.badge>
          <span style="font-size:12.5px;color:var(--tx-2);">
            Protection on the default environment cannot be changed — the activation confirmation step would disappear.
          </span>
          <input type="hidden" name="environment[protected]" value="true" />
        </div>
        <div :if={not protected_locked?(@env)}>
          <input type="hidden" name="environment[protected]" value="false" />
          <SC.checkbox_option
            id="env-protected"
            name="environment[protected]"
            value="true"
            label="Require confirmation to activate"
            checked={@form[:protected].value == "true"}
          />
        </div>
      </.form>
      <:footer>
        <DS.btn_link variant="ghost" patch={~p"/#{@org_slug}/#{@project.slug}/settings"}>
          Cancel
        </DS.btn_link>
        <DS.btn variant="primary" icon="check" form="environment-form" type="submit">Save</DS.btn>
      </:footer>
    </DS.modal>
    """
  end

  # Protection on the default environment (production) cannot be turned off from the screen; the
  # mockup's protected badge is display-only here.
  defp protected_locked?(%{slug: "production"}), do: true
  defp protected_locked?(_env), do: false

  attr :org_slug, :string, required: true
  attr :project, :map, required: true
  attr :form, :map, required: true

  defp delete_modal(assigns) do
    ~H"""
    <DS.modal
      id="delete-project-modal"
      on_close={~p"/#{@org_slug}/#{@project.slug}/settings"}
      width={460}
      icon="alert"
      title="Delete project"
    >
      <.form
        for={@form}
        id="delete-project-form"
        phx-submit="archive_project"
        phx-change="validate_form"
      >
        <div style="font-size:13.5px;color:var(--tx-1);line-height:1.6;margin-bottom:12px;">
          Type the project key
          <span class="font-mono" style="color:var(--err);">{@project.slug}</span>
          to confirm. Snapshots and the API stop serving this project immediately.
        </div>
        <DS.ds_input field={@form[:slug]} mono placeholder={@project.slug} />
      </.form>
      <:footer>
        <DS.btn_link variant="ghost" patch={~p"/#{@org_slug}/#{@project.slug}/settings"}>
          Cancel
        </DS.btn_link>
        <DS.btn
          id="confirm-delete-project"
          variant="danger"
          icon="trash"
          form="delete-project-form"
          type="submit"
        >
          Delete project
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end
end
