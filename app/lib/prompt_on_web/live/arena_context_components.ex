defmodule PromptOnWeb.ArenaContextComponents do
  @moduledoc """
  Arena context inspection surfaces.

  These components are deliberately display-only. The LiveView owns URL state, authorization,
  loading, and application of values; this module keeps the modal markup and snapshot formatting in
  one place.
  """

  use PromptOnWeb, :html

  attr :rows, :list, default: []
  attr :selected_id, :string, default: nil
  attr :preview, :map, default: nil
  attr :error, :string, default: nil
  attr :close_patch, :string, required: true
  attr :integration_patch, :string, required: true

  def log_picker(assigns) do
    assigns =
      assigns
      |> assign(:apply_disabled?, apply_disabled?(assigns.preview))
      |> assign(:preview_values, get_in(assigns.preview || %{}, [:values]) || %{})
      |> assign(:preview_missing, get_in(assigns.preview || %{}, [:missing]) || [])
      |> assign(:preview_ignored, get_in(assigns.preview || %{}, [:ignored]) || 0)

    ~H"""
    <DS.modal
      id="arena-log-modal"
      on_close={@close_patch}
      width={760}
      title="Load from logs"
      icon="database"
    >
      <div
        class="grid grid-cols-1 sm:grid-cols-[minmax(220px,280px)_minmax(0,1fr)]"
        style="gap:12px;min-height:240px;"
      >
        <div class="card2" style="overflow:hidden;display:flex;flex-direction:column;min-height:0;">
          <div class="hair-b" style="padding:9px 11px;font-size:12.5px;color:var(--tx-2);">
            Monitoring calls
          </div>

          <div
            :if={@rows == []}
            style="padding:14px 12px;font-size:12.5px;line-height:1.55;color:var(--tx-3);"
          >
            Connect monitoring and retain <span class="font-mono">input.variables</span>
            to load real values into Arena.
            <.link patch={@integration_patch} style="color:var(--link);text-decoration:none;">
              Connect monitoring
            </.link>
          </div>

          <div :if={@rows != []} style="overflow:auto;min-height:0;max-height:360px;">
            <.link
              :for={row <- @rows}
              id={"arena-log-#{row.id}"}
              patch={row.patch}
              style={log_row_style(to_string(row.id) == to_string(@selected_id))}
            >
              <span
                class="font-mono"
                style="font-size:12px;color:var(--tx-0);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
              >
                {row.model || "unknown model"}
              </span>
              <span style="font-size:11.5px;color:var(--tx-3);display:flex;gap:7px;align-items:center;">
                <span>{format_time(row.started_at)}</span>
                <span>{row.status || "unknown"}</span>
              </span>
            </.link>
          </div>
        </div>

        <div style="min-width:0;display:flex;flex-direction:column;gap:10px;">
          <div :if={@error} class="card2" style="padding:10px 12px;border-color:rgba(255,32,71,.30);">
            <div style="display:flex;align-items:center;gap:6px;font-size:12.5px;color:var(--err);">
              <DSIcons.icon name="alert" size={13} />
              {@error}
            </div>
            <div style="font-size:12px;color:var(--tx-3);line-height:1.55;margin-top:4px;">
              The selected log is unavailable or its retained input variables cannot be loaded.
            </div>
          </div>

          <div
            :if={@preview == nil and @error == nil}
            class="card2"
            style="padding:18px 14px;text-align:center;color:var(--tx-3);font-size:12.5px;line-height:1.55;"
          >
            Select a monitoring call to preview the variables Arena can import.
          </div>

          <div :if={@preview} class="card2" style="overflow:hidden;min-width:0;">
            <div class="hair-b" style="padding:9px 11px;display:flex;align-items:center;gap:8px;">
              <span style="font-size:13px;font-weight:500;color:var(--tx-0);">Variables preview</span>
              <span
                :if={@preview_ignored > 0}
                style="margin-left:auto;font-size:11.5px;color:var(--tx-3);"
              >
                {@preview_ignored} other variables ignored
              </span>
            </div>
            <div style="padding:10px 11px;display:flex;flex-direction:column;gap:9px;">
              <div style="max-height:240px;overflow:auto;background:var(--bg-1);border:1px solid var(--line-2);border-radius:var(--r);padding:9px 10px;">
                <DS.code_block text={json(@preview_values)} size={12} wrap={false} />
              </div>
              <div
                :if={@preview_missing != []}
                style="font-size:12px;color:var(--tx-3);line-height:1.55;"
              >
                Missing declared variables: <span class="font-mono">{Enum.join(@preview_missing, ", ")}</span>.
                Your current values for these variables will be kept.
              </div>
              <div
                :if={@preview_values == %{}}
                style="font-size:12px;color:var(--warn);line-height:1.55;"
              >
                This log has no variables matching the current prompt schema.
              </div>
            </div>
          </div>
        </div>
      </div>

      <:footer>
        <DS.btn_link id="arena-cancel-log" variant="ghost" patch={@close_patch} class="ml-auto">
          Cancel
        </DS.btn_link>
        <DS.btn
          id="arena-apply-log"
          variant="primary"
          icon="check"
          phx-click="arena_apply_log"
          phx-value-id={@selected_id}
          disabled={@apply_disabled?}
        >
          Apply variables
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end

  attr :context, :map, default: nil
  attr :error, :string, default: nil
  attr :close_patch, :string, required: true

  def input_inspector(assigns) do
    assigns =
      assigns
      |> assign(:prompt, nested(assigns.context, "prompt"))
      |> assign(:model, nested(assigns.context, "model"))

    ~H"""
    <DS.modal id="arena-input-modal" on_close={@close_patch} width={800} title="Input used" icon="eye">
      <div :if={@error} class="card2" style="padding:10px 12px;border-color:rgba(255,32,71,.30);">
        <div style="display:flex;align-items:center;gap:6px;font-size:12.5px;color:var(--err);">
          <DSIcons.icon name="alert" size={13} />
          {@error}
        </div>
      </div>

      <div
        :if={@context == nil and @error == nil}
        class="card2"
        style="padding:18px 14px;text-align:center;color:var(--tx-3);font-size:12.5px;line-height:1.55;"
      >
        Input context was not recorded for this turn.
      </div>

      <div :if={@context} style="display:flex;flex-direction:column;gap:10px;">
        <div
          class="card2 grid grid-cols-1 sm:grid-cols-3"
          style="padding:10px 12px;gap:10px;"
        >
          <.fact label="Prompt" value={prompt_title(@prompt)} />
          <.fact label="Model" value={model_title(@model)} />
          <.fact label="Engine" value={value(@context, "engine")} />
        </div>

        <div
          :if={value(@context, "render_error")}
          class="card2"
          style="padding:10px 12px;border-color:rgba(255,32,71,.30);"
        >
          <div style="font-size:12.5px;color:var(--err);line-height:1.55;">
            {value(@context, "render_error")}
          </div>
        </div>

        <DS.collapsible id="arena-input-variables" label="variables" icon="variable" open>
          <.code_panel text={json(value(@context, "variables") || %{})} />
        </DS.collapsible>

        <DS.collapsible id="arena-input-rendered" label="rendered request" icon="send" open>
          <.code_panel text={json(value(@context, "messages") || [])} />
        </DS.collapsible>

        <DS.collapsible id="arena-input-template" label="template messages" icon="code">
          <.code_panel text={json(value(@context, "template_messages") || [])} />
        </DS.collapsible>

        <DS.collapsible id="arena-input-params" label="model settings" icon="sliders">
          <div class="grid grid-cols-1 sm:grid-cols-2" style="gap:10px;">
            <.code_panel title="Params" text={json(value(@context, "params") || %{})} />
            <.code_panel
              title="Provider options"
              text={json(value(@context, "provider_options") || %{})}
            />
          </div>
        </DS.collapsible>
      </div>
    </DS.modal>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, default: nil

  defp fact(assigns) do
    ~H"""
    <div style="min-width:0;">
      <div class="mono-label" style="margin-bottom:3px;">{@label}</div>
      <div
        class="font-mono"
        style="font-size:12.5px;color:var(--tx-0);overflow-wrap:anywhere;"
      >
        {@value || "—"}
      </div>
    </div>
    """
  end

  attr :title, :string, default: nil
  attr :text, :string, required: true

  defp code_panel(assigns) do
    ~H"""
    <div style="min-width:0;">
      <div :if={@title} class="mono-label" style="margin-bottom:5px;">{@title}</div>
      <div style="max-height:260px;overflow:auto;background:var(--bg-1);border:1px solid var(--line-2);border-radius:var(--r);padding:9px 10px;">
        <DS.code_block text={@text} size={12} wrap={false} />
      </div>
    </div>
    """
  end

  defp apply_disabled?(nil), do: true

  defp apply_disabled?(preview),
    do: (value(preview, :values) || value(preview, "values") || %{}) == %{}

  defp log_row_style(selected?) do
    [
      "display:flex;flex-direction:column;gap:3px;padding:9px 11px;text-decoration:none;",
      "border-bottom:1px solid var(--line-2);",
      if(selected?, do: "background:var(--accent-soft);", else: "background:transparent;")
    ]
    |> DS.style_list()
  end

  defp prompt_title(nil), do: "—"

  defp prompt_title(prompt) do
    name = value(prompt, "name") || value(prompt, :name) || "Untitled prompt"

    version =
      case value(prompt, "version_number") || value(prompt, :version_number) do
        nil -> "Draft"
        number -> "v#{number}"
      end

    "#{name} #{version}"
  end

  defp model_title(nil), do: "—"

  defp model_title(model) do
    Enum.find_value(["name", :name, "model_id", :model_id, "id", :id], &value(model, &1)) || "—"
  end

  defp nested(nil, _key), do: nil
  defp nested(map, key) when is_map(map), do: value(map, key) || value(map, String.to_atom(key))

  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key)

  defp json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> encoded
      {:error, _error} -> inspect(value, pretty: true, limit: :infinity)
    end
  end

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp format_time(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp format_time(nil), do: "unknown time"
  defp format_time(value), do: to_string(value)
end
