defmodule PromptOnWeb.DS do
  @moduledoc """
  PromptOn design system function components. The structure comes from `design/mockup/app/ui.jsx`;
  colors, radii, typefaces, and control dimensions use the tokens (`:root` in `assets/css/app.css`)
  that `design/resend-brief.md` carried into this codebase from `design/DESIGN-resend.md` (the
  canonical source) — inline styles never write values directly and only reference `var(--…)`.
  Hover restyling is handled by the `.dsbtn* .dsiconbtn .dsrow-click .dstab …` classes in `app.css`.

  Screens `alias PromptOnWeb.DS` (`html_helpers` sets it up) and then call `<DS.btn>` and friends.
  Icons are `PromptOnWeb.DSIcons` (`<DSIcons.icon name="flask" />`).

  ## URL state discipline (CLAUDE.md zero-downtime deployment)

  Tabs (`screen/1`), drawer/modal close, and segmented controls **all take patch links**.
  The URL, not an event handler, has to hold the state so that when a deployment drops the socket
  and the view remounts, the user comes back to the same screen.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias PromptOnWeb.DSIcons

  # Code typeface — spec code-md (Geist Mono). The same stack as `--font-mono` in `app.css`.
  @mono_font "'Geist Mono', ui-monospace, SFMono-Regular, Menlo, monospace"

  defp mono_font, do: @mono_font

  # HEEx only filters nil/false out of `class` lists — `style` lists have to be filtered by hand.
  @doc false
  @spec style_list(iodata() | nil | false) :: String.t() | nil
  def style_list(parts) do
    case parts |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.join() do
      "" -> nil
      css -> css
    end
  end

  # ---------------------------------------------------------------------------
  # Palette and tokens (data.jsx PROVIDERS / ui.jsx TONES)

  @providers %{
    openrouter: %{letter: "R", tint: "#8b7cf6"},
    anthropic: %{letter: "A", tint: "#cc7a52"},
    openai: %{letter: "O", tint: "#10a37f"},
    google: %{letter: "G", tint: "#3b9eff"},
    groq: %{letter: "Q", tint: "#f05a3c"}
  }

  # Status colors are used only as **text, a 1px line, or a 10–12% tint** (spec: no fills). The
  # tint values are `:root`'s --ok/--warn/--err.
  @tones %{
    neutral: %{bg: "var(--bg-3)", fg: "var(--tx-1)", bd: "var(--line-2)"},
    accent: %{bg: "var(--accent-soft)", fg: "var(--tx-0)", bd: "var(--accent-line)"},
    star: %{bg: "rgba(255,197,61,.10)", fg: "var(--star)", bd: "rgba(255,197,61,.30)"},
    ok: %{bg: "rgba(17,255,153,.08)", fg: "var(--ok)", bd: "rgba(17,255,153,.26)"},
    warn: %{bg: "rgba(255,197,61,.10)", fg: "var(--warn)", bd: "rgba(255,197,61,.30)"},
    err: %{bg: "rgba(255,32,71,.10)", fg: "var(--err)", bd: "rgba(255,32,71,.30)"},
    violet: %{bg: "rgba(139,124,246,.12)", fg: "var(--violet-fg)", bd: "rgba(139,124,246,.30)"}
  }

  @role_tones %{"system" => :violet, "user" => :accent, "assistant" => :ok, "text" => :neutral}

  @doc "Tone name → `%{bg:, fg:, bd:}` (ui.jsx TONES). Unknown values fall back to `:neutral`."
  @spec tone(atom() | String.t() | nil) :: %{bg: String.t(), fg: String.t(), bd: String.t()}
  def tone(name) when is_binary(name), do: tone(known_atom(name, Map.keys(@tones)))
  def tone(name), do: Map.get(@tones, name, @tones.neutral)

  @doc "Provider → `%{letter:, tint:}` (data.jsx PROVIDERS). Unknown values default to openrouter."
  @spec provider(atom() | String.t() | nil) :: %{letter: String.t(), tint: String.t()}
  def provider(name) when is_binary(name), do: provider(known_atom(name, Map.keys(@providers)))
  def provider(name), do: Map.get(@providers, name, @providers.openrouter)

  @doc "Message role → tone name (`system` → `:violet`)."
  @spec role_tone(atom() | String.t() | nil) :: atom()
  def role_tone(role), do: Map.get(@role_tones, to_string(role || ""), :neutral)

  # Never turns a string into an atom — only looks it up in the allow list.
  defp known_atom(value, allowed), do: Enum.find(allowed, &(to_string(&1) == value))

  # ---------------------------------------------------------------------------
  # Formatters (ui.jsx fmtCost / fmtMs / fmtNum)

  @doc """
  Cost display. `nil` → `—`, 0 → `$0`, below 0.01 four decimals, otherwise two.

      iex> PromptOnWeb.DS.fmt_cost(0.0012)
      "$0.0012"

      iex> PromptOnWeb.DS.fmt_cost(nil)
      "—"
  """
  @spec fmt_cost(number() | Decimal.t() | nil) :: String.t()
  def fmt_cost(nil), do: "—"
  def fmt_cost(%Decimal{} = c), do: c |> Decimal.to_float() |> fmt_cost()

  def fmt_cost(c) when is_number(c) do
    f = c * 1.0

    cond do
      f == 0.0 -> "$0"
      abs(f) < 0.01 -> "$" <> :erlang.float_to_binary(f, decimals: 4)
      true -> "$" <> :erlang.float_to_binary(f, decimals: 2)
    end
  end

  @doc """
  Latency display. `nil` → `—`, 1000ms and above in seconds (one decimal), otherwise `123ms`.

      iex> PromptOnWeb.DS.fmt_ms(6100)
      "6.1s"

      iex> PromptOnWeb.DS.fmt_ms(240)
      "240ms"
  """
  @spec fmt_ms(number() | Decimal.t() | nil) :: String.t()
  def fmt_ms(nil), do: "—"
  def fmt_ms(%Decimal{} = ms), do: ms |> Decimal.to_float() |> fmt_ms()

  def fmt_ms(ms) when is_number(ms) do
    if ms >= 1000 do
      :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
    else
      "#{round(ms)}ms"
    end
  end

  @doc """
  Integer with thousands separators. `nil` → `—`.

      iex> PromptOnWeb.DS.fmt_num(1284)
      "1,284"

      iex> PromptOnWeb.DS.fmt_num(96)
      "96"
  """
  @spec fmt_num(number() | Decimal.t() | nil) :: String.t()
  def fmt_num(nil), do: "—"
  def fmt_num(%Decimal{} = n), do: n |> Decimal.round(0) |> Decimal.to_integer() |> fmt_num()
  def fmt_num(n) when is_float(n), do: n |> round() |> fmt_num()

  def fmt_num(n) when is_integer(n) do
    sign = if n < 0, do: "-", else: ""

    grouped =
      n
      |> abs()
      |> Integer.to_string()
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.map(&(&1 |> Enum.reverse() |> Enum.join()))
      |> Enum.reverse()
      |> Enum.join(",")

    sign <> grouped
  end

  # ---------------------------------------------------------------------------
  # Atomic components

  @doc """
  Provider mark — one letter plus the provider color (the tint from data.jsx PROVIDERS).

      <DS.provider_mark provider={:anthropic} />
  """
  attr :provider, :any,
    required: true,
    doc: "`:openrouter` `:anthropic` `:openai` `:google` `:groq`"

  attr :size, :any, default: 18
  attr :radius, :integer, default: 6
  attr :class, :any, default: nil

  def provider_mark(assigns) do
    assigns = assign(assigns, :p, provider(assigns.provider))

    ~H"""
    <span
      class={@class}
      title={to_string(@provider)}
      style={
        style_list([
          "width:#{@size}px;height:#{@size}px;border-radius:#{@radius}px;",
          "background:#{@p.tint}22;border:1px solid #{@p.tint}55;color:#{@p.tint};",
          "display:inline-flex;align-items:center;justify-content:center;",
          "font-family:#{mono_font()};font-size:#{@size * 0.5}px;font-weight:600;flex-shrink:0;"
        ])
      }
    >{@p.letter}</span>
    """
  end

  @doc """
  Status dot (spec status-dot — 8px, no glow). `kind` is `:ok` `:warn` `:err` `:idle`; `pulse`
  makes it blink.
  """
  attr :kind, :atom, default: :ok, values: [:ok, :warn, :err, :idle]
  attr :pulse, :boolean, default: false
  attr :size, :integer, default: 8
  attr :class, :any, default: nil

  def status_dot(assigns) do
    color =
      case assigns.kind do
        :ok -> "var(--ok)"
        :warn -> "var(--warn)"
        :err -> "var(--err)"
        :idle -> "var(--tx-4)"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span
      class={[@pulse && "pulse", @class]}
      style={
        style_list([
          "width:#{@size}px;height:#{@size}px;border-radius:var(--r-pill);display:inline-block;",
          "background:#{@color};flex-shrink:0;"
        ])
      }
    />
    """
  end

  @variants ~w(primary accent_soft solid outline ghost danger)
  @sizes ~w(sm md lg)

  @doc """
  Button (ui.jsx Btn). Renders a `<button>` — use `btn_link/1` when you need a link.

      <DS.btn variant="primary" icon="plus" phx-click="new_use_case">New use case</DS.btn>
  """
  attr :variant, :string, default: "ghost", values: @variants
  attr :size, :string, default: "md", values: @sizes
  attr :icon, :string, default: nil
  attr :icon_right, :string, default: nil
  attr :active, :boolean, default: false, doc: "pressed state of the ghost variant"
  attr :full, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value type)
  slot :inner_block

  def btn(assigns) do
    ~H"""
    <button class={btn_class(@variant, @size, @active, @full, @class)} {@rest}>
      <DSIcons.icon :if={@icon} name={@icon} size={icon_size(@size)} />
      {render_slot(@inner_block)}
      <DSIcons.icon :if={@icon_right} name={@icon_right} size={icon_size(@size)} />
    </button>
    """
  end

  @doc """
  Button-shaped link — one of `navigate` / `patch` / `href`. Variants and sizes match `btn/1`.
  """
  attr :variant, :string, default: "ghost", values: @variants
  attr :size, :string, default: "md", values: @sizes
  attr :icon, :string, default: nil
  attr :icon_right, :string, default: nil
  attr :active, :boolean, default: false
  attr :full, :boolean, default: false
  attr :class, :any, default: nil
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :any, default: nil
  attr :rest, :global
  slot :inner_block

  def btn_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={btn_class(@variant, @size, @active, @full, @class)}
      {@rest}
    >
      <DSIcons.icon :if={@icon} name={@icon} size={icon_size(@size)} />
      {render_slot(@inner_block)}
      <DSIcons.icon :if={@icon_right} name={@icon_right} size={icon_size(@size)} />
    </.link>
    """
  end

  defp btn_class(variant, size, active, full, extra) do
    ["dsbtn", "dsbtn-#{variant}", "dsbtn-#{size}", active && "is-active", full && "w-full", extra]
  end

  defp icon_size("sm"), do: 13
  defp icon_size(_), do: 14.5

  @doc """
  Icon button (ui.jsx IconBtn). Becomes a link when given `patch`/`navigate`/`href`.

      <DS.icon_btn name="x" patch={~p"/personal/acme/use-cases"} title="Close" />
  """
  attr :name, :string, required: true
  attr :size, :integer, default: 28
  attr :active, :boolean, default: false
  attr :filled, :boolean, default: false
  attr :color, :string, default: nil
  attr :stroke, :any, default: 1.9
  attr :class, :any, default: nil
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :any, default: nil
  attr :rest, :global, include: ~w(disabled form name value type title)

  def icon_btn(%{navigate: nil, patch: nil, href: nil} = assigns) do
    ~H"""
    <button class={icon_btn_class(@active, @class)} style={icon_btn_style(@size, @color)} {@rest}>
      <DSIcons.icon name={@name} size={inner_icon_size(@size)} filled={@filled} stroke={@stroke} />
    </button>
    """
  end

  def icon_btn(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={icon_btn_class(@active, @class)}
      style={icon_btn_style(@size, @color)}
      {@rest}
    >
      <DSIcons.icon name={@name} size={inner_icon_size(@size)} filled={@filled} stroke={@stroke} />
    </.link>
    """
  end

  defp icon_btn_class(active, extra), do: ["dsiconbtn", active && "is-active", extra]

  defp icon_btn_style(size, color),
    do: style_list(["width:#{size}px;height:#{size}px;", color && "color:#{color};"])

  defp inner_icon_size(size) when size <= 24, do: 14
  defp inner_icon_size(_), do: 15.5

  @doc """
  Badge (ui.jsx Badge). `tone` is one of `:neutral :accent :star :ok :warn :err :violet`.
  """
  attr :tone, :any, default: :neutral
  attr :mono, :boolean, default: false
  attr :class, :any, default: nil
  attr :style, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    assigns = assign(assigns, :t, tone(assigns.tone))

    ~H"""
    <span
      class={@class}
      style={
        style_list([
          "display:inline-flex;align-items:center;gap:4px;font-size:12px;padding:2px 8px;",
          "border-radius:var(--r-pill);background:#{@t.bg};color:#{@t.fg};border:1px solid #{@t.bd};",
          if(@mono,
            do: "font-family:#{mono_font()};letter-spacing:0.02em;",
            else: "font-family:inherit;"
          ),
          "font-weight:500;line-height:1.4;white-space:nowrap;justify-self:start;",
          @style
        ])
      }
      {@rest}
    >{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  Environment pill (ui.jsx EnvPill). `protected` adds a lock. Becomes a link when given
  `patch`/`navigate`.
  """
  attr :name, :string, required: true
  attr :protected, :boolean, default: false
  attr :active, :boolean, default: false
  attr :compact, :boolean, default: false
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def env_pill(%{navigate: nil, patch: nil} = assigns) do
    ~H"""
    <span class={["tr", @class]} style={env_pill_style(@active, @compact)} {@rest}>
      <DSIcons.icon :if={@protected} name="lock" size={10} />{@name}
    </span>
    """
  end

  def env_pill(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      class={["tr", @class]}
      style={style_list([env_pill_style(@active, @compact), "text-decoration:none;cursor:pointer;"])}
      {@rest}
    >
      <DSIcons.icon :if={@protected} name="lock" size={10} />{@name}
    </.link>
    """
  end

  defp env_pill_style(active, compact) do
    style_list([
      "display:inline-flex;align-items:center;gap:5px;font-size:13px;",
      if(compact, do: "padding:2px 7px;", else: "padding:4px 9px;"),
      "border-radius:var(--r-sm);font-family:#{mono_font()};",
      if(active,
        do: "background:var(--bg-3);color:var(--tx-0);border:1px solid var(--line-2);",
        else: "background:transparent;color:var(--tx-2);border:1px solid transparent;"
      )
    ])
  end

  # ---------------------------------------------------------------------------
  # Page shell

  @doc """
  Screen shell (ui.jsx Screen). A 64px header + an optional tab row + a scrolling body.

  Tabs are **patch links** — the active tab has to stay in the URL so a remount comes back to the
  same tab.

      <DS.screen title="Use Cases" sub="9 use cases"
                 tabs={[%{id: "all", label: "All", count: 9, patch: ~p"/personal/acme/use-cases?tab=all"}]}
                 active_tab={@tab}>
        <:crumb label="personal" navigate={~p"/personal"} />
        <:actions><DS.btn variant="primary" icon="plus">New</DS.btn></:actions>
        Body
      </DS.screen>
  """
  attr :title, :string, default: nil
  attr :title_mono, :boolean, default: false
  attr :sub, :string, default: nil
  attr :max_w, :integer, default: 1120
  attr :pad, :integer, default: 24

  attr :flush, :boolean,
    default: false,
    doc: "fill the body edge to edge, no padding or max width"

  attr :tabs, :list, default: [], doc: "list of `%{id:, label:, count: nil, patch:}`"
  attr :active_tab, :any, default: nil
  attr :id, :string, default: nil

  slot :crumb do
    attr :label, :string, required: true
    attr :navigate, :string
    attr :patch, :string
  end

  slot :actions
  slot :inner_block, required: true

  def screen(assigns) do
    ~H"""
    <div id={@id} style="flex:1;display:flex;flex-direction:column;height:100%;min-width:0;">
      <div
        class={@tabs == [] && "hair-b"}
        style="min-height:64px;flex-shrink:0;display:flex;align-items:center;gap:14px;padding:10px 24px;"
      >
        <div style="min-width:0;">
          <div :if={@crumb != []} style="display:flex;align-items:center;gap:6px;margin-bottom:2px;">
            <%= for {c, i} <- Enum.with_index(@crumb) do %>
              <DSIcons.icon :if={i > 0} name="chevRight" size={11} class="tx3" />
              <.link
                :if={c[:navigate] || c[:patch]}
                navigate={c[:navigate]}
                patch={c[:patch]}
                style="font-size:12.5px;line-height:1.3;color:var(--tx-2);white-space:nowrap;text-decoration:none;"
              >
                {c.label}
              </.link>
              <span
                :if={!(c[:navigate] || c[:patch])}
                style="font-size:12.5px;line-height:1.3;color:var(--tx-3);white-space:nowrap;"
              >
                {c.label}
              </span>
            <% end %>
          </div>
          <div
            :if={@title}
            style={
              style_list([
                "font-size:22px;line-height:1.3;font-weight:500;letter-spacing:-0.3px;white-space:nowrap;",
                if(@title_mono, do: "font-family:#{mono_font()};", else: "font-family:inherit;")
              ])
            }
          >
            {@title}
          </div>
          <div :if={@sub} style="font-size:13px;line-height:1.35;color:var(--tx-2);margin-top:1px;">
            {@sub}
          </div>
        </div>
        <div style="margin-left:auto;display:flex;align-items:center;gap:8px;">
          {render_slot(@actions)}
        </div>
      </div>

      <div
        :if={@tabs != []}
        class="hair-b"
        style="flex-shrink:0;display:flex;align-items:center;gap:2px;padding:0 24px;"
      >
        <.link
          :for={t <- @tabs}
          id={"tab-#{t.id}"}
          patch={t[:patch]}
          navigate={t[:navigate]}
          class={["dstab tr", to_string(t.id) == to_string(@active_tab) && "is-active"]}
        >
          {t.label}
          <span :if={t[:count]} class="font-mono" style="font-size:12px;color:var(--tx-3);">
            {t[:count]}
          </span>
        </.link>
      </div>

      <div style={"flex:1;overflow-y:auto;min-height:0;padding:#{if @flush, do: 0, else: @pad}px;"}>
        <%= if @flush do %>
          {render_slot(@inner_block)}
        <% else %>
          <div style={"max-width:#{@max_w}px;margin:0 auto;"}>{render_slot(@inner_block)}</div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc "Stat tile (ui.jsx StatTile)."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, default: nil
  attr :sub, :string, default: nil
  attr :tone, :any, default: nil
  attr :icon, :string, default: nil
  attr :class, :any, default: nil

  def stat_tile(assigns) do
    ~H"""
    <div class={["card2", @class]} style="padding:12px 14px;">
      <div style="display:flex;align-items:center;gap:6px;margin-bottom:7px;">
        <DSIcons.icon :if={@icon} name={@icon} size={12} class="tx3" />
        <span class="mono-label" style="padding:0;">{@label}</span>
      </div>
      <div style="display:flex;align-items:baseline;gap:4px;">
        <span style={
          style_list([
            "font-size:24px;font-weight:500;letter-spacing:-0.4px;line-height:1.2;font-variant-numeric:tabular-nums;",
            "color:#{if @tone, do: tone(@tone).fg, else: "var(--tx-0)"};"
          ])
        }>
          {@value}
        </span>
        <span :if={@unit} style="font-size:12.5px;color:var(--tx-2);">{@unit}</span>
      </div>
      <div :if={@sub} style="font-size:12px;color:var(--tx-3);margin-top:4px;">{@sub}</div>
    </div>
    """
  end

  @doc "Sparkline (ui.jsx Sparkline). `data` is a list of numbers (two or more)."
  attr :data, :list, required: true
  attr :w, :integer, default: 220
  attr :h, :integer, default: 34
  attr :color, :string, default: "var(--accent)"
  attr :class, :any, default: nil

  def sparkline(assigns) do
    assigns = assign(assigns, :points, sparkline_points(assigns.data, assigns.w, assigns.h))

    ~H"""
    <svg
      :if={@points}
      width={@w}
      height={@h}
      class={@class}
      style="display:block;overflow:visible;"
      aria-hidden="true"
    >
      <polygon points={"0,#{@h} #{@points} #{@w},#{@h}"} fill="var(--accent-soft)" opacity="0.5" />
      <polyline
        points={@points}
        fill="none"
        stroke={@color}
        stroke-width="1.5"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  defp sparkline_points(data, w, h) when is_list(data) and length(data) > 1 do
    nums = Enum.map(data, &(&1 * 1.0))
    max = Enum.max([Enum.max(nums), 1.0])
    min = Enum.min(nums)
    span = if max - min == 0.0, do: 1.0, else: max - min
    last = length(nums) - 1

    nums
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {d, i} ->
      x = i / last * w
      y = h - (d - min) / span * (h - 4) - 2
      "#{:erlang.float_to_binary(x, decimals: 1)},#{:erlang.float_to_binary(y, decimals: 1)}"
    end)
  end

  defp sparkline_points(_data, _w, _h), do: nil

  # ---------------------------------------------------------------------------
  # Table (CSS grid)

  @doc """
  Grid table (ui.jsx Table). `cols` is a list of `%{label:, w:, align: "left"}`, and the same
  `cols` must be passed to `row/1` for the columns to line up.

      <DS.table cols={@cols}>
        <DS.row :for={{uc, i} <- Enum.with_index(@use_cases)} cols={@cols} index={i}
                navigate={~p"/personal/acme/use-cases/\#{uc.key}"}>
          …
        </DS.row>
      </DS.table>
  """
  attr :cols, :list, required: true
  attr :class, :any, default: nil
  attr :style, :any, default: nil
  attr :id, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def table(assigns) do
    ~H"""
    <div id={@id} class={["card2", @class]} style={style_list(["overflow:hidden;", @style])} {@rest}>
      <div
        class="hair-b"
        style={"display:grid;grid-template-columns:#{grid_cols(@cols)};gap:12px;padding:10px 14px;align-items:center;"}
      >
        <span :for={c <- @cols} class="mono-label" style={"text-align:#{c[:align] || "left"};"}>
          {c[:label]}
        </span>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Table row (ui.jsx Row). Given `navigate`/`patch`/`href` it becomes a link row; a `phx-click` row
  turns on hover/cursor with `clickable`. `index > 0` adds a hairline on top.
  """
  attr :cols, :list, required: true
  attr :index, :integer, default: 0
  attr :selected, :boolean, default: false
  attr :tone, :any, default: nil
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :any, default: nil
  attr :clickable, :boolean, default: false
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def row(%{navigate: nil, patch: nil, href: nil} = assigns) do
    ~H"""
    <div
      id={@id}
      class={row_class(@clickable, @selected, @tone, @class)}
      style={row_style(@cols, @index, @selected, @tone)}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  def row(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={row_class(true, @selected, @tone, @class)}
      style={
        style_list([
          row_style(@cols, @index, @selected, @tone),
          "color:inherit;text-decoration:none;"
        ])
      }
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp row_class(clickable, selected, tone, extra) do
    ["tr", clickable && "dsrow-click", selected && "is-selected", tone && "has-tone", extra]
  end

  defp row_style(cols, index, selected, tone) do
    bg =
      cond do
        selected -> "var(--bg-3)"
        tone -> tone(tone).bg
        true -> "transparent"
      end

    style_list([
      "display:grid;grid-template-columns:#{grid_cols(cols)};gap:12px;padding:11px 14px;min-height:44px;align-items:center;",
      if(index > 0, do: "border-top:1px solid var(--line);", else: ""),
      "background:#{bg};"
    ])
  end

  defp grid_cols(cols), do: Enum.map_join(cols, " ", &(&1[:w] || "1fr"))

  @doc "One key/value line (ui.jsx Kv). The value is mono by default and right-aligned."
  attr :label, :string, required: true
  attr :mono, :boolean, default: true
  attr :w, :integer, default: 96
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def kv(assigns) do
    ~H"""
    <div class={@class} style="display:flex;align-items:baseline;gap:10px;padding:4px 0;">
      <span style={"font-size:12.5px;color:var(--tx-2);width:#{@w}px;flex-shrink:0;white-space:nowrap;"}>
        {@label}
      </span>
      <span
        class={@mono && "font-mono"}
        style="font-size:13px;color:var(--tx-0);margin-left:auto;text-align:right;min-width:0;overflow-wrap:anywhere;"
      >{render_slot(@inner_block)}</span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Overlays — closing is always a patch

  @doc """
  Right-hand slide-over (ui.jsx Drawer). The open target has to be in the URL, so **closing is a
  patch**.

      <DS.drawer :if={@selected} on_close={~p"/personal/acme/use-cases"} title={@selected.name}>…</DS.drawer>
  """
  attr :id, :string, default: "drawer"
  attr :on_close, :any, required: true, doc: "path to patch to on close (or a `%JS{}`)"
  attr :width, :integer, default: 640
  attr :title, :string, default: nil
  attr :sub, :string, default: nil
  slot :badge
  slot :actions
  slot :footer
  slot :inner_block, required: true

  def drawer(assigns) do
    assigns = assign(assigns, :close, close_js(assigns.on_close))

    ~H"""
    <div
      id={@id}
      style="position:fixed;inset:0;z-index:70;display:flex;justify-content:flex-end;"
      phx-window-keydown={@close}
      phx-key="escape"
    >
      <div
        id={"#{@id}-backdrop"}
        style="position:absolute;inset:0;background:rgba(0,0,0,.6);"
        phx-click={@close}
        aria-hidden="true"
      />
      <div
        class="slidein"
        style={
          style_list([
            "position:relative;width:#{@width}px;max-width:92vw;height:100%;display:flex;flex-direction:column;",
            "background:var(--bg-2);border-left:1px solid var(--line-2);"
          ])
        }
      >
        <div
          class="hair-b"
          style="padding:13px 16px;display:flex;align-items:center;gap:10px;flex-shrink:0;"
        >
          <div style="min-width:0;flex:1;">
            <div style="display:flex;align-items:center;gap:8px;">
              <span style={"font-size:15px;font-weight:500;font-family:#{mono_font()};white-space:nowrap;"}>
                {@title}
              </span>
              {render_slot(@badge)}
            </div>
            <div :if={@sub} style="font-size:12.5px;color:var(--tx-2);margin-top:2px;">{@sub}</div>
          </div>
          {render_slot(@actions)}
          <.icon_btn name="x" phx-click={@close} title="Close" />
        </div>
        <div style="flex:1;overflow-y:auto;padding:16px;min-height:0;">
          {render_slot(@inner_block)}
        </div>
        <div
          :if={@footer != []}
          class="hair-t"
          style="padding:11px 16px;display:flex;align-items:center;gap:8px;flex-shrink:0;background:var(--bg-1);"
        >
          {render_slot(@footer)}
        </div>
      </div>
    </div>
    """
  end

  @doc "Centered modal (ui.jsx Modal). Rendered only while open; closing is a patch."
  attr :id, :string, default: "modal"
  attr :on_close, :any, required: true
  attr :width, :integer, default: 460
  attr :title, :string, default: nil
  attr :icon, :string, default: nil
  slot :footer
  slot :inner_block, required: true

  def modal(assigns) do
    assigns = assign(assigns, :close, close_js(assigns.on_close))

    ~H"""
    <div
      id={@id}
      style="position:fixed;inset:0;z-index:80;display:flex;align-items:center;justify-content:center;padding:30px;"
      phx-window-keydown={@close}
      phx-key="escape"
    >
      <div
        id={"#{@id}-backdrop"}
        style="position:absolute;inset:0;background:rgba(0,0,0,.6);"
        phx-click={@close}
        aria-hidden="true"
      />
      <div
        class="fadeup"
        style={
          style_list([
            "position:relative;width:#{@width}px;max-width:100%;max-height:86vh;display:flex;flex-direction:column;",
            "background:var(--bg-2);border:1px solid var(--line-2);border-radius:var(--r-xl);"
          ])
        }
      >
        <div
          class="hair-b"
          style="padding:13px 16px;display:flex;align-items:center;gap:9px;flex-shrink:0;"
        >
          <DSIcons.icon :if={@icon} name={@icon} size={16} style="color:var(--tx-1);" />
          <span style="font-size:16px;font-weight:500;flex:1;">{@title}</span>
          <.icon_btn name="x" phx-click={@close} title="Close" />
        </div>
        <div style="padding:16px;overflow-y:auto;flex:1;min-height:0;">
          {render_slot(@inner_block)}
        </div>
        <div
          :if={@footer != []}
          class="hair-t"
          style="padding:11px 16px;display:flex;align-items:center;gap:8px;flex-shrink:0;"
        >
          {render_slot(@footer)}
        </div>
      </div>
    </div>
    """
  end

  defp close_js(%JS{} = js), do: js
  defp close_js(path) when is_binary(path), do: JS.patch(path)

  # ---------------------------------------------------------------------------
  # Forms and inputs

  @doc """
  Segmented control (ui.jsx Seg). Each option is a `patch` link (recommended) or a `phx-click`
  button.

      <DS.seg value={@env} options={[%{value: "production", label: "prod", patch: ~p"/…?env=production"}]} />
  """
  attr :options, :list, required: true, doc: "list of `%{value:, label:, patch: nil}`"
  attr :value, :any, default: nil
  attr :event, :string, default: nil, doc: "phx-click event name used when there is no patch"
  attr :target, :any, default: nil
  attr :class, :any, default: nil
  attr :id, :string, default: nil
  attr :rest, :global

  def seg(assigns) do
    ~H"""
    <div id={@id} class={["seg", @class]} style="width:fit-content;" {@rest}>
      <%= for o <- @options do %>
        <.link
          :if={o[:patch] || o[:navigate]}
          patch={o[:patch]}
          navigate={o[:navigate]}
          class={to_string(o.value) == to_string(@value) && "on"}
          style="text-decoration:none;"
        >
          {o[:label] || o.value}
        </.link>
        <button
          :if={!(o[:patch] || o[:navigate])}
          type="button"
          class={to_string(o.value) == to_string(@value) && "on"}
          phx-click={@event}
          phx-target={@target}
          phx-value-value={o.value}
          style="cursor:pointer;border:none;font-family:inherit;background:transparent;"
        >
          {o[:label] || o.value}
        </button>
      <% end %>
    </div>
    """
  end

  @doc """
  Text input (ui.jsx Input). Inside a form, passing `field={@form[:name]}` fills in name/value/id.
  """
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :type, :string, default: "text"
  attr :placeholder, :string, default: nil
  attr :mono, :boolean, default: false
  attr :icon, :string, default: nil
  attr :prefix, :string, default: nil
  attr :w, :any, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(autocomplete disabled readonly required maxlength pattern step)

  def ds_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(:field, nil)
    |> assign(:name, assigns.name || field.name)
    |> assign(:id, assigns.id || field.id)
    |> assign(
      :value,
      assigns.value || Phoenix.HTML.Form.normalize_value(assigns.type, field.value)
    )
    |> ds_input()
  end

  def ds_input(assigns) do
    ~H"""
    <div
      class={["ring-acc", @class]}
      style={
        style_list([
          "display:flex;align-items:center;gap:7px;background:var(--bg-2);border:1px solid var(--line-2);",
          "border-radius:var(--r);padding:0 12px;",
          @w && "width:#{css_len(@w)};"
        ])
      }
    >
      <DSIcons.icon :if={@icon} name={@icon} size={13} class="tx3" />
      <span :if={@prefix} class="font-mono" style="font-size:12.5px;color:var(--tx-3);">{@prefix}</span>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        class={@mono && "font-mono"}
        style="flex:1;min-width:0;background:transparent;border:none;outline:none;color:var(--tx-0);font-size:14px;line-height:20px;padding:9px 0;"
        {@rest}
      />
    </div>
    """
  end

  @doc """
  Select (ui.jsx Select). `options` is in `Phoenix.HTML.Form.options_for_select/2` form
  (`["a", "b"]` or `[{"label", "value"}]`).
  """
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :w, :any, default: 120
  attr :mono, :boolean, default: false
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled multiple required)

  def ds_select(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(:field, nil)
    |> assign(:name, assigns.name || field.name)
    |> assign(:id, assigns.id || field.id)
    |> assign(:value, assigns.value || field.value)
    |> ds_select()
  end

  def ds_select(assigns) do
    ~H"""
    <select
      id={@id}
      name={@name}
      class={[@mono && "font-mono", @class]}
      style={
        style_list([
          "background:var(--bg-2);border:1px solid var(--line-2);border-radius:var(--r);",
          "color:var(--tx-0);font-size:14px;height:40px;padding:0 10px;outline:none;cursor:pointer;",
          @w && "width:#{css_len(@w)};",
          if(@mono, do: "font-family:#{mono_font()};", else: "font-family:inherit;")
        ])
      }
      {@rest}
    >
      {Phoenix.HTML.Form.options_for_select(@options, @value)}
    </select>
    """
  end

  defp css_len(v) when is_integer(v), do: "#{v}px"
  defp css_len(v) when is_binary(v), do: v

  # ---------------------------------------------------------------------------
  # Text and code

  @doc "Code block (ui.jsx Code). Pass `text` or use the body slot."
  attr :text, :string, default: nil
  attr :wrap, :boolean, default: true
  attr :size, :any, default: 13
  attr :class, :any, default: nil
  attr :style, :any, default: nil
  slot :inner_block

  def code_block(assigns) do
    ~H"""
    <pre
      class={["font-mono", @class]}
      style={
        style_list([
          "margin:0;font-size:#{@size}px;line-height:1.6;color:var(--tx-0);",
          if(@wrap, do: "white-space:pre-wrap;overflow-wrap:anywhere;", else: "white-space:pre;"),
          @style
        ])
      }
      phx-no-curly-interpolation
    ><%= @text %><%= render_slot(@inner_block) %></pre>
    """
  end

  @doc """
  Liquid template highlighting (ui.jsx Liquid). `{{ … }}` is link blue, `{% … %}` is violet
  (syntax colors inside the code well, not UI accents).
  The body is **user content**, so HEEx escapes it (`raw/1` is not used).
  """
  attr :text, :string, default: ""
  attr :size, :any, default: 13
  attr :class, :any, default: nil
  attr :style, :any, default: nil

  def liquid(assigns) do
    assigns = assign(assigns, :parts, liquid_tokens(assigns.text))

    ~H"""
    <pre
      class={["font-mono", @class]}
      style={
        style_list([
          "margin:0;font-size:#{@size}px;line-height:1.65;white-space:pre-wrap;",
          "overflow-wrap:anywhere;color:var(--tx-0);",
          @style
        ])
      }
      phx-no-curly-interpolation
    ><span :for={{kind, text} <- @parts} style={liquid_style(kind)}><%= text %></span></pre>
    """
  end

  @doc """
  Splits Liquid source into a list of `{:output | :tag | :text, fragment}` (ui.jsx liquidTokens).

      iex> PromptOnWeb.DS.liquid_tokens("hi {{ name }}!")
      [text: "hi ", output: "{{ name }}", text: "!"]
  """
  @spec liquid_tokens(String.t() | nil) :: [{:output | :tag | :text, String.t()}]
  def liquid_tokens(nil), do: []

  def liquid_tokens(text) when is_binary(text) do
    ~r/(\{\{[^}]*\}\}|\{%[^%]*%\})/
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      cond do
        String.starts_with?(part, "{{") -> {:output, part}
        String.starts_with?(part, "{%") -> {:tag, part}
        true -> {:text, part}
      end
    end)
  end

  defp liquid_style(:output),
    do: "color:var(--link);background:rgba(59,158,255,.12);border-radius:var(--r-xs);"

  defp liquid_style(:tag),
    do: "color:var(--violet-fg);background:rgba(139,124,246,.12);border-radius:var(--r-xs);"

  defp liquid_style(:text), do: nil

  # Metrics from ui.jsx HighlightedEditor — the highlight layer (pre) and the textarea have to
  # **overlap character for character**, so both elements must use exactly the same values.
  @editor_metrics "font-family:'Geist Mono', ui-monospace, SFMono-Regular, Menlo, monospace;" <>
                    "font-variant-ligatures:none;" <>
                    "font-size:13px;line-height:1.6;padding:10px 12px;letter-spacing:normal;" <>
                    "white-space:pre-wrap;overflow-wrap:anywhere;tab-size:2;margin:0;border:0;"

  defp editor_metrics, do: @editor_metrics

  @doc """
  A textarea with Liquid highlighting laid behind the caret (ui.jsx HighlightedEditor, plan.md
  §10.2).

  A `<pre>` highlight layer with the same metrics is stacked beneath a transparent textarea. The
  highlighting is drawn **by the server**, so it only refreshes once the value comes up via
  `phx-change` — put `phx-change` on the form and give it a `phx-debounce`.

      <.form for={@form} phx-change="validate" phx-submit="save">
        <DS.highlighted_editor id="sys" field={@form[:system]} phx-debounce="200" />
      </.form>

  A colocated hook grows the height to fit the content (it never shrinks below `min_height`).
  """
  attr :id, :string, required: true
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :name, :string, default: nil
  attr :value, :string, default: ""
  attr :min_height, :integer, default: 120
  attr :placeholder, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled readonly required)

  def highlighted_editor(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(:field, nil)
    |> assign(:name, assigns.name || field.name)
    |> assign(:value, assigns.value || to_string(field.value || ""))
    |> highlighted_editor()
  end

  def highlighted_editor(assigns) do
    assigns = assign(assigns, :parts, liquid_tokens(assigns.value))

    ~H"""
    <div class={@class} style="position:relative;">
      <pre
        aria-hidden="true"
        id={"#{@id}-highlight"}
        style={
          style_list([
            editor_metrics(),
            "position:absolute;inset:0;pointer-events:none;overflow:hidden;color:var(--tx-0);"
          ])
        }
        phx-no-curly-interpolation
      ><span :for={{kind, text} <- @parts} style={liquid_style(kind)}><%= text %></span><%= "\n" %></pre>
      <textarea
        id={@id}
        name={@name}
        placeholder={@placeholder}
        spellcheck="false"
        class="ring-acc"
        phx-hook=".AutoGrowEditor"
        data-min-height={@min_height}
        style={
          style_list([
            editor_metrics(),
            "position:relative;display:block;width:100%;min-height:#{@min_height}px;",
            "background:transparent;color:transparent;-webkit-text-fill-color:transparent;",
            "caret-color:var(--tx-0);outline:none;resize:none;overflow:hidden;"
          ])
        }
        {@rest}
      ><%= @value %></textarea>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoGrowEditor">
      export default {
        grow() {
          const min = parseInt(this.el.dataset.minHeight || "120", 10)
          this.el.style.height = "auto"
          this.el.style.height = Math.max(min, this.el.scrollHeight) + "px"
        },
        mounted() {
          this.grow()
          this.el.addEventListener("input", () => this.grow())
        },
        updated() { this.grow() }
      }
    </script>
    """
  end

  @doc """
  List of message cards (ui.jsx MessagesView). `messages` is a list of `%{role:, content:}`
  (Ash embedded structs work too — atom keys). `highlight` turns on Liquid highlighting.
  """
  attr :messages, :list, required: true
  attr :highlight, :boolean, default: false

  attr :max, :integer,
    default: nil,
    doc: "max height of a message body (px) — scrolls on overflow"

  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def messages_view(assigns) do
    ~H"""
    <div id={@id} class={@class} style="display:flex;flex-direction:column;gap:8px;">
      <div
        :for={{m, i} <- Enum.with_index(@messages)}
        id={"#{@id || "messages"}-#{i}"}
        class="card2"
        style="background:var(--bg-1);overflow:hidden;"
      >
        <div class="hair-b" style="padding:6px 10px;display:flex;align-items:center;gap:7px;">
          <.badge tone={role_tone(m.role)} mono>{m.role}</.badge>
          <span class="font-mono" style="margin-left:auto;font-size:11px;color:var(--tx-3);">
            {String.length(m.content || "")} ch
          </span>
        </div>
        <div style={
          style_list(["padding:9px 11px;", @max && "max-height:#{@max}px;overflow-y:auto;"])
        }>
          <.liquid :if={@highlight} text={m.content} />
          <.code_block :if={!@highlight} text={m.content} />
        </div>
      </div>
    </div>
    """
  end

  @doc "Line-level diff (ui.jsx DiffView) — emits add/del/eq via LCS."
  attr :from, :string, default: ""
  attr :to, :string, default: ""
  attr :class, :any, default: nil

  def diff_view(assigns) do
    assigns = assign(assigns, :rows, line_diff(assigns.from, assigns.to))

    ~H"""
    <div class={["card2", @class]} style="background:var(--bg-1);overflow:hidden;">
      <div
        :for={{kind, line} <- @rows}
        style={
          style_list([
            "display:flex;gap:8px;padding:1px 10px;background:#{diff_bg(kind)};",
            "border-left:2px solid #{if kind == :eq, do: "transparent", else: diff_fg(kind)};"
          ])
        }
      >
        <span
          class="font-mono"
          style={"font-size:12.5px;color:#{diff_fg(kind)};width:8px;flex-shrink:0;"}
        >
          {diff_sign(kind)}
        </span>
        <span
          class="font-mono"
          style={
            style_list([
              "font-size:13px;line-height:1.6;white-space:pre-wrap;overflow-wrap:anywhere;",
              "color:#{if kind == :eq, do: "var(--tx-1)", else: "var(--tx-0)"};"
            ])
          }
        >{blank_to_space(line)}</span>
      </div>
    </div>
    """
  end

  defp blank_to_space(""), do: " "
  defp blank_to_space(line), do: line

  defp diff_bg(:add), do: "rgba(17,255,153,.08)"
  defp diff_bg(:del), do: "rgba(255,32,71,.08)"
  defp diff_bg(:eq), do: "transparent"

  defp diff_fg(:add), do: "var(--ok)"
  defp diff_fg(:del), do: "var(--err)"
  defp diff_fg(:eq), do: "var(--tx-2)"

  defp diff_sign(:add), do: "+"
  defp diff_sign(:del), do: "−"
  defp diff_sign(:eq), do: " "

  @max_diff_lines 3_000

  @doc """
  Line-level LCS diff (a port of ui.jsx lineDiff). Returns a list of `{:eq | :add | :del, line}`.
  Once either side exceeds #{@max_diff_lines} lines it skips the O(m×n) table and treats the
  change as a wholesale replacement.

      iex> PromptOnWeb.DS.line_diff("a\\nb", "a\\nc")
      [eq: "a", del: "b", add: "c"]
  """
  @spec line_diff(String.t() | nil, String.t() | nil) :: [{:eq | :add | :del, String.t()}]
  def line_diff(from, to) do
    a = String.split(from || "", "\n")
    b = String.split(to || "", "\n")

    if length(a) > @max_diff_lines or length(b) > @max_diff_lines do
      Enum.map(a, &{:del, &1}) ++ Enum.map(b, &{:add, &1})
    else
      at = List.to_tuple(a)
      bt = List.to_tuple(b)
      walk_diff(at, bt, lcs_table(at, bt), 0, 0, [])
    end
  end

  defp lcs_table(a, b) do
    m = tuple_size(a)
    n = tuple_size(b)
    last = Tuple.duplicate(0, n + 1)

    rows =
      if m == 0 do
        [last]
      else
        Enum.reduce((m - 1)..0//-1, [last], fn i, [next | _] = acc ->
          [List.to_tuple(lcs_row(a, b, i, n, next)) | acc]
        end)
      end

    List.to_tuple(rows)
  end

  defp lcs_row(_a, _b, _i, 0, _next), do: [0]

  defp lcs_row(a, b, i, n, next) do
    Enum.reduce((n - 1)..0//-1, [0], fn j, [right | _] = cells ->
      value =
        if elem(a, i) == elem(b, j) do
          elem(next, j + 1) + 1
        else
          max(elem(next, j), right)
        end

      [value | cells]
    end)
  end

  defp walk_diff(a, b, dp, i, j, acc) do
    walk_step(a, b, dp, i, j, acc, i < tuple_size(a), j < tuple_size(b))
  end

  defp walk_step(_a, _b, _dp, _i, _j, acc, false, false), do: Enum.reverse(acc)

  defp walk_step(a, b, dp, i, j, acc, true, false),
    do: walk_diff(a, b, dp, i + 1, j, [{:del, elem(a, i)} | acc])

  defp walk_step(a, b, dp, i, j, acc, false, true),
    do: walk_diff(a, b, dp, i, j + 1, [{:add, elem(b, j)} | acc])

  defp walk_step(a, b, dp, i, j, acc, true, true) do
    cond do
      elem(a, i) == elem(b, j) ->
        walk_diff(a, b, dp, i + 1, j + 1, [{:eq, elem(a, i)} | acc])

      # On a tie, emit the deletion first (the same choice as ui.jsx lineDiff).
      elem(elem(dp, i + 1), j) >= elem(elem(dp, i), j + 1) ->
        walk_diff(a, b, dp, i + 1, j, [{:del, elem(a, i)} | acc])

      true ->
        walk_diff(a, b, dp, i, j + 1, [{:add, elem(b, j)} | acc])
    end
  end

  # ---------------------------------------------------------------------------
  # Fragments and states

  @doc "Empty state (ui.jsx Empty)."
  attr :icon, :string, default: "layers"
  attr :title, :string, required: true
  attr :sub, :string, default: nil
  attr :class, :any, default: nil
  attr :id, :string, default: nil
  slot :action

  def empty(assigns) do
    ~H"""
    <div
      id={@id}
      class={@class}
      style="display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;gap:12px;padding:52px 30px;"
    >
      <span style="width:40px;height:40px;border-radius:var(--r-lg);background:var(--bg-2);border:1px solid var(--line-2);display:flex;align-items:center;justify-content:center;">
        <DSIcons.icon name={@icon} size={19} class="tx3" />
      </span>
      <div>
        <div style="font-size:15px;font-weight:500;">{@title}</div>
        <div
          :if={@sub}
          style="font-size:13.5px;color:var(--tx-2);margin-top:4px;max-width:340px;line-height:1.55;"
        >
          {@sub}
        </div>
      </div>
      {render_slot(@action)}
    </div>
    """
  end

  @doc "Placeholder box (ui.jsx Placeholder)."
  attr :label, :string, required: true
  attr :h, :integer, default: 120
  attr :class, :any, default: nil

  def placeholder(assigns) do
    ~H"""
    <div
      class={@class}
      style={
        style_list([
          "height:#{@h}px;border-radius:var(--r);border:1px dashed var(--line-2);",
          "background:repeating-linear-gradient(135deg, rgba(255,255,255,.018) 0 10px, transparent 10px 20px);",
          "display:flex;align-items:center;justify-content:center;"
        ])
      }
    >
      <span class="font-mono" style="font-size:12.5px;color:var(--tx-3);">{@label}</span>
    </div>
    """
  end

  @doc """
  Collapsible card (ui.jsx Collapsible). Because it is a `<details>`, the browser holds the open
  state and a LiveView patch does not close it.
  """
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :open, :boolean, default: false
  attr :mono, :boolean, default: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :right
  slot :inner_block, required: true

  def collapsible(assigns) do
    ~H"""
    <details id={@id} class={["card2 dscollapse", @class]} style="overflow:hidden;" open={@open}>
      <summary>
        <DSIcons.icon name="chevRight" size={14} class="tx2 dscollapse-closed" />
        <DSIcons.icon name="chevDown" size={14} class="tx2 dscollapse-open" />
        <DSIcons.icon :if={@icon} name={@icon} size={14} class="tx2" />
        <span style={
          style_list([
            "font-size:13.5px;font-weight:500;",
            if(@mono, do: "font-family:#{mono_font()};", else: "font-family:inherit;")
          ])
        }>
          {@label}
        </span>
        <span style="margin-left:auto;display:flex;align-items:center;gap:6px;">
          {render_slot(@right)}
        </span>
      </summary>
      <div class="fadeup">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  @doc """
  Project slug → tile color. The mockups (`sidebar.jsx`, `s_overview.jsx`) carry one `color` per
  project, and the sidebar switcher and the project card use **the same color**. The domain has no
  such field, so it is picked deterministically from a hash of the slug — which is why this must be
  the only such function. With a palette per screen, the same project would show up blue in the
  sidebar and orange on the card.

      iex> PromptOnWeb.DS.project_color("helpdesk") =~ "#"
      true

      iex> PromptOnWeb.DS.project_color("acme") == PromptOnWeb.DS.project_color("acme")
      true
  """
  # The spec's accent colors (blue, violet, green, orange, yellow) plus provider teal — painted only
  # as dots and tints.
  @project_palette ~w(#3b9eff #8b7cf6 #11ff99 #ff801f #ffc53d #10a37f)

  @spec project_color(String.t()) :: String.t()
  def project_color(slug) when is_binary(slug) do
    Enum.at(@project_palette, :erlang.phash2(slug, length(@project_palette)))
  end

  @doc """
  Star rating (ui.jsx Stars). Given `event` it becomes clickable and sends 1..5 as
  `phx-value-star`.

  **No screen uses this right now** — it is a library component kept for when the Evals screen
  (plan.md §5.8) arrives. Do not attach it to a screen that has nowhere to store the rating.
  """
  attr :value, :integer, default: 0
  attr :event, :string, default: nil
  attr :size, :integer, default: 16
  attr :target, :any, default: nil
  attr :class, :any, default: nil

  def stars(assigns) do
    ~H"""
    <div class={["dsstars", @class]} style="display:flex;gap:2px;" role="group">
      <button
        :for={n <- 1..5}
        type="button"
        class={["dsstar", n <= @value && "is-on"]}
        disabled={is_nil(@event)}
        phx-click={@event}
        phx-target={@target}
        phx-value-star={n}
        title={"#{n}"}
        style={is_nil(@event) && "cursor:default;"}
      >
        <DSIcons.icon name="star" size={@size} filled={n <= @value} />
      </button>
    </div>
    """
  end
end
