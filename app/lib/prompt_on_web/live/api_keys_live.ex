defmodule PromptOnWeb.ApiKeysLive do
  @moduledoc """
  PromptOn SDK keys (`/:org_slug/:project_slug/api-keys`).

  Keys are **project-owned**, and remain so after provider keys (BYOK) moved up to the organization
  (`PromptOn.Projects.ApiKey`: outside the tenant, but it carries a `project_id` and becomes the
  public API's actor). On 2026-09-01 what had been a tab of the project Settings came out as **its
  own screen**, when the sidebar project nav became the four items Overview · Use cases · API keys ·
  Settings.

  **Keys are not bound to an environment** (same day, ADR 0007 revision): one key reads every
  environment of this project, and the request picks the environment with a parameter
  (`environment`, default `production`). So the issue modal has no environment field, only a name.

  The target of the open modal travels in the URL as a query parameter (CLAUDE.md zero-downtime
  deployment discipline):

  | URL | Screen |
  |---|---|
  | (none) | list of issued keys + SDK setup |
  | `?issue=1` | key issue modal |

  **SDK keys are shown only up to the prefix.** Only a hash of the raw key is stored, so the raw key
  is shown once right after issuing, and after that it is `key_prefix` + a mask.
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Projects
  alias PromptOnWeb.ErrorText
  alias PromptOnWeb.SettingsComponents, as: SC

  @scopes [:read, :logs]
  @bundle_path "priv/prompton/use-cases.production.json"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "API keys · #{socket.assigns.project.slug}",
       scopes: @scopes,
       modal: nil,
       form: nil,
       issued_key: nil
     )
     |> load_keys()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, apply_modal(socket, params)}
  end

  # ---------------------------------------------------------------------------
  # Data

  defp load_keys(socket) do
    project = socket.assigns.project

    keys =
      case Projects.list_api_keys(project.id, actor: socket.assigns.current_user) do
        {:ok, keys} ->
          keys |> Enum.filter(&is_nil(&1.revoked_at)) |> Enum.sort_by(& &1.inserted_at)

        {:error, _error} ->
          []
      end

    assign(socket, :api_keys, keys)
  end

  # ---------------------------------------------------------------------------
  # Modal (URL target)

  defp apply_modal(socket, %{"issue" => "1"}) do
    socket |> assign(:form, issue_form(socket)) |> assign(:modal, :issue)
  end

  defp apply_modal(socket, _params), do: assign(socket, modal: nil, issued_key: nil)

  # Do not rebuild the form when it is already open; rebuilding resets the checks and the input.
  defp issue_form(%{assigns: %{modal: :issue, form: %Phoenix.HTML.Form{name: "api_key"} = form}}),
    do: form

  defp issue_form(_socket),
    do: to_form(%{"name" => "", "scopes" => Enum.map(@scopes, &to_string/1)}, as: :api_key)

  # ---------------------------------------------------------------------------
  # Events

  # The modal target is in the URL, but **the input values** are revived by Phoenix form recovery.
  # Recovery only replays forms that carry `phx-change`, so every form on the screen must have this
  # handler attached.
  @impl Phoenix.LiveView
  def handle_event("validate_form", params, socket) do
    {:noreply, assign(socket, :form, restore_form(socket.assigns.form, params))}
  end

  def handle_event("issue_key", %{"api_key" => params}, socket) do
    project = socket.assigns.project

    attrs = %{
      project_id: project.id,
      name: key_name(params["name"]),
      scopes: parse_scopes(params["scopes"])
    }

    case Projects.issue_api_key(attrs, actor: socket.assigns.current_user) do
      {:ok, key} ->
        {:noreply,
         socket
         |> load_keys()
         |> assign(:issued_key, Ash.Resource.get_metadata(key, :raw_key))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  def handle_event("revoke_key", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.api_keys, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Key not found.")}

      key ->
        case Projects.revoke_api_key(key, actor: socket.assigns.current_user) do
          {:ok, _key} ->
            {:noreply, socket |> load_keys() |> put_flash(:info, "Key revoked")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, ErrorText.message(error))}
        end
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

  # The name is only a human-readable label (the raw key is shown once). When blank it is simply
  # "SDK key".
  defp key_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> "SDK key"
      trimmed -> trimmed
    end
  end

  defp key_name(_name), do: "SDK key"

  defp parse_scopes(values) do
    values
    |> List.wrap()
    |> Enum.map(fn value -> Enum.find(@scopes, &(to_string(&1) == to_string(value))) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "SDK config code block, filled with this project's real values."
  @spec sdk_config(String.t()) :: String.t()
  def sdk_config(base_url) do
    """
    config :prompton_sdk,
      base_url: "#{base_url}",
      api_key: System.fetch_env!("PTN_API_KEY"),
      bundle: "#{@bundle_path}",
      poll_interval: :timer.seconds(30)\
    """
  end

  @doc "SDK snapshot fallback chain: remote → disk → repo bundle."
  @spec fallback_chain() :: [{String.t(), String.t()}]
  def fallback_chain do
    [
      {"remote", "ETag polling every 30s"},
      {"disk", "Disk cache fallback"},
      {"bundle", "Repo bundle fallback"}
    ]
  end

  # ---------------------------------------------------------------------------
  # Render

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :sdk_config, sdk_config(PromptOnWeb.Endpoint.url()))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      org_slug={@org_slug}
      project={@project}
      projects={@projects}
      organization={@organization}
      organizations={@organizations}
      nav={:apikeys}
    >
      <DS.screen id="api-keys-screen" title="API keys" sub={@project.name} max_w={880}>
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <:crumb label={@project.slug} navigate={~p"/#{@org_slug}/#{@project.slug}"} />

        <div id="api-keys-body">
          <SC.setting_card
            id="sdk-keys-card"
            title="SDK keys"
            desc="One key covers the whole project — the request picks the environment (parameter environment, default production). Scopes split config fetching (read) from monitoring logs (logs)."
          >
            <div :if={@api_keys == []} style="font-size:13px;color:var(--tx-2);">
              No keys issued yet.
            </div>
            <div :if={@api_keys != []} style="display:flex;flex-direction:column;gap:6px;">
              <SC.row_box :for={key <- @api_keys} id={"key-row-#{key.id}"} pad="10px 11px">
                <DSIcons.icon name="key" size={14} class="tx2" />
                <span class="font-mono" style="font-size:13px;color:var(--tx-0);">
                  {key.key_prefix}<span style="color:var(--tx-3);">••••••••</span>
                </span>
                <span style="font-size:12.5px;color:var(--tx-2);min-width:0;overflow:hidden;text-overflow:ellipsis;">
                  {key.name}
                </span>
                <span style="display:flex;gap:3px;">
                  <DS.badge :for={scope <- key.scopes} tone={:accent} mono style="font-size:10px;">
                    {scope}
                  </DS.badge>
                </span>
                <span style="margin-left:auto;font-size:12px;color:var(--tx-3);white-space:nowrap;">
                  used {SC.relative_time(key.last_used_at)}
                </span>
                <SC.copy_button id={"copy-key-#{key.id}"} text={key.key_prefix} title="Copy prefix" />
                <DS.icon_btn
                  id={"revoke-key-#{key.id}"}
                  name="trash"
                  size={24}
                  title="Revoke"
                  phx-click="revoke_key"
                  phx-value-id={key.id}
                  data-confirm="Revoke this key? This cannot be undone."
                />
              </SC.row_box>
            </div>
            <:footer>
              <DS.btn_link
                id="issue-key"
                variant="primary"
                icon="plus"
                style="margin-left:auto;"
                patch={~p"/#{@org_slug}/#{@project.slug}/api-keys?#{[issue: "1"]}"}
              >
                Issue key
              </DS.btn_link>
            </:footer>
          </SC.setting_card>

          <SC.setting_card
            id="sdk-setup-card"
            title="SDK setup"
            desc="Your app pulls the deployed use-case document and selects prompts locally, then calls your provider itself — PromptOn is never in the request path. If PromptOn goes down, the app keeps running on its last document."
          >
            <div
              id="sdk-config"
              class="card2"
              style="padding:12px;background:var(--bg-1);overflow-x:auto;"
            >
              <DS.code_block text={@sdk_config} wrap={false} />
            </div>
            <div style="display:flex;gap:14px;margin-top:12px;flex-wrap:wrap;">
              <%= for {{stage, note}, index} <- Enum.with_index(fallback_chain()) do %>
                <div style="display:flex;align-items:center;gap:7px;">
                  <DSIcons.icon :if={index > 0} name="arrowRight" size={12} class="tx3" />
                  <DS.badge tone={if index == 0, do: :ok, else: :neutral} mono>{stage}</DS.badge>
                  <span style="font-size:12px;color:var(--tx-3);">{note}</span>
                </div>
              <% end %>
            </div>
          </SC.setting_card>
        </div>

        <.issue_modal
          :if={@modal == :issue}
          org_slug={@org_slug}
          project={@project}
          form={@form}
          scopes={@scopes}
          issued_key={@issued_key}
        />
      </DS.screen>
    </Layouts.app>
    """
  end

  attr :org_slug, :string, required: true
  attr :project, :map, required: true
  attr :form, :map, required: true
  attr :scopes, :list, required: true
  attr :issued_key, :string, default: nil

  defp issue_modal(assigns) do
    ~H"""
    <DS.modal
      id="issue-key-modal"
      on_close={~p"/#{@org_slug}/#{@project.slug}/api-keys"}
      width={480}
      icon="key"
      title="Issue SDK key"
    >
      <div :if={@issued_key} id="issued-key">
        <div style="display:flex;align-items:center;gap:7px;margin-bottom:10px;">
          <DSIcons.icon name="alert" size={14} style="color:var(--warn);" />
          <span style="font-size:13.5px;color:var(--tx-1);">This key will not be shown again.</span>
        </div>
        <div
          class="card2"
          style="padding:11px;background:var(--bg-1);display:flex;align-items:center;gap:8px;"
        >
          <DS.code_block class="font-mono" style="flex:1;min-width:0;" size={12.5} text={@issued_key} />
          <SC.copy_button id="copy-issued-key" text={@issued_key} title="Copy key" />
        </div>
      </div>

      <div :if={is_nil(@issued_key)}>
        <.form for={@form} id="issue-key-form" phx-submit="issue_key" phx-change="validate_form">
          <SC.form_label text="name" />
          <DS.ds_input id="issue-key-name" field={@form[:name]} placeholder="Server key" />
          <div style="font-size:12px;color:var(--tx-3);margin-top:7px;line-height:1.55;">
            One key reads every environment of this project — the request chooses with <span class="font-mono">"environment"</span>.
          </div>
          <SC.form_label text="scopes" style="margin-top:14px;" />
          <div style="display:flex;gap:6px;">
            <SC.checkbox_option
              :for={scope <- @scopes}
              id={"issue-scope-#{scope}"}
              name="api_key[scopes][]"
              value={to_string(scope)}
              checked={to_string(scope) in List.wrap(@form[:scopes].value)}
            />
          </div>
          <div style="font-size:12px;color:var(--tx-3);margin-top:7px;line-height:1.55;">
            <span class="font-mono">read</span>
            fetches the deployed use-case document and server-filled prompt.
            <span class="font-mono">logs</span>
            reports monitoring logs back to PromptOn.
          </div>
        </.form>
      </div>

      <:footer>
        <DS.btn_link
          :if={@issued_key}
          id="issue-done"
          variant="primary"
          icon="check"
          full
          patch={~p"/#{@org_slug}/#{@project.slug}/api-keys"}
        >
          Done
        </DS.btn_link>
        <DS.btn_link
          :if={is_nil(@issued_key)}
          variant="ghost"
          patch={~p"/#{@org_slug}/#{@project.slug}/api-keys"}
        >
          Cancel
        </DS.btn_link>
        <DS.btn
          :if={is_nil(@issued_key)}
          id="confirm-issue-key"
          variant="primary"
          icon="check"
          form="issue-key-form"
          type="submit"
        >
          Issue
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end
end
