defmodule PromptOnWeb.EvalsComponents do
  @moduledoc """
  The drawing half of the Evals tab (ADR 0010 §5.1) — function components plus the pure label
  helpers they use.

  Everything here is presentational: it takes records and maps and returns markup. The tab's state,
  its events and every domain call live in `PromptOnWeb.EvalsPanel`.

  The vocabulary is seven pieces:

  - `sample_card/1` — one sampled log with the stars the human clicks.
  - `agreement_table/1` — the human's score next to the AI's, one row per sample.
  - `rubric_card/1` — a rubric version, read-only.
  - `run_card/1` / `run_drawer/1` — one batch evaluation, collapsed and expanded.
  - `score_badge/1` — a revision's average, wherever that revision is shown.
  - `distribution_bar/1` — the 1..5 histogram as one bar.
  - `continuous_eval_card/1` — the disabled paid-plan affordance (ADR 0010 §5.7). The plan it names
    is derived from `PromptOn.Entitlements`, never written out.

  `score_badge/1` renders **nothing** for a revision that was never evaluated. An always-empty
  column is forbidden by `CLAUDE.md`, and "no badge" reads as "not measured", which is the truth.
  """
  use PromptOnWeb, :html

  alias PromptOn.Entitlements
  alias PromptOn.Evals.RubricCriteria

  @levels [1, 2, 3, 4, 5]

  # The role prefixes `PromptOn.Evals.PayloadText` writes in front of a chat message.
  @roles ~w(system user assistant tool text)

  # ---------------------------------------------------------------------------
  # Pure labels

  @doc """
  Average score → badge tone. The thresholds are the ADR's: 4.0 and up is good, 3.0 and up is
  neutral, below 3.0 is bad.

      iex> PromptOnWeb.EvalsComponents.score_tone(4.0)
      :ok

      iex> PromptOnWeb.EvalsComponents.score_tone(3.0)
      :neutral

      iex> PromptOnWeb.EvalsComponents.score_tone(Decimal.new("2.99"))
      :err

      iex> PromptOnWeb.EvalsComponents.score_tone(nil)
      :neutral
  """
  @spec score_tone(number() | Decimal.t() | nil) :: atom()
  def score_tone(value) do
    case to_float(value) do
      nil -> :neutral
      average when average >= 4.0 -> :ok
      average when average >= 3.0 -> :neutral
      _low -> :err
    end
  end

  @doc """
  One score to one decimal place.

      iex> PromptOnWeb.EvalsComponents.score_label(Decimal.new("4.24"))
      "4.2"

      iex> PromptOnWeb.EvalsComponents.score_label(4)
      "4.0"

      iex> PromptOnWeb.EvalsComponents.score_label(nil)
      "—"
  """
  @spec score_label(number() | Decimal.t() | nil) :: String.t()
  def score_label(value) do
    case to_float(value) do
      nil -> "—"
      number -> :erlang.float_to_binary(number, decimals: 1)
    end
  end

  @doc """
  A 0..1 ratio as a whole percentage.

      iex> PromptOnWeb.EvalsComponents.ratio_label(0.9)
      "90%"

      iex> PromptOnWeb.EvalsComponents.ratio_label(nil)
      "—"
  """
  @spec ratio_label(number() | Decimal.t() | nil) :: String.t()
  def ratio_label(value) do
    case to_float(value) do
      nil -> "—"
      ratio -> "#{round(ratio * 100)}%"
    end
  end

  @doc """
  A dollar amount. Anything above zero but below a cent says so rather than showing `$0.00`, which
  would read as free.

      iex> PromptOnWeb.EvalsComponents.cost_label(Decimal.new("0.42"))
      "$0.42"

      iex> PromptOnWeb.EvalsComponents.cost_label(0.0004)
      "< $0.01"

      iex> PromptOnWeb.EvalsComponents.cost_label(nil)
      "—"
  """
  @spec cost_label(number() | Decimal.t() | nil) :: String.t()
  def cost_label(value) do
    case to_float(value) do
      nil -> "—"
      amount when amount <= 0.0 -> "$0.00"
      amount when amount < 0.01 -> "< $0.01"
      amount -> "$" <> :erlang.float_to_binary(amount, decimals: 2)
    end
  end

  @doc """
  The 1..5 histogram as five rows. An empty (or all-zero) distribution gives every row a ratio of
  `0.0` instead of dividing by zero.

      iex> PromptOnWeb.EvalsComponents.distribution_rows(%{"4" => 2, "5" => 2}) |> Enum.map(& &1.ratio)
      [0.0, 0.0, 0.0, 0.5, 0.5]

      iex> PromptOnWeb.EvalsComponents.distribution_rows(%{}) |> Enum.map(& &1.ratio)
      [0.0, 0.0, 0.0, 0.0, 0.0]

      iex> PromptOnWeb.EvalsComponents.distribution_rows(nil) |> Enum.map(& &1.count)
      [0, 0, 0, 0, 0]
  """
  @spec distribution_rows(map() | nil) :: [
          %{level: 1..5, count: non_neg_integer(), ratio: float()}
        ]
  def distribution_rows(distribution) do
    counts = Enum.map(@levels, &level_count(distribution, &1))
    total = Enum.sum(counts)

    @levels
    |> Enum.zip(counts)
    |> Enum.map(fn {level, count} ->
      %{level: level, count: count, ratio: if(total > 0, do: count / total, else: 0.0)}
    end)
  end

  @doc """
  How long ago, in one short phrase. `nil` is an em dash.

      iex> PromptOnWeb.EvalsComponents.ago_label(nil)
      "—"

      iex> PromptOnWeb.EvalsComponents.ago_label(DateTime.utc_now())
      "just now"
  """
  @spec ago_label(DateTime.t() | nil) :: String.t()
  def ago_label(nil), do: "—"

  def ago_label(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3_600 -> "#{div(seconds, 60)} min ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3_600)} h ago"
      seconds -> "#{div(seconds, 86_400)} d ago"
    end
  end

  @doc """
  The first line of a text, cut to `max` characters — what the agreement table shows in place of a
  whole payload.

      iex> PromptOnWeb.EvalsComponents.excerpt("hello\\nworld", 20)
      "hello"

      iex> PromptOnWeb.EvalsComponents.excerpt(nil, 20)
      "—"
  """
  @spec excerpt(String.t() | nil, pos_integer()) :: String.t()
  def excerpt(nil, _max), do: "—"

  def excerpt(text, max) when is_binary(text) do
    line =
      text
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.trim()

    case line do
      "" -> "—"
      line when byte_size(line) > max -> String.slice(line, 0, max) <> "…"
      line -> line
    end
  end

  @doc """
  The one line of an input worth putting in the agreement table.

  `PromptOn.Evals.PayloadText` renders a chat input as `"role: content"` blocks separated by a
  blank line, and the **system** block is identical on every sample of a use case — ten identical
  rows tell the reader nothing. So this prefers the last `user:` block (the turn that actually
  distinguishes the samples), falls back to the last block, and drops the role prefix.

      iex> PromptOnWeb.EvalsComponents.input_excerpt("system: Be nice.\\n\\nuser: how are you?", 40)
      "how are you?"

      iex> PromptOnWeb.EvalsComponents.input_excerpt("just text", 40)
      "just text"

      iex> PromptOnWeb.EvalsComponents.input_excerpt(nil, 40)
      "—"
  """
  @spec input_excerpt(String.t() | nil, pos_integer()) :: String.t()
  def input_excerpt(nil, _max), do: "—"

  def input_excerpt(text, max) when is_binary(text) do
    blocks =
      text
      |> String.split("\n\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    block =
      Enum.find(Enum.reverse(blocks), &String.starts_with?(&1, "user:")) || List.last(blocks) ||
        text

    block |> strip_role() |> excerpt(max)
  end

  defp strip_role(block) do
    case String.split(block, ": ", parts: 2) do
      [role, rest] -> if role in @roles, do: rest, else: block
      _no_prefix -> block
    end
  end

  @doc """
  Rubric source → the badge word.

      iex> PromptOnWeb.EvalsComponents.source_label(:ai_draft)
      "AI draft"

      iex> PromptOnWeb.EvalsComponents.source_label(:manual)
      "Manual"
  """
  @spec source_label(atom()) :: String.t()
  def source_label(:ai_draft), do: "AI draft"
  def source_label(:ai_revision), do: "AI revision"
  def source_label(:manual), do: "Manual"
  def source_label(other), do: to_string(other)

  @doc """
  Run status → badge tone.

      iex> PromptOnWeb.EvalsComponents.status_tone(:completed)
      :ok

      iex> PromptOnWeb.EvalsComponents.status_tone(:failed)
      :err
  """
  @spec status_tone(atom()) :: atom()
  def status_tone(:completed), do: :ok
  def status_tone(:failed), do: :err
  def status_tone(:cancelled), do: :warn
  def status_tone(_active), do: :accent

  @doc """
  How far a run has got. "done", not "scored": the count includes the items that failed and the ones
  the judge answered unparsably, and a run in which nothing was scored must not read `"5 / 5
  scored"`. When something did fail, the label says so.

      iex> PromptOnWeb.EvalsComponents.progress_label(%{scored_count: 3, unparsable_count: 1, failed_count: 0, item_count: 10})
      "4 / 10 done · 3 scored · 1 unparsable"

      iex> PromptOnWeb.EvalsComponents.progress_label(%{scored_count: 10, unparsable_count: 0, failed_count: 0, item_count: 10})
      "10 / 10 done"

      iex> PromptOnWeb.EvalsComponents.progress_label(%{scored_count: 0, unparsable_count: 0, failed_count: 5, item_count: 5})
      "5 / 5 done · 0 scored · 5 failed"
  """
  @spec progress_label(map()) :: String.t()
  def progress_label(run) do
    head = "#{done_count(run)} / #{run.item_count} done"

    case problems(run) do
      [] -> head
      problems -> Enum.join([head, "#{run.scored_count || 0} scored" | problems], " · ")
    end
  end

  defp problems(run) do
    [{:unparsable_count, "unparsable"}, {:failed_count, "failed"}]
    |> Enum.filter(fn {field, _label} -> (Map.get(run, field) || 0) > 0 end)
    |> Enum.map(fn {field, label} -> "#{Map.get(run, field)} #{label}" end)
  end

  @doc false
  @spec done_count(map()) :: non_neg_integer()
  def done_count(run),
    do: (run.scored_count || 0) + (run.unparsable_count || 0) + (run.failed_count || 0)

  @doc """
  A short, **discriminating** reference to a monitoring log. The first characters of a `uuid_v7` are
  its millisecond timestamp, so every item of one batch would render the same string; the tail is
  what differs. The full id belongs in a `title`.

      iex> PromptOnWeb.EvalsComponents.log_ref("01a06a65-9c2f-7b1e-8000-0123456789ab")
      "456789ab"

      iex> PromptOnWeb.EvalsComponents.log_ref(nil)
      "—"
  """
  @spec log_ref(String.t() | nil) :: String.t()
  def log_ref(id) when is_binary(id) and byte_size(id) >= 8, do: String.slice(id, -8, 8)
  def log_ref(id) when is_binary(id), do: id
  def log_ref(_id), do: "—"

  @doc """
  The lowest plan on which continuous evaluation is included, as display copy — derived from
  `PromptOn.Entitlements`, never written out, so the card can never advertise a plan that does not
  have the feature.

      iex> PromptOnWeb.EvalsComponents.automatic_evaluation_plans()
      "Pro"
  """
  @spec automatic_evaluation_plans() :: String.t()
  def automatic_evaluation_plans do
    Entitlements.plans()
    |> Enum.filter(&Entitlements.allows?(&1, :automatic_evaluation))
    |> Enum.map_join(" and ", &Entitlements.label/1)
    |> case do
      "" -> "a paid plan"
      labels -> labels
    end
  end

  @doc """
  `{level, criteria field}` pairs, 1 to 5 — the display order of a rubric's levels.

      iex> PromptOnWeb.EvalsComponents.level_fields() |> hd()
      {1, :level_1}
  """
  @spec level_fields() :: [{1..5, atom()}]
  def level_fields, do: Enum.zip(@levels, RubricCriteria.levels())

  defp level_count(distribution, level) when is_map(distribution) do
    case Map.get(distribution, Integer.to_string(level), Map.get(distribution, level, 0)) do
      count when is_integer(count) and count > 0 -> count
      _none -> 0
    end
  end

  defp level_count(_distribution, _level), do: 0

  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(_value), do: nil

  # Level colour: the failures are red, the middle is amber, the good ones are green.
  defp level_color(level) when level <= 2, do: "var(--err)"
  defp level_color(3), do: "var(--warn)"
  defp level_color(_level), do: "var(--ok)"

  # ---------------------------------------------------------------------------
  # Score badge

  @doc """
  A deployment revision's evaluated average (ADR 0010 §5.4). Renders **nothing** when `run` is nil,
  so a revision nobody has evaluated shows no badge at all rather than an empty column.
  """
  attr :run, :map, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def score_badge(assigns) do
    ~H"""
    <DS.badge
      :if={@run}
      id={@id}
      class={@class}
      tone={score_tone(@run.average_score)}
      mono
      title={badge_title(@run)}
      style="font-size:10.5px;"
    >
      {score_label(@run.average_score)} ★ · n={@run.scored_count} · v{@run.rubric_number}
    </DS.badge>
    """
  end

  defp badge_title(run) do
    [
      "criteria v#{run.rubric_number}",
      run.judge_model,
      ago_label(run.finished_at)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # ---------------------------------------------------------------------------
  # Distribution

  @doc """
  The 1..5 histogram as one stacked bar. An all-zero distribution renders the empty track — it
  never divides by zero.
  """
  attr :distribution, :map, default: %{}
  attr :id, :string, default: nil
  attr :height, :integer, default: 8
  attr :legend, :boolean, default: false

  def distribution_bar(assigns) do
    assigns = assign(assigns, :rows, distribution_rows(assigns.distribution))

    ~H"""
    <div id={@id} style="display:flex;flex-direction:column;gap:5px;min-width:0;">
      <div
        style={"display:flex;height:#{@height}px;border-radius:var(--r-sm);overflow:hidden;background:var(--bg-3);border:1px solid var(--line-2);"}
        title={Enum.map_join(@rows, " · ", &"#{&1.level}:#{&1.count}")}
      >
        <span
          :for={row <- @rows}
          :if={row.ratio > 0}
          id={@id && "#{@id}-level-#{row.level}"}
          style={"width:#{Float.round(row.ratio * 100, 2)}%;background:#{level_color(row.level)};opacity:.55;"}
        ></span>
      </div>
      <div :if={@legend} style="display:flex;gap:10px;flex-wrap:wrap;">
        <span
          :for={row <- @rows}
          class="font-mono"
          style="font-size:11.5px;color:var(--tx-3);white-space:nowrap;"
        >
          <span style={"color:#{level_color(row.level)};"}>{row.level}</span>★ {row.count}
        </span>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Calibration

  @doc """
  One sampled log: where it came from, what went in and out, and the stars the human clicks.

  The star click writes straight to the database (there is no Save on this screen, exactly as in
  the prompt editor), so the note field is only enabled once a score exists — `:score` stores the
  two together.
  """
  attr :sample, :map, required: true
  attr :target, :any, default: nil

  def sample_card(assigns) do
    ~H"""
    <div
      id={"sample-#{@sample.position}"}
      class="card2"
      style="padding:11px 13px;display:flex;flex-direction:column;gap:9px;min-width:0;"
    >
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
        <span class="font-mono" style="font-size:13px;font-weight:600;">#{@sample.position}</span>
        <span class="font-mono" style="font-size:11.5px;color:var(--tx-3);overflow-wrap:anywhere;">
          {sample_source(@sample)}
        </span>
        <DS.badge :if={@sample.truncated?} tone={:neutral} mono style="font-size:10px;">
          truncated
        </DS.badge>
        <span style="flex:1;"></span>
        <DS.stars
          value={@sample.user_score || 0}
          event="score_sample"
          target={@target}
          phx-value-sample={@sample.id}
        />
      </div>

      <DS.collapsible id={"sample-#{@sample.position}-input"} label="input" icon="arrowDownLeft">
        <div style="max-height:190px;overflow:auto;padding:10px 12px;">
          <DS.code_block text={@sample.input_text || ""} size={12.5} />
        </div>
      </DS.collapsible>

      <DS.collapsible
        id={"sample-#{@sample.position}-output"}
        label="output"
        icon="arrowUpRight"
        open
      >
        <div style="max-height:190px;overflow:auto;padding:10px 12px;">
          <DS.code_block text={@sample.output_text || ""} size={12.5} />
        </div>
      </DS.collapsible>

      <DS.ds_input
        id={"sample-#{@sample.position}-note"}
        name="note"
        value={@sample.user_note}
        disabled={is_nil(@sample.user_score)}
        placeholder={
          if is_nil(@sample.user_score),
            do: "Score it first — the note is stored with the score.",
            else: "Why this score? (optional)"
        }
        phx-blur="note_sample"
        phx-target={@target}
        phx-value-sample={@sample.id}
        autocomplete="off"
      />
    </div>
    """
  end

  defp sample_source(sample) do
    [
      sample.model,
      sample.deployment_revision && "##{sample.deployment_revision}",
      sample.started_at && Calendar.strftime(sample.started_at, "%Y-%m-%d %H:%M")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  @doc """
  The human's score beside the AI's, one row per sample.

  A row where the two disagree by two levels or more is tinted: that gap is exactly what a revision
  is meant to close. Rows are `%{position:, excerpt:, user_score:, ai_score:, delta:, status:,
  rationale:, error_message:}`.
  """
  attr :rows, :list, required: true
  attr :id, :string, default: "agreement-table"

  def agreement_table(assigns) do
    ~H"""
    <div id={@id} style="display:flex;flex-direction:column;gap:5px;min-width:0;">
      <div
        style="display:flex;align-items:center;gap:10px;padding:0 12px;"
        class="mono-label"
      >
        <span style="width:26px;">#</span>
        <span style="flex:1;min-width:0;">input</span>
        <span style="width:44px;text-align:right;">you</span>
        <span style="width:44px;text-align:right;">ai</span>
        <span style="width:36px;text-align:right;" title="How far the AI's score is from yours">
          gap
        </span>
      </div>

      <details
        :for={row <- @rows}
        id={"agreement-#{row.position}"}
        class="card2 dscollapse"
        style={
          DS.style_list([
            "overflow:hidden;",
            if(gap?(row), do: "border-color:rgba(255,32,71,.30);background:rgba(255,32,71,.06);")
          ])
        }
      >
        <summary>
          <DSIcons.icon name="chevRight" size={13} class="tx2 dscollapse-closed" />
          <DSIcons.icon name="chevDown" size={13} class="tx2 dscollapse-open" />
          <span class="font-mono" style="font-size:12.5px;width:26px;">#{row.position}</span>
          <span style="flex:1;min-width:0;font-size:13px;color:var(--tx-1);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
            {row.excerpt}
          </span>
          <span
            class="font-mono"
            style="font-size:12.5px;color:var(--tx-1);width:44px;text-align:right;"
          >
            {row.user_score || "—"}
          </span>
          <span class="font-mono" style="font-size:12.5px;width:44px;text-align:right;">
            {ai_cell(row)}
          </span>
          <span
            class="font-mono"
            style={"font-size:12.5px;width:36px;text-align:right;color:#{delta_color(row.delta)};"}
          >
            {row.delta || "—"}
          </span>
        </summary>
        <div class="fadeup" style="padding:2px 12px 11px;display:flex;flex-direction:column;gap:6px;">
          <div :if={row.status == :ok} style="font-size:13px;color:var(--tx-1);line-height:1.55;">
            {row.rationale || "The judge gave no rationale."}
          </div>
          <div
            :if={row.status == :unparsable}
            style="font-size:13px;color:var(--warn);line-height:1.55;"
            title="the judge did not answer with JSON"
          >
            The judge did not answer with JSON, so this sample has no AI score.
          </div>
          <div :if={row.status == :failed} style="font-size:13px;color:var(--err);line-height:1.55;">
            {row.error_message || "The judge call failed."}
          </div>
          <div :if={is_nil(row.status)} style="font-size:13px;color:var(--tx-3);line-height:1.55;">
            Not scored against these criteria yet.
          </div>
        </div>
      </details>
    </div>
    """
  end

  defp gap?(%{delta: delta}) when is_integer(delta), do: delta >= 2
  defp gap?(_row), do: false

  defp ai_cell(%{status: :ok, ai_score: score}) when not is_nil(score), do: to_string(score)
  defp ai_cell(%{status: :unparsable}), do: "?"
  defp ai_cell(%{status: :failed}), do: "!"
  defp ai_cell(_row), do: "—"

  defp delta_color(nil), do: "var(--tx-3)"
  defp delta_color(delta) when delta >= 2, do: "var(--err)"
  defp delta_color(delta) when delta >= 1, do: "var(--warn)"
  defp delta_color(_delta), do: "var(--ok)"

  @doc "A rubric version, read-only: the summary, the hard rules, and the five levels."
  attr :rubric, :map, required: true
  attr :id, :string, default: "rubric-card"

  def rubric_card(assigns) do
    assigns = assign(assigns, :criteria, assigns.rubric.criteria)

    ~H"""
    <div id={@id} class="card2" style="padding:12px 14px;display:flex;flex-direction:column;gap:11px;">
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
        <span class="font-mono" style="font-size:13.5px;font-weight:600;">v{@rubric.number}</span>
        <DS.badge tone={:neutral} mono style="font-size:10px;">
          {source_label(@rubric.source)}
        </DS.badge>
        <span style="flex:1;"></span>
        <span class="font-mono" style="font-size:11.5px;color:var(--tx-3);">
          {ago_label(@rubric.inserted_at)}
        </span>
      </div>

      <div style="font-size:13.5px;color:var(--tx-0);line-height:1.6;overflow-wrap:anywhere;">
        {@criteria.summary}
      </div>

      <div :if={@rubric.note} style="font-size:12.5px;color:var(--tx-2);line-height:1.55;">
        <span class="mono-label">note</span> {@rubric.note}
      </div>

      <div
        :if={@criteria.must_never != []}
        id={"#{@id}-must-never"}
        style="display:flex;flex-direction:column;gap:5px;"
      >
        <span class="mono-label">must never</span>
        <div style="display:flex;flex-wrap:wrap;gap:5px;">
          <span
            :for={item <- @criteria.must_never}
            class="chip"
            style="background:rgba(255,32,71,.10);border-color:rgba(255,32,71,.30);color:var(--err);"
          >
            {item}
          </span>
        </div>
      </div>

      <div style="display:flex;flex-direction:column;gap:2px;">
        <DS.kv :for={{level, field} <- level_fields()} label={"#{level} ★"} w={44} mono={false}>
          <span style="font-size:13px;color:var(--tx-1);line-height:1.55;overflow-wrap:anywhere;">
            {Map.get(@criteria, field)}
          </span>
        </DS.kv>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Runs

  @doc "One batch evaluation, collapsed: progress while it runs, the result when it is done."
  attr :run, :map, required: true
  attr :patch, :string, required: true
  attr :selected?, :boolean, default: false

  def run_card(assigns) do
    ~H"""
    <.link
      id={"run-#{@run.id}"}
      patch={@patch}
      class="card2"
      style={
        DS.style_list([
          "padding:10px 12px;display:flex;align-items:center;gap:12px;text-decoration:none;min-width:0;",
          if(@selected?, do: "border-color:var(--line-3);background:var(--bg-3);"),
          if(@run.status == :failed, do: "border-color:rgba(255,32,71,.30);")
        ])
      }
    >
      <div style="display:flex;flex-direction:column;gap:3px;min-width:0;flex:1;">
        <span class="font-mono" style="font-size:13px;color:var(--tx-0);white-space:nowrap;">
          #{@run.deployment_revision} · {run_env(@run)} · criteria v{@run.rubric_number}
        </span>
        <span class="font-mono" style="font-size:11.5px;color:var(--tx-3);">
          {@run.judge_model} · {ago_label(@run.finished_at || @run.inserted_at)}
        </span>
      </div>

      <div
        :if={@run.status in [:queued, :running]}
        style="display:flex;align-items:center;gap:8px;min-width:0;"
      >
        <span class="font-mono" style="font-size:12px;color:var(--tx-2);white-space:nowrap;">
          {progress_label(@run)}
        </span>
        <DS.badge tone={:accent} mono style="font-size:10px;">{@run.status}</DS.badge>
      </div>

      <div
        :if={@run.status == :completed}
        style="display:flex;align-items:center;gap:10px;min-width:0;"
      >
        <div style="width:110px;">
          <.distribution_bar id={"run-#{@run.id}-dist"} distribution={@run.score_distribution} />
        </div>
        <span class="font-mono" style="font-size:11.5px;color:var(--tx-3);white-space:nowrap;">
          n={@run.scored_count}
        </span>
        <span
          class="font-mono"
          style={"font-size:17px;font-weight:600;white-space:nowrap;color:#{DS.tone(score_tone(@run.average_score)).fg};"}
        >
          {score_label(@run.average_score)}
        </span>
      </div>

      <DS.badge
        :if={@run.status in [:failed, :cancelled]}
        tone={status_tone(@run.status)}
        mono
        style="font-size:10px;"
      >
        {@run.status}
      </DS.badge>
    </.link>
    """
  end

  defp run_env(%{environment: %{slug: slug}}), do: slug
  defp run_env(_run), do: "—"

  @doc """
  One run, expanded: the frozen numbers, and the twenty worst items with the judge's reasons.

  The worst items are the product — an average tells you there is a problem, these tell you what it
  is. There is no link to a log detail screen because there is no log detail screen yet; the
  log id is shown instead so it can be found in the logs the app itself keeps.
  """
  attr :run, :map, required: true
  attr :items, :list, default: []
  attr :on_close, :any, required: true
  attr :target, :any, default: nil

  def run_drawer(assigns) do
    ~H"""
    <DS.drawer
      id="run-drawer"
      on_close={@on_close}
      width={720}
      title={"Evaluation ##{@run.deployment_revision} · criteria v#{@run.rubric_number}"}
      sub={"#{run_env(@run)} · #{@run.judge_model}"}
    >
      <:badge>
        <DS.badge tone={status_tone(@run.status)} mono>{@run.status}</DS.badge>
      </:badge>
      <:actions>
        <DS.btn
          :if={@run.status in [:queued, :running]}
          id="cancel-run"
          size="sm"
          variant="outline"
          icon="x"
          phx-click="cancel_run"
          phx-target={@target}
          phx-value-id={@run.id}
        >
          Cancel
        </DS.btn>
      </:actions>

      <div style="display:flex;flex-direction:column;gap:14px;min-width:0;">
        <div :if={@run.error_message} id="run-error" style="font-size:13px;color:var(--err);">
          {@run.error_message}
        </div>

        <div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;">
          <DS.stat_tile
            label="average"
            value={score_label(@run.average_score)}
            tone={score_tone(@run.average_score)}
            sub={"n = #{@run.scored_count}"}
          />
          <DS.stat_tile label="items" value={@run.item_count} sub={progress_label(@run)} />
          <DS.stat_tile label="cost" value={cost_label(@run.cost_usd)} sub={@run.judge_model} />
        </div>

        <.distribution_bar
          id="run-drawer-dist"
          distribution={@run.score_distribution}
          height={10}
          legend
        />

        <div style="display:flex;flex-direction:column;gap:2px;">
          <DS.kv label="window">{window_label(@run)}</DS.kv>
          <DS.kv label="sampled">{@run.item_count} of up to {@run.sample_limit}</DS.kv>
          <DS.kv label="unparsable">{@run.unparsable_count}</DS.kv>
          <DS.kv label="failed">{@run.failed_count}</DS.kv>
        </div>

        <div style="display:flex;flex-direction:column;gap:6px;">
          <span class="mono-label">Worst items</span>
          <div
            :if={@items == []}
            id="run-no-worst"
            style="font-size:13px;color:var(--tx-3);padding:4px 2px;"
          >
            {no_worst_copy(@run)}
          </div>
          <div
            :for={item <- @items}
            id={"worst-#{item.id}"}
            class="card2"
            style="padding:9px 11px;display:flex;flex-direction:column;gap:5px;min-width:0;"
          >
            <div style="display:flex;align-items:center;gap:8px;">
              <span
                class="font-mono"
                style={"font-size:13px;font-weight:600;color:#{level_color(item.score)};"}
              >
                {item.score} ★
              </span>
              <span
                class="font-mono"
                style="font-size:11.5px;color:var(--tx-3);"
                title={item.generation_id}
              >
                #{item.position} · {log_ref(item.generation_id)}
              </span>
            </div>
            <div style="font-size:13px;color:var(--tx-1);line-height:1.55;overflow-wrap:anywhere;">
              {item.rationale || "No rationale."}
            </div>
          </div>
        </div>
      </div>
    </DS.drawer>
    """
  end

  defp no_worst_copy(%{status: :completed}),
    do: "Nothing scored 2 or below — this revision has no worst items."

  defp no_worst_copy(%{status: status}) when status in [:failed, :cancelled],
    do: "This run produced no scores."

  defp no_worst_copy(_run), do: "Nothing scored 2 or below yet."

  defp window_label(%{window_from: nil}), do: "—"

  defp window_label(%{window_from: from, window_to: to}) do
    Calendar.strftime(from, "%Y-%m-%d %H:%M") <> " → " <> Calendar.strftime(to, "%Y-%m-%d %H:%M")
  end

  # ---------------------------------------------------------------------------
  # Continuous evaluation (not built — ADR 0010 §5.7)

  @doc """
  The one place continuous evaluation is mentioned. The control is a real disabled checkbox, never
  a button that does nothing: on a plan without the feature it is a plan gate, on a plan with it the
  feature is not built yet, and both say so.

  The plan named in the badge and the sub-line comes from `automatic_evaluation_plans/0`, so the
  card can never advertise a plan that `PromptOn.Entitlements` does not actually grant the feature
  to (only `:pro` does today).
  """
  attr :plan, :atom, required: true
  attr :settings_path, :string, required: true
  attr :id, :string, default: "continuous-eval"

  def continuous_eval_card(assigns) do
    assigns =
      assign(assigns, :allowed?, Entitlements.allows?(assigns.plan, :automatic_evaluation))

    ~H"""
    <div
      id={@id}
      class="card2"
      style="padding:12px 14px;display:flex;align-items:flex-start;gap:12px;opacity:.72;"
    >
      <div style="flex:1;min-width:0;display:flex;flex-direction:column;gap:4px;">
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
          <span style="font-size:13.5px;font-weight:500;color:var(--tx-0);">
            Continuous evaluation
          </span>
          <DS.badge
            id={"#{@id}-badge"}
            tone={if @allowed?, do: :neutral, else: :accent}
            mono
            style="font-size:10px;"
          >
            {if @allowed?, do: "Coming soon", else: automatic_evaluation_plans()}
          </DS.badge>
        </div>
        <span style="font-size:12.5px;color:var(--tx-2);line-height:1.55;">
          Score new logs automatically as they arrive and get told when the average drifts.
        </span>
        <span :if={@allowed?} id={"#{@id}-sub"} style="font-size:12px;color:var(--tx-3);">
          Not built yet — manual evaluation is available above.
        </span>
        <span :if={!@allowed?} id={"#{@id}-sub"} style="font-size:12px;color:var(--tx-3);">
          Available on {automatic_evaluation_plans()}.
          <.link navigate={@settings_path} style="color:var(--link);">Organization settings</.link>
        </span>
      </div>

      <input
        id={"#{@id}-toggle"}
        type="checkbox"
        disabled
        checked={false}
        title={
          if @allowed?,
            do: "Not built yet",
            else: "Continuous evaluation is a #{automatic_evaluation_plans()} plan feature"
        }
        style="margin-top:3px;cursor:not-allowed;"
      />
    </div>
    """
  end
end
