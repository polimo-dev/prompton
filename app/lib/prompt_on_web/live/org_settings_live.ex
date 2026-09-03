defmodule PromptOnWeb.OrgSettingsLive do
  @moduledoc """
  Organization settings (`/:org_slug/settings`).

  | URL | Screen |
  |---|---|
  | `?tab=general` | rename · (team) slug change · (personal) convert to team organization |
  | `?tab=providers` | BYOK OpenRouter key |
  | `?tab=providers&add-provider=openrouter` | key registration modal |
  | `?tab=providers&rotate-provider=<id>` | key rotation modal |

  ## The provider is OpenRouter alone

  By the decision of 2026-09-01 BYOK is **OpenRouter alone** (`PromptOn.Accounts.ProviderKey`). So
  this tab has neither five provider rows nor a selection, just **one card**: when connected, the
  masked hint plus rotate/remove; otherwise the registration form (label + key). The
  `?add-provider=openrouter` URL was left as is (when providers multiply again, the name goes in
  that slot).

  ## Why provider keys live on the organization

  BYOK keys moved up from the project to the **organization** on 2026-09-01
  (`PromptOn.Accounts.ProviderKey`). There is no reason to make people register the same
  OpenRouter key again per project, and billing and members live on the organization, so the key
  does too. That is why the project Settings has no provider tab and **this screen is the one place
  to enter a key**; the use case hub's model picker and AI draft modal only give a link here when
  there is no key (the inline input inside the picker was dropped).

  ## Provisioning credentials are not here

  **Management keys were removed on 2026-09-02.** Coding AIs and the CLI now get **the user's own
  CLI session token** through `prompton login` (device authorization, `/device`), and that token's
  permissions are exactly the user's organization memberships. With no separate machine credential
  hanging off the organization, this screen has no tab for one either. A project's runtime SDK keys
  have their own screen at `/{org}/{project}/api-keys`.

  ## Personal organization

  A personal organization has no slug and lives at `/personal`. Its name can be changed, and the
  moment it gets a slug (`:claim_slug`) it becomes a team organization, so "Convert to team
  organization" is not a separate action but **the slug form itself**. A successful conversion
  changes the URL, so it does `push_navigate` to the new slug.
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Accounts
  alias PromptOnWeb.ErrorText
  alias PromptOnWeb.OrgComponents, as: OC
  alias PromptOnWeb.SettingsComponents, as: SC

  @tabs ~w(general providers)
  @tab_labels %{
    "general" => "General",
    "providers" => "Provider Keys"
  }

  # There is one BYOK provider: a constant, not a list.
  @provider :openrouter

  # Where this key is used: the only places the server calls a provider itself are the use case
  # hub's **arena** and AI drafts (and P1's experiments and judges). The app's production calls do
  # not go through PromptOn (no proxy mode, ADR 0001/0007).
  @provider_use "Arena · AI draft"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Settings · #{Layouts.org_label(socket.assigns.organization)}",
       modal: nil,
       form: nil,
       name_form: name_form(socket.assigns.organization),
       slug_form: slug_form(socket.assigns.organization),
       provider_key: nil
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    tab = tab_param(params)

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> load_tab(tab)
     |> apply_modal(tab, params)}
  end

  defp tab_param(%{"tab" => tab}) when tab in @tabs, do: tab
  defp tab_param(_params), do: hd(@tabs)

  defp tabs(org_slug) do
    Enum.map(@tabs, fn id ->
      %{id: id, label: @tab_labels[id], patch: ~p"/#{org_slug}/settings?tab=#{id}"}
    end)
  end

  defp name_form(organization), do: to_form(%{"name" => organization.name}, as: :organization)

  defp slug_form(organization),
    do: to_form(%{"slug" => organization.slug || "", "name" => organization.name}, as: :claim)

  # ---------------------------------------------------------------------------
  # Data

  defp load_tab(socket, "providers"), do: assign(socket, :provider_key, current_key(socket))
  defp load_tab(socket, _tab), do: socket

  # Even with only one registrable provider, the list is still filtered by provider once, so that
  # a DB with rows left over from when the constraint was open does not show another provider's key
  # as if it were OpenRouter's.
  defp current_key(socket) do
    socket
    |> provider_keys()
    |> Enum.find(&(&1.provider == @provider))
  end

  @doc "The organization's unrevoked provider keys (the screen survives a failure: empty list)."
  @spec provider_keys(map(), map()) :: [map()]
  def provider_keys(organization, user) do
    case Accounts.list_provider_keys(organization.id, actor: user) do
      {:ok, keys} -> keys
      {:error, _error} -> []
    end
  end

  defp provider_keys(socket),
    do: provider_keys(socket.assigns.organization, socket.assigns.current_user)

  defp settings_path(socket, tab), do: ~p"/#{socket.assigns.org_slug}/settings?tab=#{tab}"

  # ---------------------------------------------------------------------------
  # Modal (URL target)

  # With a single provider the value of `?add-provider=` no longer selects anything: if present,
  # the modal opens.
  defp apply_modal(socket, "providers", %{"add-provider" => value}) when is_binary(value) do
    assign(socket,
      modal: :add_provider,
      form: to_form(%{"secret" => "", "label" => "default"}, as: :provider_key)
    )
  end

  defp apply_modal(socket, "providers", %{"rotate-provider" => id}) when is_binary(id) do
    case find_key(socket, id) do
      nil ->
        assign(socket, modal: nil)

      key ->
        assign(socket,
          modal: {:rotate_provider, key},
          form: to_form(%{"secret" => ""}, as: :provider_key)
        )
    end
  end

  defp apply_modal(socket, _tab, _params), do: assign(socket, modal: nil)

  defp find_key(%{assigns: %{provider_key: %{id: id} = key}}, id), do: key
  defp find_key(_socket, _id), do: nil

  # ---------------------------------------------------------------------------
  # Events: form recovery (CLAUDE.md zero-downtime deployment discipline)

  @impl Phoenix.LiveView
  def handle_event("validate_name", %{"organization" => params}, socket) do
    {:noreply, assign(socket, :name_form, to_form(params, as: :organization))}
  end

  def handle_event("validate_slug", %{"claim" => params}, socket) do
    {:noreply, assign(socket, :slug_form, to_form(params, as: :claim))}
  end

  def handle_event("validate_form", params, socket) do
    {:noreply, assign(socket, :form, restore_form(socket.assigns.form, params))}
  end

  # ---------------------------------------------------------------------------
  # Events: General

  def handle_event("save_name", %{"organization" => params}, socket) do
    case Accounts.rename_organization(
           socket.assigns.organization,
           %{name: String.trim(params["name"] || "")},
           actor: socket.assigns.current_user
         ) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(organization: organization, name_form: name_form(organization))
         |> put_flash(:info, "Organization saved")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  # Getting a slug changes the URL: a personal organization becomes a team organization at that
  # moment (`/personal` → `/{slug}`), and a team organization moves address. Either way the links
  # are only right after re-entering at the new address.
  def handle_event("claim_slug", %{"claim" => params}, socket) do
    attrs = %{
      slug: String.trim(params["slug"] || ""),
      name: String.trim(params["name"] || socket.assigns.organization.name)
    }

    case Accounts.claim_organization_slug(socket.assigns.organization, attrs,
           actor: socket.assigns.current_user
         ) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> put_flash(:info, "Organization is now /#{organization.slug}")
         |> push_navigate(to: ~p"/#{organization.slug}/settings?tab=general")}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:slug_form, to_form(params, as: :claim))
         |> put_flash(:error, ErrorText.message(error))}
    end
  end

  # ---------------------------------------------------------------------------
  # Events: Provider Keys

  def handle_event("add_provider_key", %{"provider_key" => params}, socket) do
    attrs = %{
      organization_id: socket.assigns.organization.id,
      provider: @provider,
      label: blank_to_nil(params["label"]) || "default",
      secret: params["secret"] || ""
    }

    case Accounts.register_provider_key(attrs, actor: socket.assigns.current_user) do
      {:ok, _key} ->
        {:noreply,
         socket
         |> load_tab("providers")
         |> put_flash(:info, "Provider key stored (encrypted)")
         |> push_patch(to: settings_path(socket, "providers"))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  def handle_event("rotate_provider_key", %{"provider_key" => params}, socket) do
    with {:rotate_provider, key} <- socket.assigns.modal,
         {:ok, _key} <-
           Accounts.rotate_provider_key(key, %{secret: params["secret"] || ""},
             actor: socket.assigns.current_user
           ) do
      {:noreply,
       socket
       |> load_tab("providers")
       |> put_flash(:info, "Provider key rotated")
       |> push_patch(to: settings_path(socket, "providers"))}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, ErrorText.message(error))}
      _other -> {:noreply, put_flash(socket, :error, "Provider key not found.")}
    end
  end

  def handle_event("revoke_provider_key", %{"id" => id}, socket) do
    key = find_key(socket, id)

    case key && Accounts.revoke_provider_key(key, actor: socket.assigns.current_user) do
      {:ok, _key} ->
        {:noreply, socket |> load_tab("providers") |> put_flash(:info, "Provider key removed")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}

      nil ->
        {:noreply, put_flash(socket, :error, "Provider key not found.")}
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

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp provider_use, do: @provider_use

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
      nav={:org_settings}
    >
      <DS.screen
        id="org-settings-screen"
        title="Organization settings"
        sub={Layouts.org_label(@organization)}
        max_w={880}
        tabs={tabs(@org_slug)}
        active_tab={@tab}
      >
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <:actions>
          <OC.org_nav org_slug={@org_slug} active={:settings} />
        </:actions>

        <.general_tab
          :if={@tab == "general"}
          organization={@organization}
          name_form={@name_form}
          slug_form={@slug_form}
        />
        <.providers_tab
          :if={@tab == "providers"}
          org_slug={@org_slug}
          provider_key={@provider_key}
        />
        <.add_provider_modal :if={@modal == :add_provider} org_slug={@org_slug} form={@form} />
        <.rotate_provider_modal
          :if={match?({:rotate_provider, _key}, @modal)}
          org_slug={@org_slug}
          form={@form}
          provider_key={elem(@modal, 1)}
        />
      </DS.screen>
    </Layouts.app>
    """
  end

  # --- General ---------------------------------------------------------------

  attr :organization, :map, required: true
  attr :name_form, :map, required: true
  attr :slug_form, :map, required: true

  defp general_tab(assigns) do
    ~H"""
    <div id="org-settings-general">
      <SC.setting_card
        id="org-general-card"
        title="General"
        desc="An organization owns projects, members, and the LLM provider keys they share."
      >
        <form id="org-name-form" phx-submit="save_name" phx-change="validate_name">
          <div class="mono-label" style="margin-bottom:7px;">name</div>
          <DS.ds_input id="org-name" field={@name_form[:name]} />
        </form>
        <div style="display:flex;align-items:center;gap:7px;margin-top:12px;">
          <DSIcons.icon name="building" size={13} class="tx3" />
          <span style="font-size:12.5px;color:var(--tx-2);">
            {kind_label(@organization)} · <span class="font-mono">{address(@organization)}</span>
          </span>
        </div>
        <:footer>
          <DS.btn id="save-org-name" variant="primary" form="org-name-form" type="submit">
            Save
          </DS.btn>
        </:footer>
      </SC.setting_card>

      <SC.setting_card
        id="org-slug-card"
        title={if @organization.personal?, do: "Convert to team organization", else: "URL"}
        desc={slug_desc(@organization)}
      >
        <form id="org-slug-form" phx-submit="claim_slug" phx-change="validate_slug">
          <div class="mono-label" style="margin-bottom:7px;">url key (slug)</div>
          <DS.ds_input id="org-slug" field={@slug_form[:slug]} mono prefix="/" placeholder="acme" />
          <div :if={@organization.personal?} class="mono-label" style="margin:14px 0 7px;">name</div>
          <DS.ds_input :if={@organization.personal?} id="org-slug-name" field={@slug_form[:name]} />
        </form>
        <:footer>
          <span style="font-size:12.5px;color:var(--tx-2);margin-right:auto;line-height:1.5;">
            Lowercase letters, digits and dashes. It becomes the first segment of every URL in this organization.
          </span>
          <DS.btn id="save-org-slug" variant="solid" form="org-slug-form" type="submit">
            {if @organization.personal?, do: "Convert", else: "Save"}
          </DS.btn>
        </:footer>
      </SC.setting_card>
    </div>
    """
  end

  defp kind_label(%{personal?: true}), do: "Personal organization"
  defp kind_label(_organization), do: "Team organization"

  defp address(%{personal?: true}), do: "/personal"
  defp address(%{slug: slug}) when is_binary(slug), do: "/#{slug}"
  defp address(_organization), do: "—"

  defp slug_desc(%{personal?: true}),
    do:
      "A personal organization lives at /personal and has no URL key. Claiming one turns it into a team organization — the projects, keys and members it already has come along."

  defp slug_desc(_organization),
    do:
      "Changing the URL key moves every page in this organization. Links people already have stop working."

  # --- Provider Keys ---------------------------------------------------------

  attr :org_slug, :string, required: true
  attr :provider_key, :map, default: nil

  defp providers_tab(assigns) do
    ~H"""
    <div id="org-settings-providers">
      <SC.setting_card
        id="provider-keys-card"
        title="OpenRouter"
        desc="The credential the PromptOn server uses for arena runs and AI drafts. Shared by every project in this organization, and stored encrypted."
      >
        <SC.row_box id="provider-row-openrouter" pad="10px 11px">
          <DS.provider_mark provider={:openrouter} size={24} radius={6} />
          <div style="min-width:0;">
            <div class="font-mono" style="font-size:13.5px;font-weight:500;">openrouter</div>
            <div
              class="font-mono"
              style={"font-size:12px;color:#{if @provider_key, do: "var(--tx-2)", else: "var(--tx-3)"};"}
            >
              {OC.masked(@provider_key)}
            </div>
          </div>
          <span style="margin-left:auto;font-size:12px;color:var(--tx-3);white-space:nowrap;">
            {provider_use()}
          </span>
          <span
            :if={@provider_key}
            style="display:inline-flex;align-items:center;gap:6px;font-size:13px;color:var(--ok);"
          >
            <DS.status_dot kind={:ok} /> connected
          </span>
          <span
            :if={is_nil(@provider_key)}
            style="display:inline-flex;align-items:center;gap:6px;font-size:13px;color:var(--tx-2);"
          >
            <DS.status_dot kind={:idle} /> none
          </span>
          <DS.icon_btn
            :if={@provider_key}
            id="rotate-provider-openrouter"
            name="rerun"
            size={24}
            title="Rotate"
            patch={~p"/#{@org_slug}/settings?tab=providers&rotate-provider=#{@provider_key.id}"}
          />
          <DS.icon_btn
            :if={@provider_key}
            id="remove-provider-openrouter"
            name="trash"
            size={24}
            title="Remove"
            phx-click="revoke_provider_key"
            phx-value-id={@provider_key.id}
            data-confirm="Remove this provider key?"
          />
        </SC.row_box>
        <:footer>
          <DS.btn_link
            :if={is_nil(@provider_key)}
            id="add-provider-openrouter"
            variant="primary"
            icon="plus"
            style="margin-left:auto;"
            patch={~p"/#{@org_slug}/settings?tab=providers&add-provider=openrouter"}
          >
            Connect OpenRouter
          </DS.btn_link>
        </:footer>
      </SC.setting_card>

      <SC.info_box
        id="provider-keys-note"
        icon="shield"
        icon_size={15}
        font_size={11.5}
        line_height={1.6}
        pad="11px 13px"
        radius="var(--r)"
      >
        PromptOn is never in your request path — your app makes production calls with its own keys.
        This key is only for the calls the PromptOn server makes itself: arena runs and AI drafts, for
        any project in this organization. OpenRouter reaches every model in the catalog, so one key is
        enough. More providers later. Models are registered from the model picker inside a use case.
      </SC.info_box>
    </div>
    """
  end

  # --- Modals ----------------------------------------------------------------

  attr :org_slug, :string, required: true
  attr :form, :map, required: true

  defp add_provider_modal(assigns) do
    ~H"""
    <DS.modal
      id="add-provider-modal"
      on_close={~p"/#{@org_slug}/settings?tab=providers"}
      width={460}
      icon="key"
      title="Connect OpenRouter"
    >
      <div style="display:flex;align-items:center;gap:9px;margin-bottom:14px;">
        <DS.provider_mark provider={:openrouter} size={22} radius={6} />
        <span style="font-size:12.5px;color:var(--tx-2);line-height:1.55;">
          OpenRouter routes to every model in the catalog, so this one key covers them all.
        </span>
      </div>

      <.form
        for={@form}
        id="add-provider-form"
        phx-submit="add_provider_key"
        phx-change="validate_form"
      >
        <OC.provider_secret_fields form={@form} />
      </.form>

      <div style="display:flex;align-items:center;gap:6px;margin-top:10px;font-size:12.5px;color:var(--tx-2);">
        <DSIcons.icon name="lock" size={12} /> Stored encrypted with ash_cloak AES-256-GCM.
      </div>

      <:footer>
        <DS.btn_link variant="ghost" patch={~p"/#{@org_slug}/settings?tab=providers"}>
          Cancel
        </DS.btn_link>
        <DS.btn
          id="confirm-add-provider"
          variant="primary"
          icon="check"
          form="add-provider-form"
          type="submit"
        >
          Add key
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end

  attr :org_slug, :string, required: true
  attr :form, :map, required: true
  attr :provider_key, :map, required: true

  defp rotate_provider_modal(assigns) do
    ~H"""
    <DS.modal
      id="rotate-provider-modal"
      on_close={~p"/#{@org_slug}/settings?tab=providers"}
      width={460}
      icon="rerun"
      title={"Rotate #{@provider_key.provider} key"}
    >
      <div style="font-size:12.5px;color:var(--tx-2);line-height:1.55;margin-bottom:12px;">
        The current key is
        <span class="font-mono" style="color:var(--tx-1);">{OC.masked(@provider_key)}</span>
        — rotating replaces it in place, so running calls pick up the new key immediately.
      </div>

      <.form
        for={@form}
        id="rotate-provider-form"
        phx-submit="rotate_provider_key"
        phx-change="validate_form"
      >
        <OC.provider_secret_fields form={@form} label?={false} />
      </.form>

      <:footer>
        <DS.btn_link variant="ghost" patch={~p"/#{@org_slug}/settings?tab=providers"}>
          Cancel
        </DS.btn_link>
        <DS.btn
          id="confirm-rotate-provider"
          variant="primary"
          icon="check"
          form="rotate-provider-form"
          type="submit"
        >
          Rotate key
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end
end
