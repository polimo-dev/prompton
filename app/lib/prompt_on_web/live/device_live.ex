defmodule PromptOnWeb.DeviceLive do
  @moduledoc """
  Device authorization approval screen (`/device`, prefilled with `?code=ABCD-EFGH`),
  agent-first-spec batch ③.

  This is where `prompton login` sends the browser. It does exactly one thing: **a person checks
  the code the CLI presented and approves or denies it.**

  ## No organization is chosen here

  What gets issued is not an organization credential but **this person's CLI session token**. The
  token's permissions are exactly that person's organization memberships, so the approval screen
  has no organization picker. Which organization to provision into is chosen per command (`--org`)
  or by the CLI config file.

  ## Sign-in is required

  The router's `PromptOnWeb.Plugs.RequireUserWithReturnTo` sends signed-out requests to `/sign-in`
  while **storing the place to return to (including `?code=`) in the session**;
  `PromptOnWeb.AuthController.success/4` reads it and sends the user back to this screen right
  after sign-in. So opening the link the CLI gave while signed out does not break the flow.

  ## The state of the code is the screen

  | State | What is shown |
  |---|---|
  | no code / typo | code input form |
  | `pending` | client name + Approve / Deny |
  | `approved`, `consumed` | "you can go back" |
  | `denied` | denied |
  | expired | expired; start over from the CLI |

  The URL's `?code=` is the only screen state (zero-downtime deployment discipline: meaningful UI
  state travels in the URL).
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Accounts
  alias PromptOn.Accounts.CliSession
  alias PromptOn.Accounts.DeviceAuthorization
  alias PromptOnWeb.ErrorText
  alias PromptOnWeb.SettingsComponents, as: SC

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Connect a device", request: nil, state: :blank)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, load_code(socket, params["code"])}
  end

  # ---------------------------------------------------------------------------
  # Events

  @impl Phoenix.LiveView
  def handle_event("find", %{"device" => %{"code" => code}}, socket) do
    case DeviceAuthorization.normalize_user_code(code) do
      nil ->
        {:noreply,
         put_flash(socket, :error, "That code doesn't look right — it is eight characters.")}

      normalized ->
        {:noreply, push_patch(socket, to: ~p"/device?code=#{normalized}")}
    end
  end

  def handle_event("approve", _params, socket) do
    user = socket.assigns.current_user

    with %{state: :pending, request: request} <- socket.assigns,
         {:ok, token, _claims} <-
           CliSession.issue(user, client: request.client, name: request.key_name),
         {:ok, approved} <-
           Accounts.approve_device_authorization(request, %{user_id: user.id, token: token},
             actor: user
           ) do
      {:noreply, assign(socket, request: approved, state: :approved)}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, ErrorText.message(error))}
      _other -> {:noreply, put_flash(socket, :error, "This code can no longer be approved.")}
    end
  end

  def handle_event("deny", _params, socket) do
    with %{state: :pending, request: request} <- socket.assigns,
         {:ok, denied} <-
           Accounts.deny_device_authorization(request, %{}, actor: socket.assigns.current_user) do
      {:noreply, assign(socket, request: denied, state: :denied)}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, ErrorText.message(error))}
      _other -> {:noreply, put_flash(socket, :error, "This code can no longer be denied.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Data

  defp load_code(socket, nil), do: assign(socket, request: nil, state: :blank)

  defp load_code(socket, raw) do
    case DeviceAuthorization.normalize_user_code(raw) do
      nil -> assign(socket, request: nil, state: :unknown)
      code -> assign_request(socket, code)
    end
  end

  defp assign_request(socket, code) do
    case Accounts.device_authorization_by_user_code(code, actor: socket.assigns.current_user) do
      {:ok, %DeviceAuthorization{} = request} ->
        assign(socket, request: request, state: state_of(request))

      _other ->
        assign(socket, request: nil, state: :unknown)
    end
  end

  # Expiry takes precedence over status: approving would only hand the CLI an `expired_token`.
  defp state_of(request) do
    cond do
      DeviceAuthorization.expired?(request) -> :expired
      request.status == :pending -> :pending
      request.status == :denied -> :denied
      true -> :approved
    end
  end

  @doc "Screen copy: one title line per state (`{title, description}`)."
  @spec copy(atom()) :: {String.t(), String.t()}
  def copy(:blank),
    do: {"Enter the code", "Your terminal is showing an eight-character code. Type it here."}

  def copy(:unknown),
    do:
      {"We don't know that code",
       "Check the code in your terminal, or start over with prompton login."}

  def copy(:expired),
    do:
      {"That code has expired",
       "Codes last 15 minutes. Run prompton login again to get a new one."}

  def copy(:denied),
    do: {"Access denied", "This device was not connected. You can close this page."}

  def copy(:approved),
    do: {"Device connected", "Your terminal has what it needs. You can close this page."}

  def copy(:pending),
    do: {"Connect this device?", "Approving signs this device in as you until you log it out."}

  # ---------------------------------------------------------------------------
  # Render

  @impl Phoenix.LiveView
  def render(assigns) do
    {title, description} = copy(assigns.state)
    assigns = assign(assigns, title: title, description: description)

    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div style="min-height:100dvh;display:flex;align-items:center;justify-content:center;padding:24px;">
      <div id="device-card" class="card2" style="width:100%;max-width:440px;padding:22px;">
        <div style="display:flex;align-items:center;gap:9px;margin-bottom:14px;">
          <DSIcons.icon name="code" size={16} class="tx2" />
          <span class="mono-label">prompton cli</span>
        </div>

        <div style="font-size:20px;font-weight:500;line-height:1.3;letter-spacing:-0.3px;">
          {@title}
        </div>
        <div style="font-size:13px;color:var(--tx-2);line-height:1.55;margin-top:6px;">
          {@description}
        </div>

        <.code_form :if={@state in [:blank, :unknown]} />
        <.request_details :if={@request && @state == :pending} request={@request} />

        <div style="display:flex;gap:8px;margin-top:18px;">
          <DS.btn
            :if={@state == :pending}
            id="device-deny"
            variant="ghost"
            phx-click="deny"
            full
          >
            Deny
          </DS.btn>
          <DS.btn
            :if={@state == :pending}
            id="device-approve"
            variant="primary"
            icon="check"
            phx-click="approve"
            full
          >
            Approve
          </DS.btn>
          <DS.btn_link
            :if={@state not in [:pending, :blank, :unknown]}
            id="device-home"
            variant="ghost"
            navigate={~p"/personal"}
            full
          >
            Back to PromptOn
          </DS.btn_link>
        </div>

        <div style="font-size:12px;color:var(--tx-3);margin-top:14px;line-height:1.55;">
          Signed in as <span class="font-mono">{to_string(@current_user.email)}</span>. The device
          gets your access — the same organizations and projects you can already reach.
        </div>
      </div>
    </div>
    """
  end

  defp code_form(assigns) do
    ~H"""
    <.form for={to_form(%{"code" => ""}, as: :device)} id="device-code-form" phx-submit="find">
      <div style="margin-top:16px;">
        <SC.form_label text="code" />
        <DS.ds_input id="device-code" name="device[code]" value="" placeholder="ABCD-EFGH" mono />
      </div>
      <div style="margin-top:12px;">
        <DS.btn id="device-find" variant="primary" type="submit" full>Continue</DS.btn>
      </div>
    </.form>
    """
  end

  attr :request, :map, required: true

  defp request_details(assigns) do
    ~H"""
    <div style="margin-top:16px;display:flex;flex-direction:column;gap:6px;">
      <SC.row_box id="device-client-row" pad="10px 11px">
        <DSIcons.icon name="cpu" size={14} class="tx2" />
        <span style="font-size:13px;color:var(--tx-0);min-width:0;overflow:hidden;text-overflow:ellipsis;">
          {@request.client}
        </span>
      </SC.row_box>
      <SC.row_box :if={@request.key_name} id="device-name-row" pad="10px 11px">
        <DSIcons.icon name="tag" size={14} class="tx2" />
        <span style="font-size:13px;color:var(--tx-1);">{@request.key_name}</span>
      </SC.row_box>
      <SC.row_box id="device-code-row" pad="10px 11px">
        <DSIcons.icon name="key" size={14} class="tx2" />
        <span class="font-mono" style="font-size:13px;color:var(--tx-0);letter-spacing:0.06em;">
          {@request.user_code}
        </span>
      </SC.row_box>
    </div>

    <SC.info_box
      id="device-warning"
      icon="shield"
      icon_size={15}
      font_size={11.5}
      line_height={1.6}
      pad="11px 13px"
      radius="var(--r)"
      style="margin-top:12px;"
    >
      Approve this only if you just started it yourself. If this code came to you any other way,
      deny it.
    </SC.info_box>
    """
  end
end
