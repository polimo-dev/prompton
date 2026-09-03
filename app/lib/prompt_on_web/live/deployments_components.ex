defmodule PromptOnWeb.DeploymentsComponents do
  @moduledoc """
  Deployment pieces: presentational components that draw **one pin**, plus pure helpers (ADR 0007
  revision 2026-09-01).

  The module used by the Deployments tab of the use case hub (`PromptOnWeb.PromptEditorLive`). When
  a revision turned from a router into a pin, **the rule editor, condition chips, target rows and
  diff-lite all disappeared**. All there is to draw for one revision is one model, a version per
  prompt name, params, and who committed it when.

  The remaining screen vocabulary is three items:

  - `pin_card/1` — what is pinned right now (or by the selected revision).
  - `revision_row/1` — one line of revision history (select patch + rollback patch).

  The label helpers (`pin_rows/2`, `model_label/2`) are pure functions. A reference that is gone
  from the snapshot/index is shown as the leading characters of its id (more honest than a dead
  screen).
  """
  use PromptOnWeb, :html

  @doc ~S|Revision label: `3` → `"#3"`. Kept separate to avoid `#{}` inside the HEEx body.|
  @spec num(term()) :: String.t()
  def num(nil), do: "—"
  def num(number), do: "#" <> to_string(number)

  @doc "The commit time as one line."
  @spec when_label(map() | nil) :: String.t()
  def when_label(%{inserted_at: at}) when not is_nil(at),
    do: at |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M")

  def when_label(_deployment), do: "—"

  @doc """
  A revision's pin list as display rows. `default` always comes first and the rest are in name
  order: when the app sends no name it gets `default`, so that is the head of this list.

      iex> PromptOnWeb.DeploymentsComponents.pin_rows(nil, %{})
      []
  """
  @spec pin_rows(map() | nil, map()) :: [%{name: String.t(), version: String.t()}]
  def pin_rows(nil, _index), do: []

  def pin_rows(%{prompt_pins: pins}, index) when is_map(pins) do
    pins
    |> Enum.sort_by(fn {name, _id} -> {name != "default", name} end)
    |> Enum.map(fn {name, id} -> %{name: name, version: version_label(id, index)} end)
  end

  def pin_rows(_deployment, _index), do: []

  @doc """
  Version label: `v3` when it is in the index; a version that is not (archived or deleted) shows
  the leading characters of its id.

      iex> PromptOnWeb.DeploymentsComponents.version_label(nil, %{})
      "—"
  """
  @spec version_label(term(), map()) :: String.t()
  def version_label(nil, _index), do: "—"

  def version_label(id, index) do
    case Map.get(index, id) do
      %{number: number} -> "v#{number}"
      _unknown -> short(id)
    end
  end

  @doc "Catalog display name of the model the revision pins. Leading id characters when unknown."
  @spec model_label(map() | nil, map()) :: String.t()
  def model_label(nil, _index), do: "—"

  def model_label(%{model_id: id}, index) do
    case Map.get(index, id) do
      %{display_name: display} -> display
      _unknown -> short(id)
    end
  end

  @doc "Provider of the model the revision pins (for the provider mark); `:openrouter` if unknown."
  @spec model_provider(map() | nil, map()) :: atom()
  def model_provider(%{model_id: id}, index) do
    case Map.get(index, id) do
      %{provider: provider} -> provider
      _unknown -> :openrouter
    end
  end

  def model_provider(_deployment, _index), do: :openrouter

  @doc "The model string (`anthropic/claude-sonnet-4`), or `nil` when there is none."
  @spec model_string(map() | nil, map()) :: String.t() | nil
  def model_string(%{model_id: id}, index) do
    case Map.get(index, id) do
      %{model_id: model_id} -> model_id
      _unknown -> nil
    end
  end

  def model_string(_deployment, _index), do: nil

  @doc """
  A params/provider_options map as a sorted `{key, display value}` list.

      iex> PromptOnWeb.DeploymentsComponents.params_pairs(%{"temperature" => 0.4})
      [{"temperature", "0.4"}]
  """
  @spec params_pairs(map() | nil) :: [{String.t(), String.t()}]
  def params_pairs(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {to_string(key), format_value(value)} end)
  end

  def params_pairs(_params), do: []

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_list(value), do: Enum.join(value, ",")
  defp format_value(value) when is_map(value), do: Jason.encode!(value)
  defp format_value(value), do: to_string(value)

  @doc "Number of pins (0 for `kind :embedding`)."
  @spec pin_count(map() | nil) :: non_neg_integer()
  def pin_count(%{prompt_pins: pins}) when is_map(pins), do: map_size(pins)
  def pin_count(_deployment), do: 0

  defp short(nil), do: "—"
  defp short(id), do: id |> to_string() |> String.slice(0, 8)

  # ---------------------------------------------------------------------------
  # Pin (read-only; there is no editor)

  @doc """
  Everything one revision pins: the model, a version per prompt name, params and provider options.
  With `live?` a `live` badge is attached to the header.
  """
  attr :deployment, :map, required: true
  attr :model_index, :map, required: true
  attr :version_index, :map, required: true
  attr :live?, :boolean, default: false
  attr :committer, :string, default: "—"

  def pin_card(assigns) do
    assigns =
      assigns
      |> assign(:pins, pin_rows(assigns.deployment, assigns.version_index))
      |> assign(:params, params_pairs(assigns.deployment.params))
      |> assign(:provider_options, params_pairs(assigns.deployment.provider_options))
      |> assign(:model_id_string, model_string(assigns.deployment, assigns.model_index))

    ~H"""
    <div
      id="pin-card"
      class="card2"
      style="padding:11px 13px;display:flex;flex-direction:column;gap:11px;"
    >
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
        <span class="font-mono" style="font-size:13.5px;font-weight:600;">
          {num(@deployment.revision)}
        </span>
        <DS.badge :if={@live?} id="pin-live" tone={:ok} mono style="font-size:10px;">live</DS.badge>
        <span style="flex:1;"></span>
        <span style="font-size:12.5px;color:var(--tx-3);overflow-wrap:anywhere;">{@committer}</span>
        <span class="font-mono" style="font-size:12px;color:var(--tx-3);white-space:nowrap;">
          {when_label(@deployment)}
        </span>
      </div>

      <div style="display:flex;align-items:flex-start;gap:8px;">
        <span class="mono-label" style="width:74px;flex-shrink:0;padding-top:3px;">model</span>
        <span id="pin-model" style="display:flex;align-items:center;gap:7px;min-width:0;">
          <DS.provider_mark provider={model_provider(@deployment, @model_index)} size={18} radius={5} />
          <span class="font-mono" style="font-size:13px;color:var(--tx-0);">
            {model_label(@deployment, @model_index)}
          </span>
          <span
            :if={@model_id_string}
            class="font-mono"
            style="font-size:12px;color:var(--tx-3);min-width:0;overflow:hidden;text-overflow:ellipsis;"
          >
            {@model_id_string}
          </span>
        </span>
      </div>

      <div style="display:flex;align-items:flex-start;gap:8px;">
        <span class="mono-label" style="width:74px;flex-shrink:0;padding-top:3px;">prompts</span>
        <div id="pin-prompts" style="flex:1;min-width:0;display:flex;flex-wrap:wrap;gap:5px;">
          <span :if={@pins == []} style="font-size:12.5px;color:var(--tx-3);">
            None — this use case pins no prompt.
          </span>
          <span
            :for={pin <- @pins}
            id={"pin-#{pin.name}"}
            class="chip"
            style="display:flex;align-items:center;gap:6px;padding:4px 8px;"
          >
            <span class="font-mono" style="font-size:12.5px;color:var(--tx-0);">{pin.name}</span>
            <span style="font-size:11px;color:var(--tx-3);">·</span>
            <span class="font-mono" style="font-size:12.5px;color:var(--tx-1);">{pin.version}</span>
          </span>
        </div>
      </div>

      <div :if={@params != []} style="display:flex;align-items:flex-start;gap:8px;">
        <span class="mono-label" style="width:74px;flex-shrink:0;padding-top:3px;">params</span>
        <div id="pin-params" style="flex:1;min-width:0;display:flex;flex-wrap:wrap;gap:8px;">
          <span
            :for={{key, value} <- @params}
            class="font-mono"
            style="font-size:12px;color:var(--tx-2);white-space:nowrap;"
          >
            {key}={value}
          </span>
        </div>
      </div>

      <div :if={@provider_options != []} style="display:flex;align-items:flex-start;gap:8px;">
        <span class="mono-label" style="width:74px;flex-shrink:0;padding-top:3px;">provider</span>
        <div id="pin-provider-options" style="flex:1;min-width:0;display:flex;flex-wrap:wrap;gap:8px;">
          <span
            :for={{key, value} <- @provider_options}
            class="font-mono"
            style="font-size:12px;color:var(--tx-2);white-space:nowrap;"
          >
            {key}={value}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # History

  defp pin_count_label(deployment) do
    case pin_count(deployment) do
      1 -> "1 prompt"
      n -> "#{n} prompts"
    end
  end

  @doc "Revision history row: select (patch) and rollback (confirmation modal patch)."
  attr :deployment, :map, required: true
  attr :model_index, :map, required: true
  attr :live?, :boolean, default: false
  attr :selected?, :boolean, default: false
  attr :select_patch, :string, required: true
  attr :rollback_patch, :string, default: nil
  attr :committer, :string, default: "—"

  def revision_row(assigns) do
    ~H"""
    <div
      id={"revision-#{@deployment.revision}"}
      class="card2"
      style={
        DS.style_list([
          "padding:9px 11px;display:flex;align-items:center;gap:10px;",
          if(@selected?,
            do: "border-color:var(--line-3);background:var(--bg-3);",
            else: "border-color:var(--line-2);background:var(--bg-2);"
          )
        ])
      }
    >
      <.link
        patch={@select_patch}
        class="font-mono"
        style={"font-size:13.5px;font-weight:600;width:34px;text-decoration:none;color:#{if @live?, do: "var(--ok)", else: "var(--tx-2)"};"}
      >
        {num(@deployment.revision)}
      </.link>
      <DS.badge :if={@live?} tone={:ok} mono style="font-size:10px;">live</DS.badge>
      <span
        class="font-mono"
        style="font-size:12px;color:var(--tx-2);white-space:nowrap;min-width:0;overflow:hidden;text-overflow:ellipsis;"
      >
        {model_label(@deployment, @model_index)} · {pin_count_label(@deployment)}
      </span>
      <span style="flex:1;min-width:0;font-size:12.5px;color:var(--tx-3);overflow-wrap:anywhere;">
        {@committer}
      </span>
      <span class="font-mono" style="font-size:12px;color:var(--tx-3);white-space:nowrap;">
        {when_label(@deployment)}
      </span>
      <DS.btn_link
        :if={@rollback_patch}
        id={"rollback-to-#{@deployment.revision}"}
        size="sm"
        variant="ghost"
        icon="rerun"
        patch={@rollback_patch}
      >
        Rollback
      </DS.btn_link>
    </div>
    """
  end
end
