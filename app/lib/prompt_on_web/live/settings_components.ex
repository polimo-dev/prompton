defmodule PromptOnWeb.SettingsComponents do
  @moduledoc """
  Pieces and display helpers shared by the Projects · Models · Settings screens.

  Ported from the mockup `design/mockup/app/s_settings.jsx`: `SettingCard`, the settings row (the
  `background:var(--bg-1)` pill row) and the info box. Colors, padding and font sizes are the
  mockup values as is.

  Pure helpers that are not screen components (`relative_time/1` `context_length_label/1`) are
  collected here too, because the three screens must use the same wording and the same rounding.
  Error copy is shared across screens, so it lives in `PromptOnWeb.ErrorText`; project tile colors
  belong to the design system, so they are `PromptOnWeb.DS.project_color/1`.
  """

  use Phoenix.Component

  alias PromptOnWeb.DS
  alias PromptOnWeb.DSIcons

  # ---------------------------------------------------------------------------
  # Components

  @doc """
  Settings card (mockup `SettingCard`). With `danger` the border and title take the err color.

      <SC.setting_card title="General" desc="…">
        body
        <:footer><DS.btn variant="primary">Save</DS.btn></:footer>
      </SC.setting_card>
  """
  attr :title, :string, required: true
  attr :desc, :string, default: nil
  attr :danger, :boolean, default: false
  attr :id, :string, default: nil
  slot :footer
  slot :inner_block

  def setting_card(assigns) do
    ~H"""
    <div
      id={@id}
      class="card2"
      style={
        DS.style_list([
          "overflow:hidden;margin-bottom:14px;",
          if(@danger, do: "border-color:rgba(255,32,71,.30);", else: "border-color:var(--line-2);")
        ])
      }
    >
      <div style="padding:14px 16px;">
        <div style={
          DS.style_list([
            "font-size:15px;font-weight:500;",
            if(@danger, do: "color:var(--err);", else: "color:var(--tx-0);")
          ])
        }>
          {@title}
        </div>
        <div :if={@desc} style="font-size:13px;color:var(--tx-2);margin-top:3px;line-height:1.5;">
          {@desc}
        </div>
        <div :if={@inner_block != []} style="margin-top:13px;">{render_slot(@inner_block)}</div>
      </div>
      <div
        :if={@footer != []}
        class="hair-t"
        style="padding:10px 16px;background:var(--bg-1);display:flex;align-items:center;gap:10px;"
      >
        {render_slot(@footer)}
      </div>
    </div>
    """
  end

  @doc """
  One row inside a settings card (environment, dimension and key rows). The mockup's
  `background:var(--bg-1)` pill row.
  """
  attr :id, :string, default: nil
  attr :pad, :string, default: "9px 11px"
  attr :dashed, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def row_box(assigns) do
    ~H"""
    <div
      id={@id}
      class={@class}
      style={
        DS.style_list([
          "display:flex;align-items:center;gap:10px;padding:#{@pad};border-radius:var(--r);",
          if(@dashed,
            do: "border:1px dashed var(--line-2);",
            else: "background:var(--bg-1);border:1px solid var(--line);"
          )
        ])
      }
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "Info box (the mockup's info / shield box)."
  attr :icon, :string, default: "info"
  attr :icon_size, :integer, default: 13
  attr :font_size, :any, default: 11
  attr :line_height, :any, default: 1.55
  attr :pad, :string, default: "9px 11px"
  attr :radius, :string, default: "8px"
  attr :style, :any, default: nil
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def info_box(assigns) do
    ~H"""
    <div
      id={@id}
      style={
        DS.style_list([
          "display:flex;align-items:flex-start;gap:8px;padding:#{@pad};border-radius:#{@radius};",
          "background:var(--bg-2);border:1px solid var(--line);",
          @style
        ])
      }
    >
      <DSIcons.icon name={@icon} size={@icon_size} class="tx3" style="margin-top:1px;" />
      <span style={"font-size:#{@font_size}px;color:var(--tx-2);line-height:#{@line_height};"}>
        {render_slot(@inner_block)}
      </span>
    </div>
    """
  end

  @doc """
  Copy-to-clipboard button. The value rides along in `data-copy` and a colocated hook hands it to
  `navigator.clipboard`. The server never resends the value: copying an issued raw key involves no
  socket round-trip either.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :title, :string, default: "Copy"
  attr :size, :integer, default: 24

  def copy_button(assigns) do
    ~H"""
    <DS.icon_btn
      id={@id}
      name="copy"
      size={@size}
      title={@title}
      phx-hook=".CopyText"
      data-copy={@text}
    />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const text = this.el.dataset.copy || ""
            if (text && navigator.clipboard) { navigator.clipboard.writeText(text) }
          })
        }
      }
    </script>
    """
  end

  @doc "One checkbox cell (the mockup's label-wrapped checkbox row)."
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, default: nil
  attr :checked, :boolean, default: false
  attr :id, :string, default: nil
  attr :grow, :boolean, default: false

  def checkbox_option(assigns) do
    ~H"""
    <label style={
      DS.style_list([
        "display:flex;align-items:center;gap:7px;padding:7px 10px;border-radius:var(--r);",
        "background:var(--bg-1);border:1px solid var(--line-2);cursor:pointer;",
        @grow && "flex:1;min-width:0;"
      ])
    }>
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value={@value}
        checked={@checked}
        style="accent-color:var(--accent);"
      />
      <span class="font-mono" style="font-size:13px;">{@label || @value}</span>
    </label>
    """
  end

  @doc "Form label (mockup `mono-label`)."
  attr :text, :string, required: true
  attr :style, :any, default: nil

  def form_label(assigns) do
    ~H"""
    <div class="mono-label" style={DS.style_list(["margin-bottom:6px;", @style])}>{@text}</div>
    """
  end

  @doc "One form field error line. Shows the `field.errors` filled by `AshPhoenix.Form` as is."
  attr :field, Phoenix.HTML.FormField, required: true

  def field_error(assigns) do
    ~H"""
    <div :if={@field.errors != []} style="font-size:12.5px;color:var(--err);margin-top:5px;">
      {Enum.map_join(@field.errors, ", ", &error_text/1)}
    </div>
    """
  end

  defp error_text({message, opts}) when is_binary(message) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp error_text(message) when is_binary(message), do: message
  defp error_text(message), do: inspect(message)

  # ---------------------------------------------------------------------------
  # Display helpers

  @doc """
  Context length → the string of the mockup's `ctx` cell.

      iex> PromptOnWeb.SettingsComponents.context_length_label(200_000)
      "200K"

      iex> PromptOnWeb.SettingsComponents.context_length_label(1_000_000)
      "1M"

      iex> PromptOnWeb.SettingsComponents.context_length_label(nil)
      "—"
  """
  @spec context_length_label(integer() | nil) :: String.t()
  def context_length_label(nil), do: "—"
  def context_length_label(n) when is_integer(n) and n >= 1_000_000, do: "#{div(n, 1_000_000)}M"
  def context_length_label(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1_000)}K"
  def context_length_label(n) when is_integer(n), do: to_string(n)

  @doc """
  Last-used time → the mockup's `used 2m ago` copy. `nil` is `"never"`.

      iex> PromptOnWeb.SettingsComponents.relative_time(nil)
      "never"
  """
  @spec relative_time(DateTime.t() | nil, DateTime.t()) :: String.t()
  def relative_time(at, now \\ DateTime.utc_now())
  def relative_time(nil, _now), do: "never"

  def relative_time(%DateTime{} = at, now) do
    seconds = DateTime.diff(now, at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      seconds < 2_592_000 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(at, "%m-%d")
    end
  end
end
