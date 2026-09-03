defmodule PromptOnWeb.AccountLive do
  @moduledoc """
  Account screen (`/account`). It belongs to **one user**, not to an organization, so it is a
  top-level route outside the organization scope.

  Only what actually exists goes in: the email (read-only; there is no action to change it, and the
  email is the sign-in method itself: ADR 0008, no password), **logged-in devices** (the CLI session
  list plus per-device logout, `PromptOn.Accounts.CliSession`), and **sessions** (log out this
  browser, **Sign out everywhere**). Email change and 2FA are not in the domain, so they are not on
  the screen either.

  ## Pressing Sign out everywhere keeps this browser signed in

  With no password there is no "change the password to cut the other sessions" path, hence the
  button (`PromptOn.Accounts.Sessions.revoke_all/2`): every other browser session and every CLI
  session is revoked. To avoid cutting the browser that pressed it, mount pulls the current token's
  `jti` out of the session and passes it as `except:` (`session["user_token"]`, the key
  `PromptOnWeb.UserSession.sign_in/2` stores through `store_in_session`).

  ## The device list is the CLI sessions

  Browser sessions are not here: the browser has a logout button, and the side that never expires
  and therefore needs a list is the CLI sessions. "Log out" revokes that one jti only
  (`CliSession.revoke_jti/2`; someone else's is not_found).

  ## Drawing the sidebar needs an organization

  This route has no `:org_slug` segment, so `PromptOnWeb.LiveProjectScope` does not run. Mount
  therefore resolves the **personal organization** (`/personal`) directly and fills the shell
  assigns. Which organization the sidebar should show is a matter of taste, and the account being
  tied to the personal organization is the least surprising choice. If there is no personal
  organization (the session is broken), the user is sent back to sign-in.
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Accounts
  alias PromptOn.Accounts.CliSession
  alias PromptOn.Accounts.Sessions
  alias PromptOnWeb.ErrorText
  alias PromptOnWeb.LiveProjectScope
  alias PromptOnWeb.SettingsComponents, as: SC

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    case Accounts.personal_organization_for(user.id, actor: user) do
      {:ok, %{} = organization} ->
        {:ok,
         socket
         |> assign_shell(organization, user)
         |> assign(session_jti: session_jti(session))
         |> load_devices()}

      _other ->
        {:ok, redirect(socket, to: ~p"/sign-in")}
    end
  end

  defp assign_shell(socket, organization, user) do
    assign(socket,
      page_title: "Account",
      organization: organization,
      organizations: LiveProjectScope.list_organizations(user),
      org_slug: LiveProjectScope.personal_segment(),
      project: nil,
      projects: LiveProjectScope.list_projects(organization, user)
    )
  end

  defp load_devices(socket),
    do: assign(socket, devices: CliSession.list(socket.assigns.current_user))

  # The jti of the current browser session token, so "Sign out everywhere" keeps only this session.
  # When it is missing (a broken session) it is nil, and everything is revoked.
  defp session_jti(session) do
    with token when is_binary(token) <- session["user_token"],
         {:ok, %{"jti" => jti}} <- AshAuthentication.Jwt.peek(token) do
      jti
    else
      _other -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Events

  @impl Phoenix.LiveView
  def handle_event("sign_out_everywhere", _params, socket) do
    case Sessions.revoke_all(socket.assigns.current_user, except: socket.assigns.session_jti) do
      :ok ->
        {:noreply, socket |> load_devices() |> put_flash(:info, "Signed out everywhere else.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  def handle_event("logout_device", %{"jti" => jti}, socket) when is_binary(jti) do
    case CliSession.revoke_jti(socket.assigns.current_user, jti) do
      :ok ->
        {:noreply, socket |> load_devices() |> put_flash(:info, "Device signed out")}

      {:error, :not_found} ->
        {:noreply,
         socket |> load_devices() |> put_flash(:error, "That device is already signed out.")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  # The shape of the socket frame is up to the client. When jti is not a string the clause above
  # does not match, so catch it here rather than killing the process.
  def handle_event("logout_device", _params, socket),
    do: {:noreply, put_flash(socket, :error, "That device is already signed out.")}

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
      nav={:account}
    >
      <DS.screen id="account-screen" title="Account" sub={to_string(@current_user.email)} max_w={720}>
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />

        <SC.setting_card
          id="account-identity-card"
          title="Sign-in"
          desc="Your email is how you sign in — we send a code to it, there is no password. Changing it isn't supported yet — ask an operator."
        >
          <div class="mono-label" style="margin-bottom:7px;">email</div>
          <DS.ds_input
            id="account-email"
            name="account[email]"
            value={to_string(@current_user.email)}
            mono
            readonly
          />
        </SC.setting_card>

        <SC.setting_card
          id="account-devices-card"
          title="Logged-in devices"
          desc="CLI sessions signed in as you. They never expire — sign one out here or run prompton logout on that machine."
        >
          <div id="device-list" style="display:flex;flex-direction:column;gap:6px;">
            <SC.row_box :for={device <- @devices} id={"device-row-#{device.jti}"} pad="10px 11px">
              <DSIcons.icon name="cpu" size={14} class="tx2" />
              <div style="display:flex;flex-direction:column;gap:2px;min-width:0;flex:1;">
                <span style="font-size:13px;color:var(--tx-0);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
                  {device.name || device.client || "Unnamed device"}
                </span>
                <span
                  class="font-mono"
                  style="font-size:11px;color:var(--tx-3);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
                >
                  {device.client || "unknown client"} · connected {SC.relative_time(device.created_at)} · used {SC.relative_time(
                    device.last_used_at
                  )}
                </span>
              </div>
              <DS.btn
                id={"logout-device-#{device.jti}"}
                variant="outline"
                phx-click="logout_device"
                phx-value-jti={device.jti}
              >
                Log out
              </DS.btn>
            </SC.row_box>
            <SC.row_box :if={@devices == []} id="device-empty" dashed pad="12px 11px">
              <span style="font-size:12.5px;color:var(--tx-2);">
                No devices yet. Run <span class="font-mono">prompton login</span> to connect one.
              </span>
            </SC.row_box>
          </div>
        </SC.setting_card>

        <SC.setting_card
          id="account-session-card"
          title="Sessions"
          desc="End this browser session, or sign out every other browser and every device above. This browser stays signed in."
        >
          <div style="display:flex;gap:8px;flex-wrap:wrap;">
            <DS.btn_link
              id="account-sign-out"
              variant="outline"
              icon="arrowRight"
              href={~p"/sign-out"}
            >
              Sign out
            </DS.btn_link>
            <DS.btn
              id="account-sign-out-everywhere"
              variant="outline"
              phx-click="sign_out_everywhere"
              data-confirm="Sign out every other browser and device? This browser stays signed in."
            >
              Sign out everywhere
            </DS.btn>
          </div>
        </SC.setting_card>
      </DS.screen>
    </Layouts.app>
    """
  end
end
