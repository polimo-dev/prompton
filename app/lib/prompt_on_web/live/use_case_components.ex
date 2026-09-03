defmodule PromptOnWeb.UseCaseComponents do
  @moduledoc """
  Function components for the use case list screen only (`UseCasesLive`, mockup `s_usecases.jsx`).

  Holds only the **screen-specific** pieces that are not in DS (`PromptOnWeb.DS`): variable chips,
  field label/error, radio segment. The old detail screen's tab bodies (Prompts/Deployments) were
  absorbed by the use case hub (`PromptOnWeb.PromptEditorLive`).

  Every selection UI is a **real input** (radio/range). The mockup's pill/list buttons were ported
  to `<label>` + hidden radio, because that is what lets Phoenix form recovery revive the selection
  when a deploy drops the socket (CLAUDE.md zero-downtime deployment discipline: tabs and modals in
  the URL, in-progress forms through form recovery).
  """
  use PromptOnWeb, :html

  @kind_icons %{chat: "note", text: "code", embedding: "variable"}

  @doc "Use case kind → icon name (mockup `KIND_ICON`)."
  @spec kind_icon(atom() | String.t()) :: String.t()
  def kind_icon(kind), do: Map.get(@kind_icons, kind_atom(kind), "layers")

  defp kind_atom(kind) when is_atom(kind), do: kind
  defp kind_atom("chat"), do: :chat
  defp kind_atom("text"), do: :text
  defp kind_atom("embedding"), do: :embedding
  defp kind_atom(_), do: nil

  @doc "Whether this is a log-only use case (`kind :embedding`); mockup `logOnly`."
  @spec log_only?(map()) :: boolean()
  def log_only?(%{kind: kind}), do: kind_atom(kind) == :embedding

  # ---------------------------------------------------------------------------
  # Chips

  @doc """
  Variable chip row (the mockup list's `variables` column). `variables` is a list of
  `%{name:, required?:}`, and anything beyond `limit` folds into `+N`.
  """
  attr :variables, :list, required: true
  attr :limit, :integer, default: nil, doc: "nil means no folding"
  attr :size, :any, default: 10
  attr :mono, :boolean, default: false
  attr :class, :any, default: nil

  def variable_chips(assigns) do
    limit = assigns.limit || length(assigns.variables)

    assigns =
      assign(assigns,
        shown: Enum.take(assigns.variables, limit),
        rest_count: max(length(assigns.variables) - limit, 0)
      )

    ~H"""
    <span class={@class} style="display:flex;gap:4px;flex-wrap:wrap;min-width:0;">
      <span
        :for={v <- @shown}
        class={["chip", @mono && "font-mono"]}
        style={"font-size:#{@size}px;"}
      >
        {v.name}<span :if={Map.get(v, :required?)} style="color:var(--tx-1);">*</span>
      </span>
      <span
        :if={@rest_count > 0}
        class="font-mono"
        style={"font-size:#{@size}px;color:var(--tx-3);"}
      >
        +{@rest_count}
      </span>
    </span>
    """
  end

  # ---------------------------------------------------------------------------
  # Form pieces

  @doc "Mono label (mockup `mono-label`) plus bottom margin."
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def field_label(assigns) do
    ~H"""
    <div class={["mono-label", @class]} style="margin-bottom:6px;">{render_slot(@inner_block)}</div>
    """
  end

  @doc "Form field errors (only once the input has actually been touched)."
  attr :field, Phoenix.HTML.FormField, required: true

  def field_error(assigns) do
    assigns =
      assign(
        assigns,
        :errors,
        if(Phoenix.Component.used_input?(assigns.field), do: assigns.field.errors, else: [])
      )

    ~H"""
    <p
      :for={{message, _opts} <- @errors}
      class="font-mono"
      style="margin:5px 0 0;font-size:12px;color:var(--err);"
    >
      {message}
    </p>
    """
  end

  @doc """
  Segmented radio (the form version of the mockup's `Seg`). `options` is a list of `{value, label}`.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :class, :any, default: nil

  def seg_radio(assigns) do
    ~H"""
    <div id={@id} class={["seg", @class]} style="width:fit-content;">
      <label
        :for={{value, label} <- @options}
        for={"#{@id}-#{value}"}
        style={seg_label_style(selected?(value, @value))}
      >
        <input
          type="radio"
          id={"#{@id}-#{value}"}
          name={@name}
          value={value}
          checked={selected?(value, @value)}
          style="position:absolute;width:1px;height:1px;opacity:0;pointer-events:none;"
        />
        {label}
      </label>
    </div>
    """
  end

  # Same dimensions as the `.seg` recipe (app.css); the selection is an elevated surface plus ink,
  # no shadow.
  defp seg_label_style(true),
    do:
      "font-size:13px;font-weight:500;padding:4px 10px;border-radius:var(--r-sm);cursor:pointer;" <>
        "background:var(--bg-3);color:var(--tx-0);"

  defp seg_label_style(false),
    do:
      "font-size:13px;font-weight:500;padding:4px 10px;border-radius:var(--r-sm);cursor:pointer;" <>
        "background:transparent;color:var(--tx-2);"

  defp selected?(_option, nil), do: false
  defp selected?(option, value), do: to_string(option) == to_string(value)
end
