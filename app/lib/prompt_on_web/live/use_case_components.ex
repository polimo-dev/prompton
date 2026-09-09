defmodule PromptOnWeb.UseCaseComponents do
  @moduledoc """
  Function components for the use case list screen only (`UseCasesLive`, mockup `s_usecases.jsx`).

  Holds only the **screen-specific** pieces that are not in DS (`PromptOnWeb.DS`): variable chips
  and field label/error. The old detail screen's tab bodies (Prompts/Deployments) were
  absorbed by the use case hub (`PromptOnWeb.PromptEditorLive`).
  """
  use PromptOnWeb, :html

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
end
