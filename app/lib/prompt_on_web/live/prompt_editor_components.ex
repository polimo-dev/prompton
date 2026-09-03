defmodule PromptOnWeb.PromptEditorComponents do
  @moduledoc """
  Function components used only by the use case hub screen (`PromptOnWeb.PromptEditorLive`).

  The screen is **one centered column with four tabs** (Editor, Arena, Deployments, Settings).
  Shared pieces such as the shell, buttons and badges live in `PromptOnWeb.DS`; what lives here
  are the pieces that exist **only on this screen**:

  | Component | Place |
  |---|---|
  | `prompt_switcher/1` | Prompt (per-language document) switcher row under the header |
  | `new_prompt_modal/1` | "New prompt" modal (`?new_prompt=1`) |
  | `model_picker_modal/1` | **Search-style model picker** (`?models=1`): multi-select from the project catalog and OpenRouter in one list |
  | `arena_bar/1` | Head of the Arena tab: the selected-model chip row plus "Add models" |
  | `message_card/1` | Message card (role select, char count, Draft with AI, HighlightedEditor) |
  | `version_preview/1` | `?v=` read-only preview plus "Restore this version to draft" |
  | `variables_card/1` | Detected variables chips, schema comparison banner and declaration editor (declare with one click) |
  | `arena/1` | Arena: one pane per model, each pane with a **persistent conversation history**, one shared input below |
  | `versions_drawer/1` | Version list drawer (`?versions=1`): selection patch and diff links |
  | `diff_column/1` | Diff view that replaces the editor when `?diff=` is set |
  | `deploy_modal/1` | Deploy (`?deploy=1`): environment, **version (default = current draft)**, model, commit message |
  | `ai_draft_modal/1` | AIDraftModal (intro → running → done) |

  Selection, diff, drawer and modal targets all arrive as **patch paths** (the CLAUDE.md
  zero-downtime deployment discipline: the URL carries the state).
  """
  use PromptOnWeb, :html

  # AI draft chip. Violet is reserved for AI badges (app.css `--violet`); paint it with a tint and
  # a text color only.
  @accent_chip "display:inline-flex;align-items:center;gap:5px;font-size:12.5px;" <>
                 "color:var(--violet-fg);background:rgba(139,124,246,.12);border:1px solid rgba(139,124,246,.30);" <>
                 "border-radius:var(--r-sm);padding:3px 8px;cursor:pointer;text-decoration:none;"

  @ai_suggestions [
    "Make it more concise",
    "Add output format rules",
    "Strengthen guardrails",
    "Use the variables better"
  ]

  @ai_steps [
    "Analyzing template structure and variables",
    "Checking for vague instructions and missing constraints",
    "Writing the improved draft"
  ]

  @doc "Default suggestion chips of the AI draft modal (mockup copy)."
  @spec ai_suggestions() :: [String.t()]
  def ai_suggestions, do: @ai_suggestions

  # ---------------------------------------------------------------------------
  # Prompt switching

  @doc """
  The prompt switcher row: lays out the named prompt documents under the use case (`default`,
  `ko`, ...) as segments.

  This piece exists so per-language prompts can be handled on screen without the console.
  Switching is a **patch**, so `?prompt=` carries the state (the CLAUDE.md zero-downtime deployment
  discipline). There is no confirmation dialog: every prompt autosaves its own draft, so nothing
  is lost by moving around (ADR 0007 revision 2026-09-01).
  """
  attr :rows, :list,
    required: true,
    doc: "`%{id:, name:, count:, active?:, patch:}` list (the default prompt comes first)"

  attr :new_patch, :string, required: true

  def prompt_switcher(assigns) do
    ~H"""
    <div
      id="prompt-switcher"
      style="display:flex;align-items:center;gap:9px;flex-wrap:wrap;margin-bottom:12px;"
    >
      <span class="mono-label">Prompts</span>
      <div class="seg" style="width:fit-content;">
        <.link
          :for={row <- @rows}
          id={row.id}
          patch={row.patch}
          class={row.active? && "on"}
          style="text-decoration:none;display:inline-flex;align-items:center;gap:6px;"
        >
          <span class="font-mono">{row.name}</span>
          <span :if={row.count} style="font-size:11px;color:var(--tx-3);">{row.count}</span>
        </.link>
      </div>
      <DS.btn_link id="new-prompt" size="sm" variant="ghost" icon="plus" patch={@new_patch}>
        New prompt
      </DS.btn_link>
      <span style="font-size:12px;color:var(--tx-3);">
        one version numbering per prompt — use it for per-language prompts
      </span>
    </div>
    """
  end

  @doc """
  The "New prompt" modal (`?new_prompt=1`). It takes only a name and a description: the name is
  unique per `(use_case, name)`, so a duplicate is rejected and the modal stays open. Creating one
  moves to the new prompt right away, but the current prompt's draft is already saved, so no
  confirmation is asked.
  """
  attr :name, :string, default: ""
  attr :description, :string, default: ""
  attr :close_patch, :string, required: true

  def new_prompt_modal(assigns) do
    ~H"""
    <DS.modal
      id="new-prompt-modal"
      on_close={@close_patch}
      width={420}
      icon="layers"
      title="New prompt"
    >
      <form id="new-prompt-form" phx-change="prompt_change" phx-submit="create_prompt">
        <div class="mono-label" style="margin-bottom:6px;">name</div>
        <DS.ds_input
          id="new-prompt-name"
          name="prompt[name]"
          value={@name}
          placeholder="ko"
          mono
          autocomplete="off"
          phx-debounce="200"
        />
        <div style="font-size:12px;color:var(--tx-3);margin-top:6px;">
          Versions are numbered per prompt — "ko" starts again at v1.
        </div>

        <div class="mono-label" style="margin:14px 0 6px;">description (optional)</div>
        <DS.ds_input
          id="new-prompt-description"
          name="prompt[description]"
          value={@description}
          placeholder="Korean prompt"
          phx-debounce="200"
        />
      </form>

      <:footer>
        <DS.btn_link id="cancel-prompt" variant="ghost" patch={@close_patch} class="ml-auto">
          Cancel
        </DS.btn_link>
        <DS.btn
          id="create-prompt"
          variant="primary"
          icon="plus"
          type="submit"
          form="new-prompt-form"
        >
          Create prompt
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end

  # ---------------------------------------------------------------------------
  # Models (picked first)

  @doc """
  The selected-model row: the chips for the models that become arena columns plus the
  "Add models" button. It is **the head of the Arena tab** (the columns are exactly this row's
  selection, so it has to sit next to the arena).

  A chip's x removes only the column. The history stays, so picking the model again brings the
  past conversation right back (clearing history is the arena's own clear).

  **With no model selected, "Add models" is primary**: the model is the first step of the journey,
  so on an empty screen this button alone should stand out. Once at least one is picked it goes
  back to a quiet outline.

  A **red warning** (`#no-model-warning`) also sits on the same row. The arena's empty CTA lives
  in the column area and gets pushed below the row, so the fact that there is no model is repeated
  at the place where models are picked. It disappears once there is at least one model.
  """
  attr :models, :list, default: [], doc: "`%{id:, name:, model_id:}` list"
  attr :add_patch, :string, required: true

  def arena_bar(assigns) do
    ~H"""
    <div id="arena-models" style="display:flex;flex-wrap:wrap;gap:6px;align-items:center;">
      <span class="mono-label">Models</span>
      <span
        :for={model <- @models}
        id={"arena-model-chip-#{model.id}"}
        style={chip_style()}
        title={model.model_id}
      >
        <span class="font-mono" style="font-size:11.5px;">{model.name}</span>
        <button
          id={"remove-arena-model-#{model.id}"}
          type="button"
          phx-click="remove_arena_model"
          phx-value-model={model.id}
          title="Remove column"
          style="background:none;border:none;padding:0;color:inherit;cursor:pointer;line-height:1;"
        >
          <DSIcons.icon name="x" size={11} />
        </button>
      </span>
      <DS.btn_link
        id="open-model-picker"
        size="sm"
        variant={if @models == [], do: "primary", else: "outline"}
        icon="plus"
        patch={@add_patch}
      >
        Add models
      </DS.btn_link>
      <span
        :if={@models == []}
        id="no-model-warning"
        style="display:inline-flex;align-items:center;gap:5px;font-size:12.5px;color:var(--err);"
      >
        <DSIcons.icon name="alert" size={12} />
        No model selected — add at least one to test this prompt.
      </span>
    </div>
    """
  end

  @doc """
  The search-style model picker (`?models=1`).

  One search box scans **the project catalog and the public OpenRouter list together** (it is not
  a dropdown: there are hundreds of model names, so they are searched for rather than picked from
  a list). Results are checkboxes, so several are picked at once. Models already in the arena
  cannot be toggled.

  A model that was removed from the arena but **still has a conversation** gets a `has history`
  marker. Columns exist only for selected models, so the fact that picking the model again brings
  the past conversation back has to be said before it is picked.

  Each row carries the **price per million tokens** (input / output) on the right: half of the
  reason for choosing a model is its price, so it must be visible while scanning the list. Unknown
  is `—` (`price_label/1`).

  Next to the search box stands a **sort segment** (Relevance, Cheapest, Newest, Context). The
  chosen sort is carried by the URL as `?msort=` (the CLAUDE.md zero-downtime deployment
  discipline), so what is received here is a **patch path**, not an event. Relevance is the
  grouped order used so far (project catalog → OpenRouter); the other three **interleave the two
  sources into one list**, because comparing prices across separate groups makes the sort lie.

  Without a provider key, Add is blocked and only a **link to the organization settings** is
  given: keys are owned by the organization (2026-09-01), so they are not something to collect
  inside a project screen, and the one place to enter them is `/{org}/settings?tab=providers`.
  """
  attr :query, :string, default: ""

  attr :rows, :list,
    default: [],
    doc:
      "`%{value:, dom_id:, name:, model_id:, price:, source:, selected?:, history?:, checked?:}` (in sorted order)"

  attr :picks, :list, default: []

  attr :sort_options, :list,
    default: [],
    doc: "sort segment: `%{value:, label:, patch:, active?:}` list (`?msort=`)"

  attr :catalog_state, :any, default: nil, doc: "`nil | :loading | :loaded | {:error, reason}`"
  attr :provider_key, :any, default: nil
  attr :truncated, :integer, default: 0, doc: "number of results cut off (hidden when 0)"
  attr :close_patch, :string, required: true

  attr :providers_path, :string,
    required: true,
    doc: "the Provider Keys tab of the organization settings"

  def model_picker_modal(assigns) do
    assigns = assign(assigns, :blocked, picker_blocker(assigns))

    ~H"""
    <DS.modal
      id="model-picker-modal"
      on_close={@close_patch}
      width={620}
      icon="search"
      title="Add models"
    >
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
        <form
          id="model-search-form"
          phx-change="model_search"
          phx-submit="model_search"
          style="flex:1 1 240px;min-width:0;"
        >
          <DS.ds_input
            id="model-search"
            name="picker[q]"
            value={@query}
            placeholder="Search by name or id — gpt, claude, llama…"
            w="100%"
            mono
            autocomplete="off"
            phx-debounce="200"
          />
        </form>
        <div id="model-sort" class="seg" style="flex:0 0 auto;width:fit-content;">
          <.link
            :for={option <- @sort_options}
            id={"model-sort-#{option.value}"}
            patch={option.patch}
            class={option.active? && "on"}
            style="text-decoration:none;"
          >
            {option.label}
          </.link>
        </div>
      </div>

      <div :if={@catalog_state == :loading} id="model-picker-loading" style={hint_style(6)}>
        Loading the OpenRouter catalog…
      </div>
      <div :if={catalog_error(@catalog_state)} id="model-picker-catalog-error" style={hint_style(6)}>
        {catalog_error(@catalog_state)}
        <button
          id="model-picker-retry"
          type="button"
          phx-click="retry_model_catalog"
          style="background:none;border:none;padding:0;font:inherit;color:var(--link);cursor:pointer;"
        >
          Retry
        </button>
      </div>

      <div
        id="model-picker-results"
        class="card2"
        style="margin-top:9px;max-height:280px;overflow-y:auto;padding:2px 0;"
      >
        <label
          :for={row <- @rows}
          id={"pick-row-#{row.dom_id}"}
          style="display:flex;align-items:center;gap:8px;padding:6px 10px;cursor:pointer;"
        >
          <input
            type="checkbox"
            id={"pick-#{row.dom_id}"}
            checked={row.checked? or row.selected?}
            disabled={row.selected?}
            phx-click="toggle_model_pick"
            phx-value-pick={row.value}
            style="accent-color:var(--accent);"
          />
          <span style="min-width:0;flex:1;">
            <span style="font-size:12.5px;color:var(--tx-1);display:block;">{row.name}</span>
            <span class="font-mono" style="font-size:11px;color:var(--tx-3);">{row.model_id}</span>
          </span>
          <span
            id={"pick-price-#{row.dom_id}"}
            class="font-mono"
            title="input / output price per 1M tokens"
            style="font-size:11px;color:var(--tx-3);text-align:right;white-space:nowrap;"
          >
            {row.price}
          </span>
          <DS.badge :if={row.source == :catalog} tone={:neutral} mono>openrouter</DS.badge>
          <DS.badge :if={row.selected?} tone={:ok} mono>added</DS.badge>
          <span
            :if={row.history?}
            id={"pick-history-#{row.dom_id}"}
            title="This model still has a conversation — adding it back brings the column with its history."
            style="font-size:10.5px;color:var(--tx-3);white-space:nowrap;"
          >
            has history
          </span>
        </label>
        <div
          :if={@rows == []}
          id="model-picker-empty"
          style="padding:10px;font-size:12.5px;color:var(--tx-3);"
        >
          No model matches this search.
        </div>
      </div>
      <div :if={@truncated > 0} id="model-picker-truncated" style={hint_style(6)}>
        {@truncated} more — keep typing to narrow it down.
      </div>

      <div
        :if={@provider_key}
        id="picker-key-ok"
        style="display:flex;align-items:center;gap:6px;margin-top:11px;font-size:12px;color:var(--tx-2);"
      >
        <DSIcons.icon name="key" size={12} style="color:var(--ok);" />
        <span>OpenRouter key</span>
        <span class="font-mono" style="color:var(--tx-1);">{@provider_key.secret_hint}</span>
        <span>connected</span>
      </div>

      <div :if={is_nil(@provider_key)} id="picker-no-key" style="margin-top:11px;">
        <.schema_banner id="picker-no-key-banner" tone={:warn} icon="key">
          No OpenRouter key in this organization — models can be added, but nothing can run.
        </.schema_banner>
        <div style="margin-top:9px;">
          <DS.btn_link
            id="picker-providers-link"
            variant="primary"
            icon="key"
            navigate={@providers_path}
          >
            Add a provider key in Organization settings
          </DS.btn_link>
        </div>
        <div style={hint_style(5)}>
          Provider keys belong to the organization — every project in it shares them.
        </div>
      </div>

      <:footer>
        <span id="model-picker-count" style="font-size:12.5px;color:var(--tx-2);margin-right:auto;">
          {length(@picks)} selected
        </span>
        <DS.btn_link id="model-picker-cancel" variant="ghost" patch={@close_patch}>Cancel</DS.btn_link>
        <DS.btn
          id="add-models"
          variant="primary"
          icon="plus"
          phx-click="add_models"
          disabled={@blocked != nil}
          title={@blocked}
        >
          Add
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end

  # Only one blocking reason: telling what to fix, in order, beats a list.
  # **Models can be added without a key**: what is blocked is running, and the arena says so.
  defp picker_blocker(%{picks: []}), do: "Pick at least one model."
  defp picker_blocker(_assigns), do: nil

  # ---------------------------------------------------------------------------
  # Price display (picker rows, arena column heads)

  @doc """
  One line of model pricing: `"$3.00 / $15.00 per 1M"` (input / output, per million tokens).

  It accepts either the `pricing` of `PromptOn.Catalog.Model` (string keys) or the `pricing` of
  `PromptOnWeb.ProviderCatalog` (atom keys). **When both are unknown it is `"—"`**, and when only
  one is known just the unknown side is `—`: writing an unknown price as 0 makes the screen lie
  that the model is "free".

      iex> PromptOnWeb.PromptEditorComponents.price_label(%{"input_per_m" => 3, "output_per_m" => 15})
      "$3.00 / $15.00 per 1M"

      iex> PromptOnWeb.PromptEditorComponents.price_label(%{input_per_m: 0.15, output_per_m: nil})
      "$0.15 / — per 1M"

      iex> PromptOnWeb.PromptEditorComponents.price_label(%{})
      "—"
  """
  @spec price_label(map() | nil) :: String.t()
  def price_label(pricing) do
    pricing = PromptOnSDK.Params.stringify_keys(pricing)
    input = rate(pricing["input_per_m"])
    output = rate(pricing["output_per_m"])

    if is_nil(input) and is_nil(output),
      do: "—",
      else: "#{format_rate(input)} / #{format_rate(output)} per 1M"
  end

  @doc """
  One price per million tokens. `nil` → `—`, 0 → `$0`, one cent and above gets two decimals,
  below that up to three significant digits (trailing zeros trimmed): rounding to `$0.00` would
  make a cheap model look free.

      iex> PromptOnWeb.PromptEditorComponents.format_rate(2.5)
      "$2.50"

      iex> PromptOnWeb.PromptEditorComponents.format_rate(0.0015)
      "$0.0015"

      iex> PromptOnWeb.PromptEditorComponents.format_rate(0)
      "$0"

      iex> PromptOnWeb.PromptEditorComponents.format_rate(nil)
      "—"
  """
  @spec format_rate(number() | Decimal.t() | nil) :: String.t()
  def format_rate(value) do
    case rate(value) do
      nil -> "—"
      f when f == 0 -> "$0"
      f when f >= 0.01 -> "$" <> :erlang.float_to_binary(f, decimals: 2)
      f -> "$" <> trim_zeros(:erlang.float_to_binary(f, decimals: sub_cent_decimals(f)))
    end
  end

  @doc """
  One price as a **number for sorting and comparison**. It uses the same interpretation as what
  `price_label/1` shows on screen, so a value that displays as "—" is `nil` ("unknown") here too:
  if the screen and the sort saw different values, the head of a cheapest-first list would be `—`.

      iex> PromptOnWeb.PromptEditorComponents.price_rate("0.15")
      0.15

      iex> PromptOnWeb.PromptEditorComponents.price_rate("-1")
      nil
  """
  @spec price_rate(number() | Decimal.t() | String.t() | nil) :: float() | nil
  def price_rate(value), do: rate(value)

  # Negative and non-numeric values fold into "unknown" (OpenRouter's `"-1"` = dynamic pricing).
  defp rate(%Decimal{} = d), do: d |> Decimal.to_float() |> rate()
  defp rate(n) when is_number(n) and n >= 0, do: n * 1.0

  defp rate(n) when is_binary(n) do
    case Float.parse(n) do
      {f, ""} -> rate(f)
      _other -> nil
    end
  end

  defp rate(_value), do: nil

  # The number of decimals that yields three significant digits (0.005 → 5 → "0.00500").
  defp sub_cent_decimals(f), do: min(2 - floor(:math.log10(f)), 10)

  defp trim_zeros(text) do
    if String.contains?(text, "."),
      do: text |> String.replace(~r/0+$/, "") |> String.replace(~r/\.$/, ""),
      else: text
  end

  # ---------------------------------------------------------------------------
  # Prompt (editor column)

  @doc """
  One message card. The names (`editor[messages][i][role|content]`) are the contract for form
  recovery, so the index is carried **in both the DOM id and the name**.
  """
  attr :index, :integer, required: true
  attr :message, :map, required: true

  attr :roles, :list,
    required: true,
    doc: "role select candidates (`[\"text\"]` for `kind :text`)"

  attr :removable?, :boolean, default: false
  attr :ai_patch, :string, required: true

  def message_card(assigns) do
    assigns = assign(assigns, :min_height, min_height(assigns.message.role))

    ~H"""
    <div id={"message-#{@index}"} class="card2" style="overflow:hidden;">
      <div class="hair-b" style="padding:7px 10px;display:flex;align-items:center;gap:8px;">
        <DS.ds_select
          id={"message-#{@index}-role"}
          name={"editor[messages][#{@index}][role]"}
          value={@message.role}
          options={@roles}
          w={104}
          mono
        />
        <span class="font-mono" style="font-size:11px;color:var(--tx-3);">
          {String.length(@message.content)} ch
        </span>
        <span style="margin-left:auto;display:flex;align-items:center;gap:2px;">
          <.link id={"message-#{@index}-ai"} patch={@ai_patch} class="tr" style={accent_chip()}>
            <DSIcons.icon name="sparkles" size={12} /> Draft with AI
          </.link>
          <DS.icon_btn
            :if={@removable?}
            id={"message-#{@index}-remove"}
            name="trash"
            size={24}
            type="button"
            title="Remove message"
            phx-click="remove_message"
            phx-value-index={@index}
          />
        </span>
      </div>
      <DS.highlighted_editor
        id={"message-#{@index}-content"}
        name={"editor[messages][#{@index}][content]"}
        value={@message.content}
        min_height={@min_height}
        phx-debounce="300"
      />
    </div>
    """
  end

  defp min_height("system"), do: 150
  defp min_height(_role), do: 110

  # Helper so the mockup's `@accent_chip` constant is used as a module attribute instead of being
  # passed through assigns.
  defp accent_chip, do: @accent_chip

  @doc """
  The `?v=<n>` preview: the **read-only** view of that version (ADR 0007 revision 2026-09-01).
  What is edited is always the draft and versions are immutable, so there is not a single input
  here.

  The only write action is **Restore this version to draft**: it overwrites the draft with this
  version's content and returns to editing (no new version is born; only Deploy mints versions).
  """
  attr :number, :integer, required: true
  attr :messages, :list, required: true, doc: "`%{role:, content:}` list (that version's content)"
  attr :commit_message, :string, default: nil
  attr :draft_patch, :string, required: true

  def version_preview(assigns) do
    ~H"""
    <div id="version-preview" style="display:flex;flex-direction:column;gap:10px;min-width:0;">
      <div
        id="version-preview-bar"
        class="card2"
        style="display:flex;align-items:center;gap:9px;flex-wrap:wrap;padding:9px 11px;"
      >
        <DS.badge tone={:accent} mono>v{@number}</DS.badge>
        <span style="font-size:12.5px;color:var(--tx-2);min-width:0;">
          Read only — {@commit_message || "no commit message"}
        </span>
        <span style="margin-left:auto;display:flex;align-items:center;gap:6px;">
          <DS.btn
            id="restore-version"
            size="sm"
            variant="outline"
            icon="history"
            type="button"
            phx-click="restore_version"
          >
            Restore this version to draft
          </DS.btn>
          <DS.btn_link id="back-to-draft" size="sm" variant="ghost" icon="x" patch={@draft_patch}>
            Back to draft
          </DS.btn_link>
        </span>
      </div>

      <div
        :for={{message, index} <- Enum.with_index(@messages)}
        id={"preview-message-#{index}"}
        class="card2"
        style="overflow:hidden;"
      >
        <div class="hair-b" style="padding:7px 10px;display:flex;align-items:center;gap:8px;">
          <DS.badge tone={DS.role_tone(message.role)} mono>{message.role}</DS.badge>
          <span class="font-mono" style="font-size:11px;color:var(--tx-3);">
            {String.length(message.content)} ch
          </span>
        </div>
        <pre style="margin:0;padding:10px;font-size:12.5px;line-height:1.55;white-space:pre-wrap;word-break:break-word;color:var(--tx-1);">{message.content}</pre>
      </div>
    </div>
    """
  end

  @doc """
  The diff column. It compares the chosen version (`?diff=`) with **what is being viewed right
  now**, message index by message index: the version being previewed while `?v=` is set,
  otherwise the current draft.
  """
  attr :from_messages, :list, required: true
  attr :to_messages, :list, required: true
  attr :from_number, :integer, required: true

  attr :to_label, :string,
    required: true,
    doc: "name of the comparison target: `\"v3\"` or `\"draft\"`"

  attr :close_patch, :string, required: true

  def diff_column(assigns) do
    ~H"""
    <div id="diff-view" style="display:flex;flex-direction:column;gap:10px;">
      <div style="display:flex;align-items:center;gap:8px;">
        <span class="mono-label">Diff v{@from_number} → {@to_label}</span>
        <DS.btn_link
          id="close-diff"
          size="sm"
          variant="ghost"
          icon="x"
          patch={@close_patch}
          style="margin-left:auto;"
        >
          Close diff
        </DS.btn_link>
      </div>
      <div :for={{m, i} <- Enum.with_index(@to_messages)} id={"diff-message-#{i}"}>
        <div style="display:flex;align-items:center;gap:7px;margin-bottom:5px;">
          <DS.badge tone={DS.role_tone(m.role)} mono>{m.role}</DS.badge>
        </div>
        <DS.diff_view from={content_at(@from_messages, i)} to={m.content} />
      </div>
    </div>
    """
  end

  defp content_at(messages, index) do
    case Enum.at(messages, index) do
      %{content: content} when is_binary(content) -> content
      _other -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # Versions drawer

  @doc """
  The version list drawer (`?versions=1`). The small version button in the header opens it: the
  screen is one centered column, so the version list is not kept open all the time but pulled out
  from the side when needed.

  The top row is **draft**: the autosaved editing target, with the immutable versions minted by
  Deploy below it. The whole row is a selection patch link, and rows that are not selected carry
  a diff patch icon button. There is no confirmation dialog: the draft is already saved, so
  nothing is lost wherever you move.

  Versions have **no status** (ADR 0007): instead of a badge, only rows whose `live_in` is
  non-empty get a `live` marker. It is the *fact* that the live deployment of that environment
  targets this version, not a status.
  """
  attr :rows, :list,
    required: true,
    doc:
      "`%{number:, live_in:, commit_message:, inserted_at:, selected?:, patch:, diff_patch:, diff_title:}`"

  attr :draft_patch, :string, required: true
  attr :draft_selected?, :boolean, default: true
  attr :close_patch, :string, required: true

  def versions_drawer(assigns) do
    ~H"""
    <DS.drawer
      id="versions-drawer"
      on_close={@close_patch}
      width={420}
      title="Versions"
      sub="The draft autosaves — Deploy mints an immutable version"
    >
      <div id="versions-list" class="card2" style="overflow:hidden;">
        <div
          id="version-row-draft"
          class={["tr", @draft_selected? && "is-selected"]}
          style={
            DS.style_list([
              "display:flex;align-items:center;gap:8px;padding:9px 11px;",
              if(@draft_selected?, do: "background:var(--bg-3);", else: "background:transparent;")
            ])
          }
        >
          <.link
            id="select-draft"
            patch={@draft_patch}
            style="display:flex;align-items:center;gap:8px;flex:1;min-width:0;text-decoration:none;color:inherit;"
          >
            <span class="font-mono" style="font-size:13.5px;font-weight:600;color:var(--tx-0);">
              draft
            </span>
            <span style="min-width:0;flex:1;">
              <span style="font-size:13px;display:block;">Editing draft</span>
              <span style="font-size:11px;color:var(--tx-3);">autosaved</span>
            </span>
          </.link>
        </div>
        <div
          :for={v <- @rows}
          id={"version-row-#{v.number}"}
          class={["tr", v.selected? && "is-selected"]}
          style={
            DS.style_list([
              "display:flex;align-items:center;gap:8px;padding:9px 11px;",
              "border-top:1px solid var(--line);",
              if(v.selected?, do: "background:var(--bg-3);", else: "background:transparent;")
            ])
          }
        >
          <.link
            id={"select-v#{v.number}"}
            patch={v.patch}
            style="display:flex;align-items:center;gap:8px;flex:1;min-width:0;text-decoration:none;color:inherit;"
          >
            <span class="font-mono" style={version_number_style(v.live_in)}>v{v.number}</span>
            <span style="min-width:0;flex:1;">
              <span style="font-size:13px;display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">
                {v.commit_message || "—"}
              </span>
              <span style="font-size:11px;color:var(--tx-3);">{format_when(v.inserted_at)}</span>
            </span>
          </.link>
          <DS.badge
            :if={v.live_in != []}
            id={"version-live-#{v.number}"}
            tone={:ok}
            mono
            title={"live in #{Enum.join(v.live_in, ", ")}"}
          >
            live
          </DS.badge>
          <DS.icon_btn
            :if={!v.selected?}
            id={"diff-v#{v.number}"}
            name="diff"
            size={22}
            patch={v.diff_patch}
            title={v.diff_title}
          />
        </div>
        <div
          :if={@rows == []}
          id="versions-empty"
          style="padding:11px;font-size:12.5px;color:var(--tx-3);"
        >
          No versions yet — Deploy commits v1.
        </div>
      </div>
    </DS.drawer>
    """
  end

  defp version_number_style([]), do: "font-size:13.5px;font-weight:600;color:var(--tx-1);"
  defp version_number_style(_live_in), do: "font-size:13.5px;font-weight:600;color:var(--ok);"

  @doc "Timestamp notation of the version list (mockup `MM-DD HH:MM`)."
  @spec format_when(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def format_when(nil), do: "—"
  def format_when(%DateTime{} = at), do: Calendar.strftime(at, "%m-%d %H:%M")
  def format_when(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%m-%d %H:%M")

  # ---------------------------------------------------------------------------
  # Variables

  @doc """
  The Detected variables card: detected chips, the schema comparison banner and the
  **declaration editor**.

  `detected` is `%{vars: [name], tags: [tag], bindings: [name]}`, and `vars` comes from
  **`PromptOnSDK.Template.variables/1`** (the same code as `detected_variables` on save, so the
  screen and the backend never disagree).

  ## Declaration finishes where the variable was detected

  A variable chip missing from the schema is a **button**: clicking it declares the variable right
  there as `string`, optional (one click). The banner's "Declare all" does the same for everything
  that is left. Declared variables change type and required in the list below (saved
  immediately), and expanding the collapsed row adds description and example (saved when focus
  leaves). Removal asks no confirmation: only the declaration disappears while the template
  stays, so the chip merely turns red again.

  Each row's form id is stable as `var-row-<name>`, so Phoenix form recovery keeps a description
  or example that was being typed even after a remount (the expanded row is carried by `?var=` in
  the URL).
  """
  attr :detected, :map, required: true

  attr :rows, :list,
    required: true,
    doc:
      "declared variables (`%{name:, type:, required?:, description:, example:, expanded?:, toggle_patch:}`)"

  attr :undeclared, :list, required: true
  attr :unused, :list, required: true
  attr :types, :list, required: true, doc: "type select candidates (`[\"string\", ...]`)"
  attr :new_name, :string, default: ""

  def variables_card(assigns) do
    assigns =
      assign(
        assigns,
        :chips,
        Enum.map(assigns.detected.vars, &%{name: &1, type: declared_type(assigns.rows, &1)})
      )

    ~H"""
    <div>
      <div class="mono-label" style="margin-bottom:7px;">Detected variables</div>
      <div id="detected-variables" class="card2" style="padding:11px;">
        <div style={
          DS.style_list([
            "display:flex;flex-wrap:wrap;gap:5px;",
            if(@detected.tags == [], do: "margin-bottom:0;", else: "margin-bottom:9px;")
          ])
        }>
          <%= for chip <- @chips do %>
            <span
              :if={chip.type}
              id={"var-chip-#{chip.name}"}
              class="chip font-mono"
              style={var_chip_style(chip.type)}
            >
              {chip.name}<span style="color:var(--tx-3);">{var_suffix(chip.type)}</span>
            </span>
            <button
              :if={is_nil(chip.type)}
              id={"var-chip-#{chip.name}"}
              type="button"
              class="chip font-mono"
              style={var_chip_style(nil) <> "font-family:inherit;cursor:pointer;"}
              title="Declare as string"
              phx-click="declare_variable"
              phx-value-name={chip.name}
            >
              {chip.name}<span style="color:var(--tx-3);">{var_suffix(nil)}</span>
              <DSIcons.icon name="plus" size={11} />
            </button>
          <% end %>
          <span :if={@detected.vars == []} style="font-size:12.5px;color:var(--tx-3);">none</span>
        </div>
        <div :if={@detected.tags != []} style="display:flex;flex-wrap:wrap;gap:5px;">
          <span
            :for={t <- @detected.tags}
            class="chip font-mono"
            style="border-color:rgba(139,124,246,.30);color:var(--violet-fg);"
          >
            {tag_label(t)}
          </span>
        </div>
        <div
          :if={@detected.bindings != []}
          style="display:flex;flex-wrap:wrap;gap:5px;margin-top:8px;padding-top:8px;border-top:1px solid var(--line);"
        >
          <span style="font-size:11px;color:var(--tx-3);align-self:center;">loop bindings</span>
          <span
            :for={b <- @detected.bindings}
            class="chip font-mono"
            style="font-size:11px;color:var(--tx-2);"
          >
            {b}
          </span>
        </div>
      </div>

      <.schema_banner
        :if={@undeclared == [] and @unused == []}
        id="schema-ok"
        tone={:ok}
        icon="check2"
      >
        Undeclared in schema: none
      </.schema_banner>
      <.schema_banner :if={@undeclared != []} id="schema-undeclared" tone={:err} icon="alert">
        Undeclared in schema: <span class="font-mono">{Enum.join(@undeclared, ", ")}</span>
        <button id="declare-all" type="button" phx-click="declare_all_variables" style={link_button()}>
          Declare all
        </button>
      </.schema_banner>
      <.schema_banner :if={@unused != []} id="schema-unused" tone={:warn} icon="alert">
        Required variables unused: <span class="font-mono">{Enum.join(@unused, ", ")}</span>
      </.schema_banner>

      <div class="mono-label" style="margin:12px 0 7px;">Input schema</div>
      <div id="declared-variables" class="card2" style="padding:2px 11px 10px;">
        <div :if={@rows == []} style="font-size:12.5px;color:var(--tx-3);padding:9px 0 3px;">
          Nothing declared yet — click a red chip above to declare it.
        </div>

        <form
          :for={row <- @rows}
          id={"var-row-#{row.name}"}
          phx-change="variable_change"
          style="display:flex;flex-direction:column;gap:6px;padding:9px 0;border-bottom:1px solid var(--line);"
        >
          <input type="hidden" name="variable[name]" value={row.name} />
          <div style="display:flex;align-items:center;gap:4px;">
            <span class="font-mono" style={var_name_style()}>{row.name}</span>
            <DS.icon_btn
              id={"var-row-#{row.name}-toggle"}
              name="note"
              size={22}
              patch={row.toggle_patch}
              active={row.expanded?}
              title="Description & example"
            />
            <DS.icon_btn
              id={"var-row-#{row.name}-remove"}
              name="x"
              size={22}
              type="button"
              title="Remove declaration"
              phx-click="remove_variable"
              phx-value-name={row.name}
            />
          </div>
          <div style="display:flex;align-items:center;gap:9px;">
            <DS.ds_select
              id={"var-row-#{row.name}-type"}
              name="variable[type]"
              value={to_string(row.type)}
              options={@types}
              w={98}
              mono
            />
            <label style="display:flex;align-items:center;gap:5px;font-size:12px;color:var(--tx-2);cursor:pointer;">
              <input type="hidden" name="variable[required?]" value="false" />
              <input
                type="checkbox"
                id={"var-row-#{row.name}-required"}
                name="variable[required?]"
                value="true"
                checked={row.required?}
                style="accent-color:var(--accent);"
              /> required
            </label>
          </div>
          <div :if={row.expanded?} style="display:flex;flex-direction:column;gap:6px;">
            <DS.ds_input
              id={"var-row-#{row.name}-description"}
              name="variable[description]"
              value={row.description}
              placeholder="description"
              w="100%"
              phx-debounce="blur"
            />
            <DS.ds_input
              id={"var-row-#{row.name}-example"}
              name="variable[example]"
              value={row.example}
              placeholder="example"
              w="100%"
              phx-debounce="blur"
            />
          </div>
        </form>

        <form
          id="add-variable-form"
          phx-change="add_variable_change"
          phx-submit="add_variable"
          style="display:flex;align-items:center;gap:6px;padding-top:10px;"
        >
          <div style="flex:1;min-width:0;">
            <DS.ds_input
              id="add-variable-name"
              name="variable[name]"
              value={@new_name}
              placeholder="variable_name"
              mono
              w="100%"
              autocomplete="off"
              phx-debounce="200"
            />
          </div>
          <DS.btn id="add-variable" size="sm" variant="ghost" icon="plus" type="submit">Add</DS.btn>
        </form>
      </div>
    </div>
    """
  end

  defp declared_type(declared, name) do
    case Enum.find(declared, &(&1.name == name)) do
      nil -> nil
      variable -> variable.type
    end
  end

  defp var_chip_style(nil), do: "border-color:rgba(255,32,71,.40);color:var(--err);"
  defp var_chip_style(_type), do: "border-color:var(--line-2);color:var(--tx-1);"

  defp var_suffix(nil), do: ":?"
  defp var_suffix(type), do: ":#{type}"

  defp var_name_style,
    do:
      "flex:1;min-width:0;font-size:12.5px;color:var(--tx-1);" <>
        "overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"

  # Lays a button out like a link inside the banner (the banner slot is a one-line `<span>`).
  defp link_button,
    do:
      "margin-left:7px;padding:0;background:none;border:none;font:inherit;" <>
        "color:var(--link);cursor:pointer;text-decoration:underline;"

  # A literal `{%` in a HEEx body collides with interpolation syntax, so it is built as a string.
  defp tag_label(tag), do: "{% " <> tag <> " %}"

  @doc "Schema comparison banner (ok/err/warn)."
  attr :id, :string, required: true
  attr :tone, :atom, required: true, values: [:ok, :err, :warn]
  attr :icon, :string, required: true
  slot :inner_block, required: true

  def schema_banner(assigns) do
    ~H"""
    <div id={@id} style={banner_style(@tone)}>
      <DSIcons.icon name={@icon} size={13} style={"color:#{banner_color(@tone)};margin-top:1px;"} />
      <span style="font-size:12.5px;color:var(--tx-1);line-height:1.5;">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  defp banner_style(tone) do
    {bg, bd} =
      case tone do
        :ok -> {"rgba(17,255,153,.07)", "rgba(17,255,153,.26)"}
        :err -> {"rgba(255,32,71,.08)", "rgba(255,32,71,.30)"}
        :warn -> {"rgba(255,197,61,.08)", "rgba(255,197,61,.30)"}
      end

    "display:flex;align-items:flex-start;gap:7px;margin-top:8px;padding:8px 10px;" <>
      "border-radius:var(--r);background:#{bg};border:1px solid #{bd};"
  end

  defp banner_color(:ok), do: "var(--ok)"
  defp banner_color(:err), do: "var(--err)"
  defp banner_color(:warn), do: "var(--warn)"

  # ---------------------------------------------------------------------------
  # Arena

  @doc """
  The arena: one pane per selected model, and **a single send goes to every pane at once**.

  A pane's content is not session state but the **persistent history** of `(use case × model)`
  (`PromptOn.Prompts.ArenaMessage`). Leaving the screen and coming back shows the past inputs and
  responses as they were, and editing the prompt does not erase them (a quiet one-liner merely
  says "from the next turn on, the new prompt is used").

  - `kind :chat`: the panes share the one input box below. Sending appends the same user turn to
    every pane, and the answers accumulate separately.
  - `kind :text`: single-shot. Pressing Run yields **one last output** per pane (the history keeps
    accumulating).

  Each pane has its own clear (that model's column only), and "Clear history" above empties this
  use case's history wholesale.

  **With no model at all** there are neither panes nor an input box: only the centered CTA
  (`#arena-empty-cta`) remains, and it opens the picker. Saying the one next thing to do, loudly,
  beats showing a disabled input box that has nowhere to send to.

  ## One scroll: the panes move together

  With a scroll box per pane, the same turn cannot be read side by side (each pane has to be
  scrolled separately). So there is **one scroll box, `#arena-scroll`**, wrapping the whole column
  strip: scrolling vertically moves every pane together, and the horizontal scroll when columns
  overflow is handled by the same box. The autoscroll hook is attached to this one box only.

  - Its height is based on the **viewport**, not pixels (`min(64vh, calc(100vh - 320px))`): a
    bigger screen shows more history. In full screen it takes all the remaining height with
    `flex:1`.
  - The column head (model name, price) is `position:sticky`, so scrolling never loses track of
    which pane is being read. Its background must be an opaque `var(--bg-2)`: if bubbles show
    through, the head becomes a smudge rather than a head.
  - Conversations are bottom-aligned. The strip has `min-height:100%`, so panes stretch to the
    box height, and the `margin-top:auto` on the first child spacer of the body pushes the empty
    space upward: short panes stand on the **same baseline**, and the last turn of every model
    sits on one line (`justify-content:flex-end` clips the top when overflowing and breaks
    scrolling).
  - `.ArenaAutoscroll` scrolls to the bottom on mount, and when a new turn is appended it scrolls
    down again **only if the view was already at the bottom (±40px) right before the patch**. A
    screen scrolled up to read the past conversation must not be hijacked by a new response.

  Turns are bubbles: the user on the right (accent), the model on the left (card background), with
  a small, dim line below carrying version, latency, cost, tokens and time.

  ## Composer and full screen

  The input row (`#arena-send-form`) is a floating card (`.arena-composer`: a `bg-3` ground with
  an accent border on focus). The one line used most often in the arena must not quietly vanish
  at the bottom of the screen.

  Full screen (`?full=1`) lays `#arena-fullscreen-overlay` down as `position:fixed`: a slim header
  (use case key, model chips, close) plus the one scroll box plus the composer. The state is in
  the URL, so even when a deployment drops the socket and remounts the view, it comes back to the
  same screen (the CLAUDE.md zero-downtime deployment discipline). Esc is handled by the colocated
  hook `.ArenaEscape`, which clicks the close link; the overlay itself is `position:fixed`, so the
  screen behind it does not move.
  """
  attr :kind, :atom, required: true, values: [:chat, :text]

  attr :columns, :list,
    default: [],
    doc: """
    `%{id:, label:, model_id:, price:, rows:, running?:}` list.
    `rows` is a `%{key:, role:, content:, status:, error:, version:, at:, latency_ms:, cost_usd:,
    input_tokens:, output_tokens:}` list (oldest first; the bottom is the newest).
    """

  attr :add_patch, :string,
    required: true,
    doc: "patch path that opens the model picker (empty-state CTA)"

  attr :variables, :list, default: [], doc: "`%{name:, type:, required?:, value:}` list"
  attr :variables_open?, :boolean, default: false
  attr :input, :string, default: ""
  attr :running?, :boolean, default: false
  attr :blocked, :string, default: nil
  attr :notice, :string, default: nil
  attr :any_history?, :boolean, default: false
  attr :title, :string, default: nil, doc: "use case key shown in the full-screen slim header"
  attr :full?, :boolean, default: false, doc: "`?full=1`: the full-screen overlay"
  attr :full_patch, :string, default: nil, doc: "patch path that turns full screen on"
  attr :exit_patch, :string, default: nil, doc: "patch path that turns full screen off"

  def arena(assigns) do
    # With no columns there is nothing to go full screen with; the empty CTA stays in its usual
    # place.
    assigns = assign(assigns, :overlay?, assigns.full? and assigns.columns != [])

    ~H"""
    <div :if={not @overlay?} id="arena">
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:7px;">
        <div class="mono-label">{if @kind == :text, do: "Runs", else: "Arena"}</div>
        <div style="margin-left:auto;display:flex;align-items:center;gap:10px;">
          <button
            :if={@any_history?}
            id="clear-arena"
            type="button"
            phx-click="clear_arena"
            data-confirm="Clear the whole conversation history for this use case?"
            style="background:none;border:none;padding:0;font-size:11.5px;color:var(--tx-3);cursor:pointer;"
          >
            Clear history
          </button>
          <DS.btn_link
            :if={@columns != [] and @full_patch}
            id="arena-fullscreen"
            size="sm"
            variant="ghost"
            icon="chevUpDown"
            patch={@full_patch}
            title="Expand the arena to full screen"
          >
            Full screen
          </DS.btn_link>
        </div>
      </div>

      <.arena_variables :if={@variables != []} rows={@variables} open?={@variables_open?} />

      <div :if={@notice} id="arena-notice" style={hint_style(8)}>{@notice}</div>

      <.arena_strip :if={@columns != []} columns={@columns} size={normal_strip_size()} />

      <DS.empty
        :if={@columns == []}
        id="arena-empty-cta"
        class="card2"
        icon="cpu"
        title="No models selected"
        sub={
          if @kind == :text,
            do: "Pick one or more models — every run goes to all of them side by side.",
            else: "Pick one or more models — every message goes to all of them side by side."
        }
      >
        <:action>
          <DS.btn_link id="arena-empty-add" variant="solid" icon="plus" patch={@add_patch}>
            Add models
          </DS.btn_link>
        </:action>
      </DS.empty>

      <.arena_composer
        :if={@columns != []}
        kind={@kind}
        input={@input}
        running?={@running?}
        blocked={@blocked}
        style="margin-top:8px;"
      />
    </div>

    <div
      :if={@overlay?}
      id="arena-fullscreen-overlay"
      phx-hook=".ArenaEscape"
      style="position:fixed;inset:0;z-index:60;background:var(--bg-0);display:flex;flex-direction:column;overflow:hidden;"
    >
      <div
        id="arena-full-header"
        class="hair-b"
        style="flex-shrink:0;display:flex;align-items:center;gap:10px;padding:9px 16px;"
      >
        <span class="font-mono" style="font-size:13px;color:var(--tx-0);white-space:nowrap;">
          {@title}
        </span>
        <span class="mono-label">{if @kind == :text, do: "Runs", else: "Arena"}</span>
        <div style="display:flex;align-items:center;gap:6px;min-width:0;overflow-x:auto;">
          <span
            :for={column <- @columns}
            id={"arena-full-chip-#{column.id}"}
            style={chip_style()}
            title={column.model_id}
          >
            <span class="font-mono" style="font-size:11.5px;white-space:nowrap;">{column.label}</span>
          </span>
        </div>
        <DS.btn_link
          id="arena-exit-full"
          size="sm"
          variant="outline"
          icon="x"
          patch={@exit_patch}
          title="Exit full screen (Esc)"
          style="margin-left:auto;flex-shrink:0;"
        >
          Exit full screen
        </DS.btn_link>
      </div>

      <div style="flex:1;min-height:0;display:flex;flex-direction:column;gap:8px;padding:10px 16px 14px;">
        <div :if={@notice} id="arena-notice" style={hint_style()}>{@notice}</div>
        <.arena_variables :if={@variables != []} rows={@variables} open?={@variables_open?} />
        <.arena_strip columns={@columns} size="flex:1;min-height:0;" />
        <.arena_composer kind={@kind} input={@input} running?={@running?} blocked={@blocked} />
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ArenaAutoscroll">
      export default {
        atBottom() {
          const gap = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
          return gap <= (parseInt(this.el.dataset.threshold || "40", 10) || 40)
        },
        toBottom() { this.el.scrollTop = this.el.scrollHeight },
        mounted() {
          this.stick = true
          this.toBottom()
        },
        beforeUpdate() { this.stick = this.atBottom() },
        updated() { if (this.stick !== false) this.toBottom() }
      }
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ArenaEscape">
      export default {
        mounted() {
          this.onKeydown = (event) => {
            if (event.key !== "Escape") return
            const exit = this.el.querySelector("#arena-exit-full")
            if (!exit) return
            event.preventDefault()
            exit.click()
          }
          window.addEventListener("keydown", this.onKeydown)
        },
        destroyed() { window.removeEventListener("keydown", this.onKeydown) }
      }
    </script>
    """
  end

  # The size of the scroll box. Normally it is the viewport minus the chrome (the 64px screen
  # header, the tab row, the model row, the composer). A fixed 320px height makes the
  # conversation postage-stamp sized on a big screen.
  defp normal_strip_size,
    do: "margin-top:8px;height:min(64vh, calc(100vh - 320px));min-height:240px;"

  attr :rows, :list, required: true
  attr :open?, :boolean, default: false

  defp arena_variables(assigns) do
    ~H"""
    <DS.collapsible id="arena-variables" label="variables" icon="variable" open={@open?}>
      <form id="arena-vars-form" phx-change="arena_vars_change" style="padding:10px 12px;">
        <div style="display:flex;flex-direction:column;gap:7px;">
          <label :for={variable <- @rows} style="display:block;">
            <span style="display:flex;align-items:center;gap:5px;margin-bottom:3px;">
              <span class="font-mono" style="font-size:12px;color:var(--tx-1);">
                {variable.name}
              </span>
              <span style="font-size:10.5px;color:var(--tx-3);">{variable.type}</span>
              <span :if={variable.required?} style="font-size:10.5px;color:var(--tx-1);">
                required
              </span>
            </span>
            <textarea
              id={"arena-var-#{variable.name}"}
              name={"vars[#{variable.name}]"}
              spellcheck="false"
              placeholder={variable.type == :list && "one item per line"}
              class="ed ring-acc"
              style="padding:9px 12px;min-height:40px;display:block;font-size:13px;background:var(--bg-2);border:1px solid var(--line-2);border-radius:var(--r);"
            ><%= variable.value %></textarea>
          </label>
        </div>
      </form>
    </DS.collapsible>
    """
  end

  attr :columns, :list, required: true

  attr :size, :string,
    required: true,
    doc: "size style of the scroll box (viewport height / `flex:1`)"

  defp arena_strip(assigns) do
    ~H"""
    <div
      id="arena-scroll"
      phx-hook=".ArenaAutoscroll"
      data-threshold="40"
      style={"overflow:auto;" <> @size}
    >
      <%!-- The strip stretches to the box height so short panes stand on the baseline too. --%>
      <div id="arena-columns" style="display:flex;align-items:stretch;gap:8px;min-height:100%;">
        <div
          :for={column <- @columns}
          id={"arena-column-#{column.id}"}
          class="card2"
          style="flex:1 1 280px;min-width:280px;display:flex;flex-direction:column;"
        >
          <%!-- The sticky head must be opaque. An overflow:hidden ancestor kills sticky. --%>
          <div
            id={"arena-column-head-#{column.id}"}
            class="hair-b"
            style="position:sticky;top:0;z-index:2;background:var(--bg-2);border-radius:var(--r) var(--r) 0 0;padding:5px 8px;display:flex;align-items:center;gap:6px;"
          >
            <span style="min-width:0;">
              <span
                class="font-mono"
                style="font-size:11.5px;color:var(--tx-1);display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
              >
                {column.label}
              </span>
              <span
                :if={column.price}
                id={"arena-column-price-#{column.id}"}
                class="font-mono"
                title="input / output price per 1M tokens"
                style="font-size:10.5px;color:var(--tx-3);display:block;white-space:nowrap;"
              >
                {column.price}
              </span>
            </span>
            <button
              id={"clear-column-#{column.id}"}
              type="button"
              phx-click="clear_column"
              phx-value-model={column.id}
              data-confirm="Clear this model's history?"
              style="margin-left:auto;background:none;border:none;padding:0;font-size:11px;color:var(--tx-3);cursor:pointer;"
            >
              clear
            </button>
          </div>
          <div
            id={"arena-body-#{column.id}"}
            style="flex:1;display:flex;flex-direction:column;gap:7px;padding:7px 8px;"
          >
            <%!-- A spacer that pushes the empty space upward so messages hug the bottom. A pane
                  with nothing in it has nothing to push, so a centered hint stands in for the
                  spacer. --%>
            <div :if={column.rows != [] or column.running?} style="margin-top:auto;"></div>
            <div
              :for={row <- column.rows}
              id={"arena-row-#{column.id}-#{row.key}"}
              data-role={row.role}
              style={turn_style(row)}
            >
              <div style={bubble_style(row)}>
                <div
                  :if={row.status == :error}
                  style="font-size:12px;color:var(--err);line-height:1.5;"
                >
                  {row.error}
                </div>
                <div
                  :if={row.status != :error}
                  style="font-size:12.5px;color:var(--tx-0);line-height:1.55;white-space:pre-wrap;overflow-wrap:anywhere;"
                >
                  {row.content}
                </div>
                <div :if={turn_meta(row) != []} style={meta_style(row)}>
                  {Enum.join(turn_meta(row), " · ")}
                </div>
              </div>
            </div>
            <div :if={column.running?} id={"arena-running-#{column.id}"} style={hint_style()}>
              running…
            </div>
            <div
              :if={column.rows == [] and not column.running?}
              style={hint_style() <> "margin:auto;text-align:center;"}
            >
              No turns yet.
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :input, :string, default: ""
  attr :running?, :boolean, default: false
  attr :blocked, :string, default: nil
  attr :style, :string, default: nil

  defp arena_composer(assigns) do
    ~H"""
    <form
      id="arena-send-form"
      class="arena-composer"
      phx-change="arena_input_change"
      phx-submit="arena_send"
      style={@style}
    >
      <textarea
        :if={@kind == :chat}
        id="arena-input"
        name="send[input]"
        spellcheck="false"
        placeholder="Message every selected model…"
        class="ed"
        style="flex:1;min-width:0;min-height:44px;font-size:14px;line-height:1.5;padding:2px 2px;display:block;"
      ><%= @input %></textarea>
      <DS.btn
        id="arena-send"
        type="submit"
        variant="primary"
        icon={if @kind == :text, do: "play", else: "send"}
        full={@kind == :text}
        disabled={@blocked != nil or @running?}
      >
        {if @kind == :text, do: "Run", else: "Send"}
      </DS.btn>
    </form>
    <div :if={@blocked} id="arena-blocked" style={hint_style(6)}>{@blocked}</div>
    """
  end

  defp row_meta?(%{role: :assistant, status: :ok}), do: true
  defp row_meta?(_row), do: false

  # User turns on the right, model turns on the left: in a pane, alignment says first who spoke.
  defp turn_style(%{role: :user}), do: "display:flex;justify-content:flex-end;"
  defp turn_style(_row), do: "display:flex;justify-content:flex-start;"

  defp bubble_style(%{role: :user}) do
    "max-width:88%;min-width:0;border-radius:var(--r-lg) var(--r-lg) var(--r-xs) var(--r-lg);padding:6px 8px;" <>
      "background:var(--accent-soft);border:1px solid var(--accent-line);"
  end

  defp bubble_style(_row) do
    "max-width:94%;min-width:0;border-radius:var(--r-lg) var(--r-lg) var(--r-lg) var(--r-xs);padding:6px 8px;" <>
      "background:var(--bg-1);border:1px solid var(--line-2);"
  end

  defp meta_style(%{role: :user}),
    do: "font-size:10.5px;color:var(--tx-3);margin-top:4px;text-align:right;"

  defp meta_style(_row), do: "font-size:10.5px;color:var(--tx-3);margin-top:4px;"

  # The line under a turn: a successful model turn carries version, latency, cost and tokens; the
  # rest carry only the time.
  defp turn_meta(row) do
    meta =
      if row_meta?(row) do
        [
          row.version && "v#{row.version}",
          DS.fmt_ms(row.latency_ms),
          DS.fmt_cost(row.cost_usd),
          "#{DS.fmt_num(row.input_tokens)}/#{DS.fmt_num(row.output_tokens)} tok"
        ]
      else
        []
      end

    Enum.reject(meta ++ [format_clock(Map.get(row, :at))], &is_nil/1)
  end

  defp format_clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
  defp format_clock(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%H:%M")
  defp format_clock(_other), do: nil

  defp chip_style do
    "display:inline-flex;align-items:center;gap:5px;color:var(--tx-0);background:var(--accent-soft);" <>
      "border:1px solid var(--accent-line);border-radius:var(--r-sm);padding:3px 7px;"
  end

  defp hint_style(margin_top \\ 0) do
    "font-size:12px;color:var(--tx-3);line-height:1.55;" <>
      if(margin_top > 0, do: "margin-top:#{margin_top}px;", else: "")
  end

  defp catalog_error({:error, reason}) when is_binary(reason), do: "Catalog: #{reason}"
  defp catalog_error(_state), do: nil

  # ---------------------------------------------------------------------------
  # Deploy

  @doc """
  The Deploy modal (`?deploy=1`). It is the screen's second verb: pick **environment, version and
  model** and commit a new revision to that environment's live deployment (ADR 0007).

  - The environment is a radio (default production). If a deployment already exists, the current
    revision number is shown beside it.
  - The version is a select whose **default is "Current draft"** (ADR 0007 revision 2026-09-01):
    choosing it makes Deploy mint v(N+1) on the spot. Only then does the **commit message field**
    (`#deploy-message`, optional) appear. Choosing a past version mints nothing, so the field
    disappears too.
  - The model is a radio as well. The list is **every active model of this project**; models that
    were tried in the arena come first and carry an `arena` marker (the rest are ordered by
    display name). The arena is where models are chosen, not a gate for deployment.
  - If `default_params` is present, one line says where the parameters come from.
  - **`pins` lists everything this deploy will pin** (ADR 0007 revision 2026-09-01: a revision is
    a pin): for each prompt name of this use case, which version gets pinned, and for a prompt
    with no version at all, the fact that it is not pinned. The prompt currently being edited
    carries a `current` marker.
  """
  attr :envs, :list, required: true, doc: "`%{id:, slug:, name:, checked?:, revision:}` list"
  attr :models, :list, required: true, doc: "`%{id:, label:, arena?:, checked?:}` list"
  attr :version_options, :list, default: [], doc: "`{label, id}` list (newest first)"
  attr :version_value, :string, default: nil

  attr :version_required?, :boolean,
    default: true,
    doc: "`kind :embedding` has no prompt version; false only then"

  attr :default_params, :map, default: %{}

  attr :pins, :list,
    default: [],
    doc:
      "what this deploy will pin: `%{name:, version:, current?:}` list (a nil `version` is not pinned)"

  attr :deployments_patch, :string, required: true
  attr :message, :string, default: ""

  attr :minting?, :boolean,
    default: false,
    doc:
      "whether this Deploy actually creates a new version (= whether the commit message field is shown)"

  attr :close_patch, :string, required: true

  def deploy_modal(assigns) do
    ~H"""
    <DS.modal id="deploy-modal" on_close={@close_patch} title="Deploy" icon="flag">
      <form id="deploy-form" phx-change="deploy_change" phx-submit="deploy">
        <div class="mono-label" style="margin-bottom:6px;">environment</div>
        <div style="display:flex;flex-direction:column;gap:2px;">
          <label
            :for={env <- @envs}
            style="display:flex;align-items:center;gap:8px;padding:6px 2px;cursor:pointer;"
          >
            <input
              type="radio"
              id={"deploy-env-#{env.slug}"}
              name="deploy[environment]"
              value={env.id}
              checked={env.checked?}
            />
            <span class="font-mono" style="font-size:12.5px;color:var(--tx-1);">{env.name}</span>
            <span :if={env.revision} style="font-size:11.5px;color:var(--tx-3);margin-left:auto;">
              now #{env.revision}
            </span>
          </label>
        </div>

        <div :if={@version_required?} class="mono-label" style="margin:12px 0 6px;">
          prompt version
        </div>
        <DS.ds_select
          :if={@version_required? and @version_options != []}
          id="deploy-version"
          name="deploy[version]"
          value={@version_value}
          options={@version_options}
          w="100%"
          mono
        />
        <div
          :if={@version_required? and @version_options == []}
          id="deploy-no-versions"
          style={hint_style()}
        >
          This use case has no prompt yet.
        </div>

        <div :if={@minting?} id="deploy-message-field" style="margin-top:10px;">
          <div class="mono-label" style="margin-bottom:6px;">commit message (optional)</div>
          <DS.ds_input
            id="deploy-message"
            name="deploy[message]"
            value={@message}
            placeholder="What changed?"
            autocomplete="off"
            phx-debounce="300"
          />
        </div>

        <div class="mono-label" style="margin:12px 0 6px;">model</div>
        <div style="display:flex;flex-direction:column;gap:2px;">
          <label
            :for={model <- @models}
            style="display:flex;align-items:center;gap:8px;padding:6px 2px;cursor:pointer;"
          >
            <input
              type="radio"
              id={"deploy-model-#{model.id}"}
              name="deploy[model]"
              value={model.id}
              checked={model.checked?}
            />
            <span
              class="font-mono"
              style="font-size:12.5px;color:var(--tx-1);min-width:0;overflow:hidden;text-overflow:ellipsis;"
            >
              {model.label}
            </span>
            <DS.badge
              :if={model.arena?}
              id={"deploy-model-arena-#{model.id}"}
              tone={:accent}
              mono
              style="margin-left:auto;"
            >
              arena
            </DS.badge>
          </label>
          <div :if={@models == []} id="deploy-no-models" style={hint_style()}>
            No model in this project yet — add one above first.
          </div>
        </div>

        <div :if={@default_params not in [nil, %{}]} id="deploy-params-note" style={hint_style(12)}>
          Params come from this use case's defaults ({params_note(@default_params)}).
        </div>

        <div :if={@pins != []} id="deploy-pins" style="margin-top:12px;">
          <div class="mono-label" style="margin-bottom:6px;">prompts pinned by this deploy</div>
          <div style="display:flex;flex-direction:column;gap:3px;">
            <div
              :for={pin <- @pins}
              id={"deploy-pin-#{pin.name}"}
              style="display:flex;align-items:center;gap:7px;font-size:12.5px;"
            >
              <span class="font-mono" style="color:var(--tx-1);">{pin.name}</span>
              <span :if={pin.current?} class="mono-label" style="padding:0;">current</span>
              <span style="flex:1;"></span>
              <span :if={pin.version} class="font-mono" style="color:var(--tx-0);">
                {pin.version}
              </span>
              <span :if={is_nil(pin.version)} style="color:var(--warn);font-size:12px;">
                no version yet — not pinned
              </span>
            </div>
          </div>
          <div style={hint_style(8)}>
            Requests pick a prompt by name (<span class="font-mono">"prompt"</span>, default <span class="font-mono">"default"</span>). A name that is not pinned is a 404, never a
            silent fallback.
            <.link
              id="deploy-open-deployments"
              patch={@deployments_patch}
              style="color:var(--link);text-decoration:none;"
            >Deployments →</.link>
          </div>
        </div>

        <DS.btn
          id="deploy-submit"
          type="submit"
          variant="primary"
          icon="flag"
          full
          style="margin-top:12px;"
          disabled={@models == [] or @envs == [] or (@version_required? and @version_options == [])}
        >
          Deploy
        </DS.btn>
      </form>
    </DS.modal>
    """
  end

  defp params_note(params) do
    params
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key} #{value}" end)
  end

  # ---------------------------------------------------------------------------
  # AI draft modal

  @doc """
  The AI draft modal (mockup `AIDraftModal`). The server holds the stage:

  - `:intro`: instruction input, suggestion chips and a preview of the current message
  - `:running`: three-step pulse plus shimmer (progress display instead of streaming)
  - `:done`: the suggested body plus Regenerate / Replace message
  - `:no_key`: generation blocked because there is no openrouter provider key (organization
    settings link)
  - `:error`: the call failed
  """
  attr :stage, :atom, required: true
  attr :role, :string, required: true
  attr :current, :string, default: ""
  attr :instruction, :string, default: ""
  attr :result, :string, default: nil
  attr :error, :string, default: nil
  attr :close_patch, :string, required: true

  attr :providers_path, :string,
    required: true,
    doc: "the Provider Keys tab of the organization settings"

  def ai_draft_modal(assigns) do
    ~H"""
    <DS.modal
      id="ai-draft-modal"
      on_close={@close_patch}
      width={640}
      icon="sparkles"
      title={"Draft #{@role} message"}
    >
      <div :if={@stage == :intro}>
        <form id="ai-draft-form" phx-change="ai_change">
          <div class="mono-label" style="margin-bottom:7px;">What should it focus on?</div>
          <textarea
            id="ai-instruction"
            name="ai[instruction]"
            phx-debounce="300"
            placeholder="e.g. preserve the emotion more strongly, add a length limit"
            class="ring-acc"
            style="width:100%;height:70px;background:var(--bg-1);border:1px solid var(--line);border-radius:var(--r);padding:10px 12px;color:var(--tx-0);font-size:14px;font-family:inherit;resize:none;outline:none;line-height:1.55;"
          >{@instruction}</textarea>
        </form>
        <div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:10px;">
          <button
            :for={s <- ai_suggestions()}
            type="button"
            class="chip tr"
            style="cursor:pointer;"
            phx-click="ai_suggest"
            phx-value-text={s}
          >
            {s}
          </button>
        </div>
        <div class="card2" style="margin-top:14px;padding:11px;background:var(--bg-1);">
          <div class="mono-label" style="margin-bottom:6px;">current {@role}</div>
          <div class="grad-fade-b" style="max-height:90px;overflow:hidden;">
            <DS.liquid text={@current} />
          </div>
        </div>
      </div>

      <div
        :if={@stage == :running}
        id="ai-running"
        style="display:flex;flex-direction:column;gap:11px;padding:6px 0;"
      >
        <div
          :for={{t, i} <- Enum.with_index(ai_steps())}
          style="display:flex;align-items:center;gap:10px;"
        >
          <span class="pulse" style={"animation-delay:#{i * 0.3}s;display:inline-flex;"}>
            <DS.status_dot kind={:ok} />
          </span>
          <span style="font-size:14px;color:var(--tx-1);">{t}</span>
        </div>
        <div class="shimmer" style="height:9px;width:72%;margin-top:4px;" />
        <div class="shimmer" style="height:9px;width:90%;" />
        <div class="shimmer" style="height:9px;width:58%;" />
      </div>

      <div :if={@stage == :done} id="ai-result">
        <div style="display:flex;align-items:center;gap:7px;margin-bottom:8px;">
          <DS.badge tone={:accent} mono>
            <DSIcons.icon name="sparkles" size={11} /> suggested
          </DS.badge>
          <DS.badge tone={:ok} mono><DSIcons.icon name="check" size={10} /> ready</DS.badge>
        </div>
        <div class="card2" style="padding:12px;background:var(--bg-1);">
          <DS.liquid text={@result} />
        </div>
      </div>

      <div :if={@stage == :no_key} id="ai-no-key">
        <.schema_banner id="ai-no-key-banner" tone={:warn} icon="alert">
          No openrouter provider key in this organization — drafts can't be generated.
        </.schema_banner>
        <div style="margin-top:10px;">
          <DS.btn_link
            id="ai-providers-link"
            variant="outline"
            icon="key"
            navigate={@providers_path}
          >
            Add a provider key in Organization settings
          </DS.btn_link>
        </div>
      </div>

      <div :if={@stage == :error} id="ai-error">
        <.schema_banner id="ai-error-banner" tone={:err} icon="alert">
          {@error}
        </.schema_banner>
      </div>

      <:footer>
        <span style="font-size:12.5px;color:var(--tx-2);display:flex;align-items:center;gap:5px;margin-right:auto;">
          <DSIcons.icon name="key" size={12} /> uses your openrouter provider key
        </span>
        <%= if @stage in [:intro, :error] do %>
          <DS.btn_link id="ai-cancel" variant="ghost" patch={@close_patch}>Cancel</DS.btn_link>
          <DS.btn id="ai-generate" variant="primary" icon="sparkles" phx-click="ai_generate">
            Generate
          </DS.btn>
        <% end %>
        <DS.btn_link :if={@stage == :running} id="ai-stop" variant="outline" patch={@close_patch}>
          Stop
        </DS.btn_link>
        <%= if @stage == :done do %>
          <DS.btn id="ai-regenerate" variant="ghost" phx-click="ai_generate">Regenerate</DS.btn>
          <DS.btn id="ai-replace" variant="primary" icon="check" phx-click="ai_replace">
            Replace message
          </DS.btn>
        <% end %>
        <DS.btn_link :if={@stage == :no_key} id="ai-close" variant="ghost" patch={@close_patch}>
          Close
        </DS.btn_link>
      </:footer>
    </DS.modal>
    """
  end

  defp ai_steps, do: @ai_steps
end
