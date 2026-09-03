defmodule PromptOnWeb.DSIcons do
  @moduledoc """
  Design system icon set. A direct port of `ICONS` from `design/mockup/app/icons.jsx`
  (Lucide-style 24×24 stroke icons, 64 of them).

      <DSIcons.icon name="flask" />
      <DSIcons.icon name="star" size={13} filled />
      <DSIcons.icon name="chevRight" size={11} class="tx3" />

  The name clashes with `CoreComponents.icon/1` (heroicons), so screens `alias PromptOnWeb.DSIcons`
  and call `<DSIcons.icon ...>` (`html_helpers` sets up the alias).

  The SVG fragments are **compile-time constants** of this module, so they are inserted as-is with
  `Phoenix.HTML.raw/1` (they are not user input). An unknown name renders as an empty icon — better
  than taking the screen down.
  """

  use Phoenix.Component

  @icons %{
    "layers" =>
      ~S|<polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/><polyline points="2 12 12 17 22 12"/>|,
    "flask" =>
      ~S|<path d="M9 3h6"/><path d="M10 3v6.5L4.5 19a1.5 1.5 0 0 0 1.3 2.2h12.4A1.5 1.5 0 0 0 19.5 19L14 9.5V3"/><path d="M7.5 15h9"/>|,
    "history" =>
      ~S|<path d="M3 12a9 9 0 1 0 2.6-6.4L3 8"/><polyline points="3 3 3 8 8 8"/><polyline points="12 7 12 12 15.5 13.8"/>|,
    "star" =>
      ~S|<polygon points="12 2.5 15.1 8.8 22 9.8 17 14.7 18.2 21.6 12 18.3 5.8 21.6 7 14.7 2 9.8 8.9 8.8 12 2.5"/>|,
    "book" =>
      ~S|<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2Z"/>|,
    "gauge" => ~S|<path d="m12 14 3.5-3.5"/><path d="M3.4 19a10 10 0 1 1 17.2 0"/>|,
    "key" =>
      ~S|<circle cx="7.5" cy="15.5" r="4.5"/><path d="m10.7 12.3 9.3-9.3"/><path d="m16.5 6.5 2.5 2.5"/><path d="m13.5 9.5 2.5 2.5"/>|,
    "settings" =>
      ~S|<path d="M12.2 2h-.4a2 2 0 0 0-2 2 1.7 1.7 0 0 1-.9 1.5 1.7 1.7 0 0 1-1.7 0 2 2 0 0 0-2.7.7l-.2.4a2 2 0 0 0 .7 2.7 1.7 1.7 0 0 1 0 3 2 2 0 0 0-.7 2.7l.2.4a2 2 0 0 0 2.7.7 1.7 1.7 0 0 1 1.7 0 1.7 1.7 0 0 1 .9 1.5 2 2 0 0 0 2 2h.4a2 2 0 0 0 2-2 1.7 1.7 0 0 1 .9-1.5 1.7 1.7 0 0 1 1.7 0 2 2 0 0 0 2.7-.7l.2-.4a2 2 0 0 0-.7-2.7 1.7 1.7 0 0 1 0-3 2 2 0 0 0 .7-2.7l-.2-.4a2 2 0 0 0-2.7-.7 1.7 1.7 0 0 1-1.7 0 1.7 1.7 0 0 1-.9-1.5 2 2 0 0 0-2-2Z"/><circle cx="12" cy="12" r="2.6"/>|,
    "play" => ~S|<polygon points="7 4 19 12 7 20 7 4"/>|,
    "chevDown" => ~S|<polyline points="6 9 12 15 18 9"/>|,
    "chevRight" => ~S|<polyline points="9 6 15 12 9 18"/>|,
    "chevUpDown" => ~S|<polyline points="7 9 12 4 17 9"/><polyline points="7 15 12 20 17 15"/>|,
    "plus" => ~S|<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>|,
    "check" => ~S|<polyline points="20 6 9 17 4 12"/>|,
    "x" => ~S|<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>|,
    "copy" =>
      ~S|<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>|,
    "save" =>
      ~S|<path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2Z"/><polyline points="17 21 17 13 7 13 7 21"/><polyline points="7 3 7 8 15 8"/>|,
    "share" =>
      ~S|<circle cx="18" cy="5" r="2.6"/><circle cx="6" cy="12" r="2.6"/><circle cx="18" cy="19" r="2.6"/><line x1="8.3" y1="13.3" x2="15.7" y2="17.7"/><line x1="15.7" y1="6.3" x2="8.3" y2="10.7"/>|,
    "sparkles" =>
      ~S|<path d="M12 3l1.6 4.4L18 9l-4.4 1.6L12 15l-1.6-4.4L6 9l4.4-1.6L12 3Z"/><path d="M19 14l.7 1.9L21.6 17l-1.9.7L19 19.6l-.7-1.9L16.4 17l1.9-.7L19 14Z"/><path d="M5 5l.6 1.6L7.2 7.2 5.6 7.8 5 9.4 4.4 7.8 2.8 7.2 4.4 6.6 5 5Z"/>|,
    "clock" => ~S|<circle cx="12" cy="12" r="9"/><polyline points="12 7 12 12 16 14"/>|,
    "zap" => ~S|<polygon points="13 2 4 14 11 14 10 22 20 10 13 10 13 2"/>|,
    "rerun" => ~S|<path d="M21 12a9 9 0 1 1-2.6-6.4"/><polyline points="21 4 21 9 16 9"/>|,
    "note" =>
      ~S|<path d="M21 14a2 2 0 0 1-2 2H8l-4 4V5a2 2 0 0 1 2-2h13a2 2 0 0 1 2 2Z"/><line x1="8" y1="8" x2="16" y2="8"/><line x1="8" y1="12" x2="13" y2="12"/>|,
    "user" =>
      ~S|<path d="M20 21v-1.5a4.5 4.5 0 0 0-4.5-4.5h-7A4.5 4.5 0 0 0 4 19.5V21"/><circle cx="12" cy="7.5" r="3.8"/>|,
    "search" => ~S|<circle cx="11" cy="11" r="7"/><line x1="21" y1="21" x2="16.5" y2="16.5"/>|,
    "filter" => ~S|<polygon points="21 4 3 4 10 12.2 10 19 14 21 14 12.2 21 4"/>|,
    "dollar" =>
      ~S|<line x1="12" y1="2" x2="12" y2="22"/><path d="M17 5.5H9.7a3.3 3.3 0 0 0 0 6.6h4.6a3.3 3.3 0 0 1 0 6.6H6"/>|,
    "more" =>
      ~S|<circle cx="5" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/>|,
    "alert" =>
      ~S|<path d="M10.3 3.9 2 18a2 2 0 0 0 1.7 3h16.6a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z"/><line x1="12" y1="9" x2="12" y2="13.5"/><line x1="12" y1="17" x2="12.01" y2="17"/>|,
    "dot" => ~S|<circle cx="12" cy="12" r="4"/>|,
    "link" =>
      ~S|<path d="M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1.5 1.5"/><path d="M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1.5-1.5"/>|,
    "send" =>
      ~S|<line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/>|,
    "arrowRight" =>
      ~S|<line x1="5" y1="12" x2="19" y2="12"/><polyline points="12 5 19 12 12 19"/>|,
    "tag" =>
      ~S|<path d="M20.6 13.4 13.4 20.6a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8Z"/><circle cx="7.5" cy="7.5" r="1.3"/>|,
    "sliders" =>
      ~S|<line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1.5" y1="14" x2="6.5" y2="14"/><line x1="9.5" y1="8" x2="14.5" y2="8"/><line x1="17.5" y1="16" x2="22.5" y2="16"/>|,
    "grid" =>
      ~S|<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>|,
    "check2" => ~S|<circle cx="12" cy="12" r="9"/><polyline points="8.5 12 11 14.5 15.5 9.5"/>|,
    "cpu" =>
      ~S|<rect x="6" y="6" width="12" height="12" rx="2"/><line x1="9" y1="2" x2="9" y2="5"/><line x1="15" y1="2" x2="15" y2="5"/><line x1="9" y1="19" x2="9" y2="22"/><line x1="15" y1="19" x2="15" y2="22"/><line x1="19" y1="9" x2="22" y2="9"/><line x1="19" y1="15" x2="22" y2="15"/><line x1="2" y1="9" x2="5" y2="9"/><line x1="2" y1="15" x2="5" y2="15"/>|,
    "globe" =>
      ~S|<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3a14 14 0 0 1 0 18 14 14 0 0 1 0-18Z"/>|,
    "bolt" => ~S|<path d="M11 2 4 13h6l-1 9 7-11h-6l1-9Z"/>|,
    "diff" => ~S|<path d="M12 3v18"/><path d="M3 9h18"/><path d="M3 15h18"/>|,
    "eye" =>
      ~S|<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>|,
    "trash" =>
      ~S|<polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>|,
    "lock" =>
      ~S|<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>|,
    "card" =>
      ~S|<rect x="2" y="5" width="20" height="14" rx="2"/><line x1="2" y1="9.5" x2="22" y2="9.5"/>|,
    "mail" => ~S|<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3.5 7 8.5 6 8.5-6"/>|,
    "shield" => ~S|<path d="M12 2 4 5v6c0 5 3.4 8.6 8 10 4.6-1.4 8-5 8-10V5l-8-3Z"/>|,
    "coin" =>
      ~S|<circle cx="12" cy="12" r="9"/><path d="M12 7.2v9.6"/><path d="M14.6 9.4a2.8 2.8 0 0 0-2.6-1.4c-1.5 0-2.6.8-2.6 2s1.1 1.7 2.6 2 2.6.8 2.6 2-1.1 2-2.6 2a2.8 2.8 0 0 1-2.6-1.4"/>|,
    "plusCircle" =>
      ~S|<circle cx="12" cy="12" r="9"/><line x1="12" y1="8.5" x2="12" y2="15.5"/><line x1="8.5" y1="12" x2="15.5" y2="12"/>|,
    "info" =>
      ~S|<circle cx="12" cy="12" r="9"/><line x1="12" y1="11" x2="12" y2="16"/><line x1="12" y1="8" x2="12.01" y2="8"/>|,
    "arrowUpRight" =>
      ~S|<line x1="7" y1="17" x2="17" y2="7"/><polyline points="8 7 17 7 17 16"/>|,
    "arrowDownLeft" =>
      ~S|<line x1="17" y1="7" x2="7" y2="17"/><polyline points="16 17 7 17 7 8"/>|,
    "building" =>
      ~S|<rect x="4" y="3" width="16" height="18" rx="1.5"/><line x1="9" y1="7" x2="9" y2="7"/><line x1="15" y1="7" x2="15" y2="7"/><line x1="9" y1="11" x2="9" y2="11"/><line x1="15" y1="11" x2="15" y2="11"/><path d="M10 21v-4h4v4"/>|,
    "route" =>
      ~S|<circle cx="6" cy="19" r="2.5"/><circle cx="18" cy="5" r="2.5"/><path d="M8.5 19H14a4 4 0 0 0 0-8H10a4 4 0 0 1 0-8h5.5"/>|,
    "server" =>
      ~S|<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><line x1="7" y1="7.5" x2="7" y2="7.5"/><line x1="7" y1="16.5" x2="7" y2="16.5"/>|,
    "gitBranch" =>
      ~S|<line x1="6" y1="4" x2="6" y2="14"/><circle cx="6" cy="17.5" r="2.5"/><circle cx="6" cy="4" r="0.6"/><circle cx="17" cy="6.5" r="2.5"/><path d="M17 9v1a4 4 0 0 1-4 4H8"/>|,
    "database" =>
      ~S|<ellipse cx="12" cy="5.5" rx="8" ry="3"/><path d="M4 5.5v13c0 1.7 3.6 3 8 3s8-1.3 8-3v-13"/><path d="M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>|,
    "activity" => ~S|<polyline points="2 12 6 12 9 20 15 4 18 12 22 12"/>|,
    "list" =>
      ~S|<line x1="9" y1="6" x2="21" y2="6"/><line x1="9" y1="12" x2="21" y2="12"/><line x1="9" y1="18" x2="21" y2="18"/><circle cx="4.5" cy="6" r="1.2"/><circle cx="4.5" cy="12" r="1.2"/><circle cx="4.5" cy="18" r="1.2"/>|,
    "code" => ~S|<polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>|,
    "variable" =>
      ~S|<path d="M6 4c-2.5 3-2.5 13 0 16"/><path d="M18 4c2.5 3 2.5 13 0 16"/><line x1="9" y1="9.5" x2="15" y2="14.5"/><line x1="15" y1="9.5" x2="9" y2="14.5"/>|,
    "boxes" =>
      ~S|<rect x="3" y="3" width="8" height="8" rx="1.5"/><rect x="13" y="3" width="8" height="8" rx="1.5"/><rect x="3" y="13" width="8" height="8" rx="1.5"/><rect x="13" y="13" width="8" height="8" rx="1.5"/>|,
    "target" =>
      ~S|<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.4"/>|,
    "flag" => ~S|<path d="M5 21V4"/><path d="M5 4h10l-1.5 4L15 12H5"/>|
  }

  @icon_names @icons |> Map.keys() |> Enum.sort()

  @doc "List of the defined icon names (sorted)."
  @spec icon_names() :: [String.t()]
  def icon_names, do: @icon_names

  @doc "The inner SVG fragment for a name (`\"\"` when unknown)."
  @spec fragment(String.t()) :: String.t()
  def fragment(name) when is_binary(name), do: Map.get(@icons, name, "")

  @doc """
  Inline SVG icon. `viewBox="0 0 24 24"`, colored with `currentColor`.

  - `name` — one of `icon_names/0`
  - `size` — px (default 16). Fractions are fine (the mockup uses 14.5)
  - `stroke` — stroke-width (default 1.9)
  - `filled` — when true, `fill="currentColor"` and no stroke (filled icons such as star)
  """
  attr :name, :string, required: true
  attr :size, :any, default: 16
  attr :stroke, :any, default: 1.9
  attr :filled, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def icon(assigns) do
    assigns = assign(assigns, :fragment, fragment(assigns.name))

    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill={if @filled, do: "currentColor", else: "none"}
      stroke={if @filled, do: "none", else: "currentColor"}
      stroke-width={@stroke}
      stroke-linecap="round"
      stroke-linejoin="round"
      class={["shrink-0", @class]}
      aria-hidden="true"
      {@rest}
    >
      {Phoenix.HTML.raw(@fragment)}
    </svg>
    """
  end
end
