defmodule PromptOnWeb.OrgHomeLive do
  @moduledoc """
  Organization home = **that organization's project list** (`/:org_slug`, mockup `s_overview.jsx`).

  `/personal` is the current user's personal organization, and a team organization arrives by its
  own slug; either way `PromptOnWeb.LiveProjectScope` has already filled `@organization @org_slug
  @projects`. A project created from this screen goes into **the organization being viewed**.

  Each card shows the project's **use case count** and **environment slugs**. Both are tenant
  queries under the project, so they are read once per project (projects are at a scale that fits
  entirely in the sidebar switcher).

  The new project modal travels in the URL as `?new=1` (CLAUDE.md zero-downtime deployment
  discipline): when a deploy drops the socket and remounts, the modal stays open. The form is an
  `AshPhoenix.Form`; the key is the project's slug and the optional description gives the project
  list a small human note. Project slugs are unique **per organization**, so they do not collide
  with the same slug in another organization.

  ## Setup card (when there is no provider key)

  When the organization has no BYOK key at all, a **setup card** stands above the project list,
  the same for a personal organization right after sign-up and for a team organization just
  created. The provider is **fixed to OpenRouter alone** (decision of 2026-09-01,
  `PromptOn.Accounts.ProviderKey`), so there is nothing to choose: the card is a single key input,
  and the copy states that there is only one set right now ("More providers later"). The key can be
  registered in place (organization-owned), and "Do this later" collapses the card for **this
  session only** (a single assign, not persisted; it shows again on the next visit). Once there is
  at least one key the card never shows again.

  Why "later" is not persisted: persisting it would need somewhere to keep a per-user,
  per-organization dismissal, and the domain has no such thing. Rather than inventing one, the card
  looks only at a fact that already exists: **whether a key exists**.

  ## New organization (`?new_org=1`)

  Creating a team organization is a modal on this screen. The creator becomes the first owner
  member (the domain's `Organization.Changes.AddCreatorAsOwner`), and on success the user lands on
  the new organization's home.
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Accounts
  alias PromptOn.Accounts.Permissions
  alias PromptOn.Prompts
  alias PromptOnWeb.ErrorText
  alias PromptOnWeb.OrgSettingsLive
  alias PromptOnWeb.SettingsComponents, as: SC

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Projects · #{Layouts.org_label(socket.assigns.organization)}",
       setup_dismissed?: false,
       setup_form: setup_form(),
       org_form: nil
     )
     |> assign_provider_keys()
     |> assign_cards()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:new_form, new_form(socket, params))
     |> assign(:org_form, org_form(socket, params))}
  end

  defp new_form(socket, %{"new" => "1"}), do: socket.assigns[:new_form] || build_form(socket, %{})
  defp new_form(_socket, _params), do: nil

  defp org_form(socket, %{"new_org" => "1"}),
    do: socket.assigns[:org_form] || to_form(%{"name" => "", "slug" => ""}, as: :organization)

  defp org_form(_socket, _params), do: nil

  defp setup_form, do: to_form(%{"secret" => ""}, as: :provider_key)

  # The setup card is decided by one fact, "does this organization have any key at all"; there is
  # no stored dismissal.
  defp assign_provider_keys(socket) do
    keys =
      OrgSettingsLive.provider_keys(socket.assigns.organization, socket.assigns.current_user)

    assign(socket, :provider_keys, keys)
  end

  @doc "Whether to draw the setup card: no key at all, manager-only, and not dismissed."
  @spec show_setup?(map()) :: boolean()
  def show_setup?(%{provider_keys: [], setup_dismissed?: false} = assigns),
    do: provider_setup_manage?(assigns)

  def show_setup?(_assigns), do: false

  defp provider_setup_manage?(%{current_user: user, organization: %{id: organization_id}}),
    do: Permissions.manage?(user, organization_id)

  defp provider_setup_manage?(_assigns), do: false

  defp build_form(socket, params) do
    PromptOn.Projects.Project
    |> AshPhoenix.Form.for_create(:create,
      domain: PromptOn.Projects,
      actor: socket.assigns.current_user,
      params: params
    )
    |> to_form()
  end

  # ---------------------------------------------------------------------------
  # Data

  defp assign_cards(socket) do
    user = socket.assigns.current_user
    assign(socket, :cards, Enum.map(socket.assigns.projects, &card(&1, user)))
  end

  defp card(project, user) do
    %{
      project: project,
      color: DS.project_color(project.slug),
      use_case_count: count_use_cases(project, user),
      env_slugs: env_slugs(project, user)
    }
  end

  defp count_use_cases(project, user) do
    case Prompts.list_use_cases(tenant: project.id, actor: user) do
      {:ok, use_cases} -> length(use_cases)
      {:error, _error} -> 0
    end
  end

  defp env_slugs(project, user) do
    project
    |> PromptOnWeb.LiveProjectScope.list_environments(user)
    |> Enum.map(& &1.slug)
  end

  # A project goes into **the organization being viewed**, the one the scope hook already resolved
  # (even with no projects at all, `@organization` comes from the URL segment and is always there).
  defp organization_id(socket) do
    case socket.assigns.organization do
      %{id: id} -> id
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Events: setup card (provider key)

  @impl Phoenix.LiveView
  def handle_event("validate_setup", %{"provider_key" => params}, socket) do
    {:noreply, assign(socket, :setup_form, to_form(params, as: :provider_key))}
  end

  def handle_event("connect_provider", %{"provider_key" => params}, socket) do
    attrs = %{
      organization_id: socket.assigns.organization.id,
      provider: :openrouter,
      label: "default",
      secret: params["secret"] || ""
    }

    case Accounts.register_provider_key(attrs, actor: socket.assigns.current_user) do
      {:ok, _key} ->
        {:noreply,
         socket
         |> assign(:setup_form, setup_form())
         |> assign_provider_keys()
         |> put_flash(:info, "Provider key stored (encrypted)")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  # Session-only; not persisted (see the module docs).
  def handle_event("dismiss_setup", _params, socket) do
    {:noreply, assign(socket, :setup_dismissed?, true)}
  end

  # ---------------------------------------------------------------------------
  # Events: new organization

  def handle_event("validate_org", %{"organization" => params}, socket) do
    {:noreply, assign(socket, :org_form, to_form(suggest_org_slug(params), as: :organization))}
  end

  def handle_event("create_org", %{"organization" => params}, socket) do
    params = suggest_org_slug(params)

    attrs = %{
      name: String.trim(params["name"] || ""),
      slug: String.trim(params["slug"] || "")
    }

    case Accounts.create_organization(attrs, actor: socket.assigns.current_user) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> put_flash(:info, "Organization #{organization.slug} created")
         |> push_navigate(to: ~p"/#{organization.slug}")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:org_form, to_form(params, as: :organization))
         |> put_flash(:error, ErrorText.message(error))}
    end
  end

  # ---------------------------------------------------------------------------
  # Events: new project

  def handle_event("validate_project", %{"form" => params}, socket) do
    {:noreply,
     assign(socket, :new_form, AshPhoenix.Form.validate(socket.assigns.new_form, params))}
  end

  def handle_event("create_project", %{"form" => params}, socket) do
    case organization_id(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "Organization not found.")}

      org_id ->
        submit_project(socket, Map.put(params, "organization_id", org_id))
    end
  end

  defp submit_project(socket, params) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project #{project.slug} created")
         |> push_navigate(to: ~p"/#{socket.assigns.org_slug}/#{project.slug}")}

      {:error, form} ->
        {:noreply, socket |> assign(:new_form, form) |> put_flash(:error, form_errors(form))}
    end
  end

  defp form_errors(form) do
    case AshPhoenix.Form.errors(form) do
      [] -> "Couldn't create the project."
      errors -> Enum.map_join(errors, " · ", fn {field, message} -> "#{field}: #{message}" end)
    end
  end

  defp suggest_org_slug(%{"slug" => slug} = params) when is_binary(slug) do
    if String.trim(slug) == "", do: %{params | "slug" => slugify(params["name"])}, else: params
  end

  defp suggest_org_slug(params), do: Map.put(params, "slug", slugify(params["name"]))

  @doc """
  Text → slug suggestion for organization names. Only produces values that satisfy the slug constraint
  (`^[a-z0-9][a-z0-9-]{0,62}$`).

      iex> PromptOnWeb.OrgHomeLive.slugify("Acme Helpdesk!")
      "acme-helpdesk"

      iex> PromptOnWeb.OrgHomeLive.slugify(nil)
      ""
  """
  @spec slugify(String.t() | nil) :: String.t()
  def slugify(nil), do: ""

  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 63)
    |> String.trim("-")
  end

  defp project_description(%{description: description}) when is_binary(description) do
    case String.trim(description) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp project_description(_project), do: nil

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
      nav={:projects}
    >
      <DS.screen
        id="org-home-screen"
        title="Projects"
        max_w={900}
      >
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <:actions>
          <DS.btn_link
            id="new-org-btn"
            variant="outline"
            icon="building"
            patch={~p"/#{@org_slug}?new_org=1"}
          >
            New organization
          </DS.btn_link>
          <DS.btn_link
            id="new-project-btn"
            variant="primary"
            icon="plus"
            patch={~p"/#{@org_slug}?new=1"}
          >
            New project
          </DS.btn_link>
        </:actions>

        <.setup_card :if={show_setup?(assigns)} org_slug={@org_slug} form={@setup_form} />

        <DS.empty
          :if={@cards == []}
          id="projects-empty"
          icon="layers"
          title="No projects yet"
          sub="A project is a tenant — it owns your use cases, models, and logs."
        >
          <:action>
            <DS.btn_link variant="primary" icon="plus" patch={~p"/#{@org_slug}?new=1"}>
              New project
            </DS.btn_link>
          </:action>
        </DS.empty>

        <div
          :if={@cards != []}
          id="project-cards"
          style="display:grid;grid-template-columns:1fr 1fr;gap:12px;"
        >
          <div
            :for={card <- @cards}
            id={"project-card-#{card.project.slug}"}
            class="card2 tr"
            style="padding:16px;position:relative;"
          >
            <.link
              id={"open-project-#{card.project.slug}"}
              navigate={~p"/#{@org_slug}/#{card.project.slug}"}
              style="display:block;color:inherit;text-decoration:none;"
            >
              <div style="display:flex;align-items:center;gap:10px;margin-bottom:14px;">
                <span style={
                  DS.style_list([
                    "width:30px;height:30px;border-radius:var(--r);flex-shrink:0;",
                    "background:#{card.color}22;border:1px solid #{card.color}55;",
                    "display:flex;align-items:center;justify-content:center;"
                  ])
                }>
                  <span style={"width:10px;height:10px;border-radius:var(--r-pill);background:#{card.color};"} />
                </span>
                <div style="min-width:0;">
                  <div class="font-mono" style="font-size:15px;font-weight:650;">
                    {card.project.slug}
                  </div>
                  <div
                    :if={project_description(card.project)}
                    id={"project-card-description-#{card.project.slug}"}
                    style="font-size:12.5px;color:var(--tx-2);margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
                  >
                    {project_description(card.project)}
                  </div>
                </div>
              </div>
              <div style="display:flex;align-items:center;gap:14px;">
                <span style="display:inline-flex;align-items:center;gap:5px;font-size:13px;color:var(--tx-2);">
                  <DSIcons.icon name="target" size={13} />
                  <span class="font-mono">{card.use_case_count}</span> use cases
                </span>
                <span style="margin-left:auto;display:flex;gap:3px;">
                  <DS.badge :for={slug <- card.env_slugs} tone={:neutral} mono style="font-size:10px;">
                    {slug}
                  </DS.badge>
                </span>
              </div>
            </.link>
            <span style="position:absolute;top:14px;right:14px;">
              <DS.icon_btn
                id={"manage-project-#{card.project.slug}"}
                name="more"
                title="Manage"
                navigate={~p"/#{@org_slug}/#{card.project.slug}/settings"}
              />
            </span>
          </div>
        </div>

        <DS.modal
          :if={@new_form}
          id="new-project-modal"
          on_close={~p"/#{@org_slug}"}
          width={460}
          icon="layers"
          title="New project"
        >
          <.form
            for={@new_form}
            id="new-project-form"
            phx-change="validate_project"
            phx-submit="create_project"
          >
            <SC.form_label text="key" />
            <DS.ds_input field={@new_form[:slug]} mono placeholder="helpdesk" required />
            <SC.field_error field={@new_form[:slug]} />
            <SC.form_label text="description" style="margin-top:14px;" />
            <textarea
              id="project-description"
              name="form[description]"
              style="width:100%;min-height:82px;border:1px solid var(--line-2);border-radius:var(--r);background:var(--bg-0);color:var(--tx-0);font-size:13px;line-height:1.5;padding:9px 10px;resize:vertical;"
              placeholder="What this project is for"
            >{Phoenix.HTML.Form.normalize_value("textarea", @new_form[:description].value)}</textarea>
            <SC.field_error field={@new_form[:description]} />
            <div style="font-size:12.5px;color:var(--tx-2);margin-top:7px;line-height:1.55;">
              The key is used as-is in URLs and SDK config — it can't be changed after creation.
              The default environments production · staging are created with it.
            </div>
          </.form>
          <:footer>
            <DS.btn_link variant="ghost" patch={~p"/#{@org_slug}"}>Cancel</DS.btn_link>
            <DS.btn variant="primary" icon="check" form="new-project-form" type="submit">
              Create project
            </DS.btn>
          </:footer>
        </DS.modal>

        <DS.modal
          :if={@org_form}
          id="new-org-modal"
          on_close={~p"/#{@org_slug}"}
          width={460}
          icon="building"
          title="New organization"
        >
          <.form
            for={@org_form}
            id="new-org-form"
            phx-change="validate_org"
            phx-submit="create_org"
          >
            <SC.form_label text="name" />
            <DS.ds_input field={@org_form[:name]} placeholder="Acme Inc" />
            <SC.form_label text="url key (slug)" style="margin-top:14px;" />
            <DS.ds_input field={@org_form[:slug]} mono prefix="/" placeholder="acme" />
          </.form>
          <div style="font-size:12.5px;color:var(--tx-2);margin-top:7px;line-height:1.55;">
            The URL key is the first segment of every page in this organization. You become its first
            owner; projects, members and provider keys live inside it.
          </div>
          <:footer>
            <DS.btn_link variant="ghost" patch={~p"/#{@org_slug}"}>Cancel</DS.btn_link>
            <DS.btn id="create-org" variant="primary" icon="check" form="new-org-form" type="submit">
              Create organization
            </DS.btn>
          </:footer>
        </DS.modal>
      </DS.screen>
    </Layouts.app>
    """
  end

  # The card that stands only when the organization has no BYOK key at all. A key entered here is
  # **organization-owned**, so every project in this organization shares it: the arena and AI
  # drafts run on that key.
  attr :org_slug, :string, required: true
  attr :form, :map, required: true

  defp setup_card(assigns) do
    ~H"""
    <div
      id="provider-setup-card"
      class="card2"
      style="padding:16px;margin-bottom:14px;border-color:var(--line-3);"
    >
      <div style="display:flex;align-items:center;gap:9px;margin-bottom:6px;">
        <DS.provider_mark provider={:openrouter} size={26} radius={7} />
        <span style="font-size:15px;font-weight:600;">Connect OpenRouter</span>
      </div>
      <div style="font-size:13px;color:var(--tx-2);line-height:1.55;margin-bottom:12px;">
        PromptOn needs an OpenRouter key to run the arena and draft prompts with AI. Your app's own
        production calls never use it. One key reaches every model in the catalog. The key belongs to
        this organization — every project in it shares the same key, and it is stored encrypted.
      </div>

      <.form
        for={@form}
        id="provider-setup-form"
        phx-change="validate_setup"
        phx-submit="connect_provider"
        style="display:flex;align-items:flex-end;gap:8px;flex-wrap:wrap;"
      >
        <div style="flex:1 1 260px;min-width:0;">
          <SC.form_label text="openrouter api key" />
          <DS.ds_input
            id="setup-secret"
            field={@form[:secret]}
            type="password"
            mono
            icon="lock"
            w="100%"
            placeholder="sk-or-v1-…"
            autocomplete="off"
            required
          />
        </div>
        <DS.btn id="connect-provider" variant="solid" icon="check" type="submit">
          Connect
        </DS.btn>
      </.form>

      <div id="setup-more-providers" style="font-size:12px;color:var(--tx-3);margin-top:9px;">
        More providers later.
      </div>

      <div style="display:flex;align-items:center;gap:12px;margin-top:11px;">
        <button
          id="setup-later"
          type="button"
          phx-click="dismiss_setup"
          style="background:none;border:none;padding:0;font:inherit;font-size:12.5px;color:var(--tx-2);cursor:pointer;text-decoration:underline;"
        >
          Do this later
        </button>
        <.link
          id="setup-settings-link"
          navigate={~p"/#{@org_slug}/settings?#{[tab: "providers"]}"}
          style="font-size:12.5px;color:var(--link);text-decoration:none;"
        >
          Manage provider keys
        </.link>
      </div>
    </div>
    """
  end
end
