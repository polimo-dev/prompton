defmodule PromptOnWeb.Layouts do
  @moduledoc """
  Root layout + app shell (sidebar) + toasts.

  The app is **dark-only**, so there is no Phoenix default theme toggle — `root.html.heex` pins
  `data-theme="promptdark"`. The sidebar is a 236px panel that takes the structure of
  `design/mockup/app/sidebar.jsx` dressed in `design/DESIGN-resend.md` (the canonical source; the
  docs layout of `design/resend-brief.md` §Logged-in app), and `#sidebar-toggle` collapses it down
  to a 60px icon rail. The body sits inside `.app-panel` — a rounded 16px hairline panel on the
  black canvas.

  ## The sidebar draws the hierarchy as it is — organization → project → account

  Three layers stand top to bottom (2026-09-01 reorganization):

  1. **Top = the current organization** (`#org-menu`). This is where the brand block (the PromptOn
     logo) used to be — the tab title already says the app's name, and what belongs in that spot is
     "which organization am I looking at". Clicking it opens the organization menu: Projects ·
     Members · Usage · Organization settings, plus the **switch organization** list of the
     organizations the user belongs to (personal organization first) + New organization.
     The collapse toggle (`#sidebar-toggle`) is the small icon at the right end of this row (in the
     rail it drops below the mark).
  2. **Middle = the project**. The project switcher + that project's four screens (`nav_items/0`).
  3. **Bottom = the account** (`#user-menu`). A click-to-open popup holds Account settings · Sign
     out.

  The three popups share one pattern — `<details>` + an absolutely positioned `.fadeup` menu. In the
  collapsed rail, CSS pulls the menu out of the rail at a fixed width
  (`html.sidebar-collapsed .dsswitch > .fadeup` in `app.css`).

  ## Sidebar collapse state is not URL state

  ADR 0005's "LiveView state goes in the URL" discipline is for **shareable screen state** (tabs,
  selection, filters). Sidebar collapse is the opposite: a **per-device chrome preference** that
  neither the server nor the URL knows about — there is no reason to collapse the sidebar of whoever
  receives a link, and it is not a "screen" to restore on remount. So it is handled not as a
  LiveView assign but with a colocated hook + `localStorage["pon:sidebar"]`, and a single
  `.sidebar-collapsed` class on `<html>` lets CSS draw both layouts (the class has to live on
  `<html>` so LiveView patches and navigation do not wipe it, and so the inline script in
  `root.html.heex` can restore it before first paint).

  Screens are assembled like this:

      <Layouts.app flash={@flash} current_user={@current_user} org_slug={@org_slug}
                   project={@project} projects={@projects} organization={@organization}
                   organizations={@organizations} nav={:usecases}>
        <DS.screen title="Use Cases">…</DS.screen>
      </Layouts.app>
  """
  use PromptOnWeb, :html

  alias PromptOnWeb.DS
  alias PromptOnWeb.DSIcons

  embed_templates "layouts/*"

  # Project nav — the four screens a project actually has. Playground, Deployments, and Models are
  # not menu items but sections/tabs inside the use case hub (`/use-cases/:key/prompt`). `path: ""`
  # is the project root.
  @nav_items [
    %{id: :overview, label: "Overview", icon: "gauge", path: ""},
    %{id: :usecases, label: "Use cases", icon: "target", path: "/use-cases"},
    %{id: :apikeys, label: "API keys", icon: "key", path: "/api-keys"},
    %{id: :settings, label: "Settings", icon: "settings", path: "/settings"}
  ]

  # Organization menu (`#org-menu`) items — the four organization-level screens. The organization
  # home has no suffix. `id` is the DOM id (`#org-<id>`); `nav` is the `nav` value used for the
  # active marker (the two differ — the organization settings nav value is `:org_settings` to keep
  # it apart from project settings, but its DOM id is `#org-settings`).
  @org_items [
    %{id: "projects", nav: :projects, label: "Projects", icon: "layers", path: ""},
    %{id: "members", nav: :members, label: "Members", icon: "user", path: "/members"},
    %{id: "usage", nav: :usage, label: "Usage", icon: "activity", path: "/usage"},
    %{
      id: "settings",
      nav: :org_settings,
      label: "Organization settings",
      icon: "settings",
      path: "/settings"
    }
  ]

  @doc """
  App shell — a 236px sidebar + body. The body slot usually holds a single `DS.screen/1`.

  `nav` is the active sidebar item (shared by the organization menu and the project nav).
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil

  attr :org_slug, :string,
    required: true,
    doc:
      "the **raw path segment** of the current organization (`\"personal\"` or a team slug) — every link uses it"

  attr :project, :map, default: nil, doc: "the current project (nil on the organization home)"

  attr :projects, :list,
    default: [],
    doc: "project switcher list (the current organization's only)"

  attr :organization, :map, default: nil

  attr :organizations, :list,
    default: [],
    doc: "switch-organization list (every organization the user is a member of, personal first)"

  attr :nav, :atom,
    default: nil,
    values: [
      nil,
      :projects,
      :overview,
      :usecases,
      :apikeys,
      :settings,
      :org_settings,
      :members,
      :usage,
      :account
    ]

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="app-shell">
      <.sidebar
        org_slug={@org_slug}
        project={@project}
        projects={@projects}
        organization={@organization}
        organizations={@organizations}
        current_user={@current_user}
        nav={@nav}
      />
      <main class="app-main">
        <div class="app-panel">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :org_slug, :string, required: true
  attr :project, :map, default: nil
  attr :projects, :list, default: []
  attr :organization, :map, default: nil
  attr :organizations, :list, default: []
  attr :current_user, :map, default: nil
  attr :nav, :atom, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside id="sidebar" class="panel hair-r sidebar">
      <div class="sidebar-org">
        <.org_menu
          org_slug={@org_slug}
          organization={@organization}
          organizations={@organizations}
          nav={@nav}
        />
        <button
          id="sidebar-toggle"
          type="button"
          class="sidebar-toggle tr"
          phx-hook=".SidebarToggle"
          aria-controls="sidebar"
          aria-expanded="true"
          aria-label="Collapse sidebar"
          title="Collapse sidebar"
        >
          <DSIcons.icon name="chevRight" size={15} class="sidebar-toggle-icon" />
        </button>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarToggle">
          // Sidebar collapse is a per-device chrome preference the server knows nothing about — it
          // runs on the <html> class + localStorage alone. The hook re-applies the stored value on
          // every mount (state survives a remount caused by LiveView navigation).
          const KEY = "pon:sidebar"

          export default {
            mounted() {
              this.onClick = () => this.apply(!collapsed(), true)
              this.el.addEventListener("click", this.onClick)
              this.apply(stored() === "collapsed", false)
            },
            updated() { this.apply(collapsed(), false) },
            destroyed() { this.el.removeEventListener("click", this.onClick) },
            apply(next, persist) {
              document.documentElement.classList.toggle("sidebar-collapsed", next)
              const label = next ? "Expand sidebar" : "Collapse sidebar"
              this.el.setAttribute("title", label)
              this.el.setAttribute("aria-label", label)
              this.el.setAttribute("aria-expanded", next ? "false" : "true")
              if (persist) { store(next ? "collapsed" : "expanded") }
            }
          }

          function collapsed() {
            return document.documentElement.classList.contains("sidebar-collapsed")
          }

          // localStorage can throw in private mode or when blocked — on failure, just leave the
          // sidebar expanded.
          function stored() {
            try { return window.localStorage.getItem(KEY) } catch (_e) { return null }
          }

          function store(value) {
            try { window.localStorage.setItem(KEY, value) } catch (_e) { /* ignore */ }
          }
        </script>
      </div>

      <nav class="sidebar-nav">
        <div class="sidebar-switch" style="padding:2px 2px 5px;">
          <.project_switcher org_slug={@org_slug} project={@project} projects={@projects} />
        </div>

        <div :if={@project} class="sidebar-subnav">
          <.nav_item
            :for={n <- nav_items()}
            id={"nav-#{n.id}"}
            label={n.label}
            icon={n.icon}
            navigate={project_path(@org_slug, @project, n.path)}
            active={@nav == n.id}
          />
        </div>
      </nav>

      <details id="user-menu" class="dsplain hair-t sidebar-user" style="position:relative;">
        <summary title={user_email(@current_user)}>
          <span style="width:30px;height:30px;border-radius:var(--r);background:var(--bg-3);border:1px solid var(--line-2);display:flex;align-items:center;justify-content:center;font-size:12.5px;font-weight:500;color:var(--tx-0);flex-shrink:0;">
            {initials(@current_user)}
          </span>
          <span class="sidebar-label" style="min-width:0;flex:1;">
            <span
              id="current-user"
              style="display:block;font-size:13.5px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;"
            >
              {user_email(@current_user)}
            </span>
            <span class="mono-label" style="display:block;font-size:10px;padding:0;">Account</span>
          </span>
          <span class="dsiconbtn sidebar-full" style="width:28px;height:28px;">
            <DSIcons.icon name="chevUpDown" size={15.5} />
          </span>
        </summary>
        <div
          class="fadeup dsmenu"
          style="position:absolute;bottom:calc(100% + 2px);left:10px;right:10px;z-index:31;"
        >
          <.link
            id="account-settings"
            navigate={~p"/account"}
            class={["dsmenu-item", @nav == :account && "is-current"]}
            style="color:var(--tx-1);"
          >
            <DSIcons.icon name="user" size={13} />
            <span style="font-size:14px;">Account settings</span>
          </.link>
          <.link id="sign-out" href={~p"/sign-out"} class="dsmenu-item" style="color:var(--tx-1);">
            <DSIcons.icon name="arrowRight" size={13} />
            <span style="font-size:14px;">Sign out</span>
          </.link>
          <div style="height:1px;background:var(--line);margin:5px 0;" />
          <div id="app-version" class="mono-label" style="padding:3px 8px 2px;">
            {app_version()}
          </div>
        </div>
      </details>
    </aside>
    """
  end

  attr :org_slug, :string, required: true
  attr :organization, :map, default: nil
  attr :organizations, :list, default: []
  attr :nav, :atom, default: nil

  defp org_menu(assigns) do
    ~H"""
    <details id="org-menu" class="dsswitch" style="position:relative;flex:1;min-width:0;">
      <summary title={org_label(@organization)}>
        <.org_mark organization={@organization} />
        <span
          class="sidebar-label"
          style="display:flex;flex-direction:column;align-items:flex-start;min-width:0;flex:1;"
        >
          <span
            id="current-org"
            style="font-size:13.5px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:132px;"
          >
            {org_label(@organization)}
          </span>
          <span class="mono-label" style="font-size:10px;padding:0;">Organization</span>
        </span>
        <DSIcons.icon name="chevUpDown" size={13} class="tx2 sidebar-full" />
      </summary>
      <div
        class="fadeup dsmenu"
        style="position:absolute;top:calc(100% + 6px);left:0;right:0;z-index:32;"
      >
        <.link
          :for={item <- org_items()}
          id={"org-#{item.id}"}
          navigate={"/#{@org_slug}#{item.path}"}
          class={["dsmenu-item", @nav == item.nav && "is-current"]}
        >
          <DSIcons.icon name={item.icon} size={13} class="tx2" />
          <span style="font-size:14px;flex:1;text-align:left;">{item.label}</span>
        </.link>

        <div style="height:1px;background:var(--line);margin:5px 0;" />
        <div class="mono-label" style="padding:5px 8px 4px;">Switch organization</div>
        <.link
          :for={org <- @organizations}
          id={"switch-org-#{org_segment(org)}"}
          navigate={"/#{org_segment(org)}"}
          class={["dsmenu-item", current_org?(org, @organization) && "is-current"]}
        >
          <.org_mark organization={org} size={18} />
          <span style="font-size:13.5px;flex:1;text-align:left;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
            {org_label(org)}
          </span>
          <DSIcons.icon
            :if={current_org?(org, @organization)}
            name="check"
            size={13}
            class="tx1"
          />
        </.link>

        <div style="height:1px;background:var(--line);margin:5px 0;" />
        <.link
          id="new-organization"
          navigate={~p"/#{@org_slug}?#{[new_org: "1"]}"}
          class="dsmenu-item"
          style="color:var(--tx-1);"
        >
          <DSIcons.icon name="plus" size={13} />
          <span style="font-size:14px;">New organization</span>
        </.link>
      </div>
    </details>
    """
  end

  attr :organization, :map, default: nil
  attr :size, :integer, default: 24

  defp org_mark(assigns) do
    ~H"""
    <span style={
      DS.style_list([
        "width:#{@size}px;height:#{@size}px;border-radius:var(--r-sm);flex-shrink:0;",
        "display:flex;align-items:center;justify-content:center;",
        "background:var(--accent-soft);border:1px solid var(--accent-line);color:var(--accent);"
      ])
    }>
      <DSIcons.icon name={org_icon(@organization)} size={round(@size * 0.6)} />
    </span>
    """
  end

  defp org_icon(%{personal?: true}), do: "user"
  defp org_icon(_organization), do: "building"

  defp current_org?(%{id: id}, %{id: current_id}), do: id == current_id
  defp current_org?(_org, _current), do: false

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :navigate, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class={["navitem tr", @active && "active"]}
      aria-current={@active && "page"}
      title={@label}
    >
      <DSIcons.icon name={@icon} size={15.5} stroke={if @active, do: 2, else: 1.8} />
      <span
        class="sidebar-label"
        style={"font-weight:#{if @active, do: 500, else: 400};white-space:nowrap;"}
      >
        {@label}
      </span>
    </.link>
    """
  end

  attr :org_slug, :string, required: true
  attr :project, :map, default: nil
  attr :projects, :list, default: []

  defp project_switcher(assigns) do
    ~H"""
    <details id="project-switcher" class="dsswitch" style="position:relative;">
      <summary title={(@project && @project.slug) || "no project"}>
        <span style={[
          "width:22px;height:22px;border-radius:var(--r-sm);display:flex;align-items:center;justify-content:center;flex-shrink:0;",
          "background:#{project_color(@project)}22;border:1px solid #{project_color(@project)}66;"
        ]}>
          <span style={"width:8px;height:8px;border-radius:var(--r-pill);background:#{project_color(@project)};"} />
        </span>
        <span
          class="sidebar-label"
          style="display:flex;flex-direction:column;align-items:flex-start;min-width:0;flex:1;"
        >
          <span
            class="font-mono"
            style="font-size:13.5px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:140px;"
          >
            {(@project && @project.slug) || "no project"}
          </span>
          <span class="mono-label" style="font-size:10px;padding:0;">Project</span>
        </span>
        <DSIcons.icon name="chevUpDown" size={13} class="tx2 sidebar-full" />
      </summary>
      <div
        class="fadeup dsmenu"
        style="position:absolute;top:calc(100% + 6px);left:0;right:0;z-index:31;"
      >
        <div class="mono-label" style="padding:5px 8px 4px;">Switch project</div>
        <.link
          :for={p <- @projects}
          id={"switch-to-#{p.slug}"}
          navigate={~p"/#{@org_slug}/#{p.slug}/use-cases"}
          class={["dsmenu-item", @project && p.id == @project.id && "is-current"]}
        >
          <span style={"width:8px;height:8px;border-radius:var(--r-pill);background:#{project_color(p)};flex-shrink:0;"} />
          <span class="font-mono" style="font-size:13.5px;flex:1;text-align:left;">{p.slug}</span>
          <span
            :if={use_case_count(p)}
            class="font-mono"
            style="font-size:11px;color:var(--tx-3);"
          >
            {use_case_count(p)} uc
          </span>
          <DSIcons.icon
            :if={@project && p.id == @project.id}
            name="check"
            size={13}
            class="tx1"
          />
        </.link>
        <div style="height:1px;background:var(--line);margin:5px 0;" />
        <.link
          id="new-project"
          navigate={~p"/#{@org_slug}?new=1"}
          class="dsmenu-item"
          style="color:var(--tx-1);"
        >
          <DSIcons.icon name="plus" size={13} />
          <span style="font-size:14px;">New project</span>
        </.link>
      </div>
    </details>
    """
  end

  @doc "Sidebar project nav item definitions (`nav` value → label/icon/path)."
  def nav_items, do: @nav_items

  @doc "Organization menu item definitions (`nav` value → label/icon/suffix after `/{org}`)."
  def org_items, do: @org_items

  # `org_slug` is the raw path segment — when viewing the personal organization it carries
  # `"personal"` as-is.
  defp project_path(org_slug, project, suffix), do: "/#{org_slug}/#{project.slug}#{suffix}"

  @doc """
  The organization's **path segment** — a personal organization has no slug, so it is the reserved
  segment `personal`. The links in the switch-organization list are built from this.

      iex> PromptOnWeb.Layouts.org_segment(%{personal?: true, slug: nil})
      "personal"

      iex> PromptOnWeb.Layouts.org_segment(%{personal?: false, slug: "acme"})
      "acme"
  """
  @spec org_segment(map()) :: String.t()
  def org_segment(%{personal?: true}), do: "personal"
  def org_segment(%{slug: slug}) when is_binary(slug), do: slug
  def org_segment(_organization), do: "personal"

  @doc """
  The organization name shown on screen. A personal organization's `name` is
  `"<email>'s organization"`, which disagrees with the URL (`/personal`), so on screen it is called
  `Personal`. Decided in this one place so that the sidebar, crumbs, and screen titles **use the
  same word**.

      iex> PromptOnWeb.Layouts.org_label(%{personal?: true, name: "a@b.c's organization"})
      "Personal"

      iex> PromptOnWeb.Layouts.org_label(%{personal?: false, name: "Acme Inc"})
      "Acme Inc"

      iex> PromptOnWeb.Layouts.org_label(nil)
      "—"
  """
  @spec org_label(map() | nil) :: String.t()
  def org_label(nil), do: "—"
  def org_label(%{personal?: true}), do: "Personal"
  def org_label(%{name: name}), do: name

  # The design system picks the color — the sidebar tile and the Projects card must give **the same
  # project the same color**.
  defp project_color(nil), do: "#888e90"
  defp project_color(project), do: DS.project_color(project.slug)

  # A switcher row in the mockup's sidebar.jsx is `color dot · key · {n} uc · check`. The count is
  # tallied in one go by `LiveProjectScope` when it reads the list and attached as metadata — if it
  # could not be counted the cell is left empty (the row is still drawn).
  defp use_case_count(project) do
    case Ash.Resource.get_metadata(project, :use_case_count) do
      count when is_integer(count) -> count
      _other -> nil
    end
  end

  defp app_version, do: "v#{Application.spec(:prompton, :vsn)}"

  defp initials(nil), do: "?"

  defp initials(user) do
    user
    |> email_local()
    |> String.split(~r/[._\-+]/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.upcase(String.first(&1) || ""))
    |> case do
      "" -> "?"
      value -> value
    end
  end

  defp user_email(nil), do: "—"
  defp user_email(user), do: to_string(user.email)

  defp email_local(user) do
    user.email |> to_string() |> String.split("@") |> List.first() |> Kernel.||("")
  end

  # ---------------------------------------------------------------------------
  # Toasts (mockup ui.jsx ToastProvider) — uses LiveView flash as-is.

  @doc """
  Flash toast group. Shows the mockup toast at the bottom center of the screen and dismisses it
  automatically after ~2.4s (a colocated hook clicks the element, which fires `lv:clear-flash`).
  Plain `put_flash(:info | :error, …)` works as-is.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      style="position:fixed;bottom:20px;left:50%;transform:translateX(-50%);z-index:999;display:flex;flex-direction:column;gap:8px;align-items:center;"
    >
      <.toast kind={:info} flash={@flash} icon="check" />
      <.toast kind={:error} flash={@flash} icon="alert" />

      <div
        id="client-error"
        class="dstoast"
        style="display:none;"
        phx-disconnected={JS.show(to: "#client-error", display: "flex")}
        phx-connected={JS.hide(to: "#client-error")}
      >
        <span style="color:var(--warn);display:inline-flex;">
          <DSIcons.icon name="alert" size={15} />
        </span>
        {gettext("Attempting to reconnect")}
      </div>

      <div
        id="server-error"
        class="dstoast"
        style="display:none;"
        phx-disconnected={JS.show(to: "#server-error", display: "flex")}
        phx-connected={JS.hide(to: "#server-error")}
      >
        <span style="color:var(--err);display:inline-flex;">
          <DSIcons.icon name="alert" size={15} />
        </span>
        {gettext("Something went wrong! Attempting to reconnect")}
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoDismissFlash">
      export default {
        mounted() {
          const delay = parseInt(this.el.dataset.delay || "2400", 10)
          this.timer = setTimeout(() => this.el.click(), delay)
        },
        destroyed() { clearTimeout(this.timer) }
      }
    </script>
    """
  end

  attr :kind, :atom, required: true, values: [:info, :error]
  attr :flash, :map, required: true
  attr :icon, :string, required: true

  defp toast(assigns) do
    assigns = assign(assigns, :message, Phoenix.Flash.get(assigns.flash, assigns.kind))

    ~H"""
    <div
      :if={@message}
      id={"flash-#{@kind}"}
      class="dstoast fadeup"
      role="alert"
      phx-hook=".AutoDismissFlash"
      data-delay="2400"
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide()}
    >
      <span style={"color:#{if @kind == :error, do: "var(--err)", else: "var(--ok)"};display:inline-flex;"}>
        <DSIcons.icon name={@icon} size={15} />
      </span>
      {@message}
    </div>
    """
  end
end
