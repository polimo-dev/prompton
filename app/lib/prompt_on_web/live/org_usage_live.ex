defmodule PromptOnWeb.OrgUsageLive do
  @moduledoc """
  Organization usage (`/:org_slug/usage?period=24h|7d|30d`).

  Every number is what `PromptOn.Observability.Stats.time_series/2` actually scanned out of the
  `generations` table, called once per project with the buckets summed. So **the columns are only
  what Stats really produces**: generations · errors · tokens · cost. The screen is named "Usage";
  it is not an invoice (there is no billing yet).

  - The period travels in the URL as `?period=`, and the **expanded project** as
    `?open=<project_slug>` (CLAUDE.md zero-downtime deployment discipline). Expanding opens that
    project's **per-use-case breakdown** for the same period and the same columns.
  - The per-use-case breakdown is **one** `Stats.time_series(..., group_by: :use_case_key)` call;
    it does not query per use case. The project total and the use case rows use **the same window
    (from/to)**, so total = sum of use cases always holds (`use_case_key` is `allow_nil? false`,
    so no row drops out).
  - `source: nil` counts **everything**: not only the monitoring logs the app sent (`:live`) but
    the arena calls too. This screen asks what the organization spent, and leaving out the calls
    the server made on its behalf would make the numbers lie.
  - The rows are the projects `PromptOnWeb.LiveProjectScope` already filtered by policy. `Stats`
    leaves authorization to the caller (module docs), so **a project_id outside that list is never
    passed in.**
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Observability.Stats
  alias PromptOnWeb.OrgComponents, as: OC
  alias PromptOnWeb.SettingsComponents, as: SC

  @periods [
    {"24h", "24h", 1},
    {"7d", "7d", 7},
    {"30d", "30d", 30}
  ]

  @cols [
    %{label: "project", w: "minmax(0,2fr)"},
    %{label: "generations", w: "120px", align: "right"},
    %{label: "errors", w: "100px", align: "right"},
    %{label: "tokens", w: "120px", align: "right"},
    %{label: "cost", w: "110px", align: "right"}
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Usage · #{Layouts.org_label(socket.assigns.organization)}",
       cols: @cols,
       rows: [],
       totals: empty_totals(),
       period: default_period(),
       open: nil,
       use_case_rows: []
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    projects = socket.assigns.projects
    period = period_param(params)

    # Compute the window **once** so the project totals and the use case breakdown see the same
    # `[from, to)`; if each called `utc_now/0`, one generation arriving in between would put the
    # totals out of step.
    window = window(period)
    open = open_param(params, projects)
    rows = Enum.map(projects, &usage_row(&1, window))

    {:noreply,
     assign(socket,
       period: period,
       open: open,
       rows: rows,
       totals: totals(rows),
       use_case_rows: use_case_rows(open, projects, window)
     )}
  end

  @doc "Period segment definitions: `{value, label, days}`."
  @spec periods() :: [{String.t(), String.t(), pos_integer()}]
  def periods, do: @periods

  defp default_period, do: @periods |> hd() |> elem(0)

  defp period_param(%{"period" => value}) do
    if Enum.any?(@periods, fn {v, _label, _days} -> v == value end),
      do: value,
      else: default_period()
  end

  defp period_param(_params), do: default_period()

  defp period_days(period) do
    Enum.find_value(@periods, 1, fn {v, _label, days} -> v == period && days end)
  end

  # An unknown slug (or another organization's) falls back to collapsed; the row list is already
  # filtered by policy.
  defp open_param(%{"open" => slug}, projects) when is_binary(slug) do
    if Enum.any?(projects, &(&1.slug == slug)), do: slug, else: nil
  end

  defp open_param(_params, _projects), do: nil

  @doc "The window this screen counts: `[from, to)`."
  @spec window(String.t()) :: {DateTime.t(), DateTime.t()}
  def window(period) do
    to = DateTime.utc_now()
    {DateTime.add(to, -period_days(period) * 86_400, :second), to}
  end

  defp usage_path(org_slug, period, open) do
    query = if open, do: [period: period, open: open], else: [period: period]
    ~p"/#{org_slug}/usage?#{query}"
  end

  # ---------------------------------------------------------------------------
  # Aggregation

  defp usage_row(project, {from, to}) do
    rows = Stats.time_series(project.id, from: from, to: to, bucket: :day, source: nil)

    Map.merge(sum(rows), %{project: project, color: DS.project_color(project.slug)})
  rescue
    # An aggregation failure must not kill the screen; only that project is drawn as 0.
    _ -> Map.merge(empty_totals(), %{project: project, color: DS.project_color(project.slug)})
  end

  # Per-use-case breakdown of the expanded project. Fetched with **one query**
  # (`group_by: :use_case_key`) and only the buckets are summed: once per project however many use
  # cases there are. Sorted by generations descending, then key ascending on ties.
  defp use_case_rows(nil, _projects, _window), do: []

  defp use_case_rows(slug, projects, window) do
    case Enum.find(projects, &(&1.slug == slug)) do
      nil -> []
      project -> use_case_rows_for(project, window)
    end
  end

  defp use_case_rows_for(project, {from, to}) do
    project.id
    |> Stats.time_series(
      from: from,
      to: to,
      bucket: :day,
      group_by: :use_case_key,
      source: nil
    )
    |> Enum.group_by(& &1.group)
    |> Enum.map(fn {use_case_key, rows} -> Map.put(sum(rows), :use_case_key, use_case_key) end)
    |> Enum.sort_by(&{-&1.count, &1.use_case_key})
  rescue
    _ -> []
  end

  defp sum(rows) do
    Enum.reduce(rows, empty_totals(), fn row, acc ->
      %{
        count: acc.count + row.count,
        error_count: acc.error_count + row.error_count,
        tokens: acc.tokens + row.input_tokens + row.output_tokens,
        cost_usd: Decimal.add(acc.cost_usd, row.cost_usd)
      }
    end)
  end

  defp totals(rows) do
    Enum.reduce(rows, empty_totals(), fn row, acc ->
      %{
        count: acc.count + row.count,
        error_count: acc.error_count + row.error_count,
        tokens: acc.tokens + row.tokens,
        cost_usd: Decimal.add(acc.cost_usd, row.cost_usd)
      }
    end)
  end

  defp empty_totals, do: %{count: 0, error_count: 0, tokens: 0, cost_usd: Decimal.new(0)}

  @doc "Whether this project row is expanded (`?open=<project_slug>`)."
  @spec open?(String.t() | nil, map()) :: boolean()
  def open?(open, %{slug: slug}), do: open == slug

  # Close when open, otherwise open; the collapsed state is the absence of `?open=`.
  defp toggle_path(org_slug, period, open, slug),
    do: usage_path(org_slug, period, if(open == slug, do: nil, else: slug))

  # ---------------------------------------------------------------------------
  # Display

  @doc """
  Dollar display, to four decimal places. Zero is `$0`.

      iex> PromptOnWeb.OrgUsageLive.cost_label(Decimal.new("0"))
      "$0"

      iex> PromptOnWeb.OrgUsageLive.cost_label(Decimal.new("1.23456"))
      "$1.2346"
  """
  @spec cost_label(Decimal.t()) :: String.t()
  def cost_label(%Decimal{} = cost) do
    if Decimal.equal?(cost, 0) do
      "$0"
    else
      "$" <> (cost |> Decimal.round(4) |> Decimal.normalize() |> Decimal.to_string(:normal))
    end
  end

  @doc """
  Large numbers shortened: `K` from 1,000, `M` from 1,000,000.

      iex> PromptOnWeb.OrgUsageLive.compact(999)
      "999"

      iex> PromptOnWeb.OrgUsageLive.compact(12_400)
      "12.4K"

      iex> PromptOnWeb.OrgUsageLive.compact(3_000_000)
      "3M"
  """
  @spec compact(integer()) :: String.t()
  def compact(n) when is_integer(n) and n >= 1_000_000, do: trim_zero(n / 1_000_000) <> "M"
  def compact(n) when is_integer(n) and n >= 1_000, do: trim_zero(n / 1_000) <> "K"
  def compact(n) when is_integer(n), do: Integer.to_string(n)

  defp trim_zero(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.replace_suffix(".0", "")
  end

  # ---------------------------------------------------------------------------
  # Render

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      org_slug={@org_slug}
      project={@project}
      projects={@projects}
      organization={@organization}
      organizations={@organizations}
      nav={:usage}
    >
      <DS.screen
        id="org-usage-screen"
        title="Usage"
        sub={Layouts.org_label(@organization)}
        max_w={980}
      >
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <:actions>
          <OC.org_nav org_slug={@org_slug} active={:usage} />
        </:actions>

        <div style="display:flex;align-items:center;gap:10px;margin-bottom:12px;">
          <DS.seg
            id="usage-period"
            value={@period}
            options={
              for {value, label, _days} <- periods() do
                %{value: value, label: label, patch: usage_path(@org_slug, value, @open)}
              end
            }
          />
          <span style="font-size:12.5px;color:var(--tx-2);">
            Every generation recorded in this window — monitoring logs your apps reported, plus
            arena runs. Open a project to see it split by use case.
          </span>
        </div>

        <div
          id="usage-totals"
          style="display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:14px;"
        >
          <DS.stat_tile label="generations" value={compact(@totals.count)} icon="activity" />
          <DS.stat_tile
            label="errors"
            value={compact(@totals.error_count)}
            icon="alert"
            tone={@totals.error_count > 0 && :err}
          />
          <DS.stat_tile label="tokens" value={compact(@totals.tokens)} icon="cpu" />
          <DS.stat_tile label="cost" value={cost_label(@totals.cost_usd)} icon="dollar" />
        </div>

        <DS.empty
          :if={@rows == []}
          id="usage-empty"
          icon="layers"
          title="No projects yet"
          sub="Usage is counted per project — create one to see numbers here."
        />

        <DS.table :if={@rows != []} id="usage-table" cols={@cols}>
          <div :for={{row, index} <- Enum.with_index(@rows)}>
            <DS.row id={"usage-row-#{row.project.slug}"} cols={@cols} index={index}>
              <span style="display:flex;align-items:center;gap:7px;min-width:0;">
                <.link
                  id={"usage-toggle-#{row.project.slug}"}
                  patch={toggle_path(@org_slug, @period, @open, row.project.slug)}
                  title={if open?(@open, row.project), do: "Collapse", else: "Expand"}
                  aria-expanded={to_string(open?(@open, row.project))}
                  class="dsiconbtn tr"
                  style="width:22px;height:22px;flex-shrink:0;color:var(--tx-2);"
                >
                  <DSIcons.icon
                    name={if open?(@open, row.project), do: "chevDown", else: "chevRight"}
                    size={13}
                  />
                </.link>
                <span style={"width:8px;height:8px;border-radius:var(--r-pill);flex-shrink:0;background:#{row.color};"} />
                <.link
                  id={"usage-open-#{row.project.slug}"}
                  navigate={~p"/#{@org_slug}/#{row.project.slug}/use-cases"}
                  class="font-mono"
                  style="font-size:13px;color:inherit;text-decoration:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
                >
                  {row.project.slug}
                </.link>
              </span>
              <span class="font-mono" style="font-size:13px;text-align:right;">{row.count}</span>
              <span
                class="font-mono"
                style={"font-size:13px;text-align:right;color:#{if row.error_count > 0, do: "var(--err)", else: "var(--tx-2)"};"}
              >
                {row.error_count}
              </span>
              <span class="font-mono" style="font-size:13px;text-align:right;color:var(--tx-2);">
                {compact(row.tokens)}
              </span>
              <span class="font-mono" style="font-size:13px;text-align:right;">
                {cost_label(row.cost_usd)}
              </span>
            </DS.row>

            <div :if={open?(@open, row.project)} id={"usage-breakdown-#{row.project.slug}"}>
              <DS.row
                :for={uc <- @use_case_rows}
                id={"usage-uc-#{row.project.slug}-#{uc.use_case_key}"}
                cols={@cols}
                index={1}
                tone={:neutral}
              >
                <span style="display:flex;align-items:center;gap:7px;min-width:0;padding-left:29px;">
                  <DSIcons.icon name="target" size={12} class="tx3" />
                  <span
                    class="font-mono"
                    style="font-size:12.5px;color:var(--tx-1);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
                  >
                    {uc.use_case_key}
                  </span>
                </span>
                <span class="font-mono" style="font-size:12.5px;text-align:right;">
                  {uc.count}
                </span>
                <span
                  class="font-mono"
                  style={"font-size:12.5px;text-align:right;color:#{if uc.error_count > 0, do: "var(--err)", else: "var(--tx-2)"};"}
                >
                  {uc.error_count}
                </span>
                <span class="font-mono" style="font-size:12.5px;text-align:right;color:var(--tx-2);">
                  {compact(uc.tokens)}
                </span>
                <span class="font-mono" style="font-size:12.5px;text-align:right;">
                  {cost_label(uc.cost_usd)}
                </span>
              </DS.row>

              <DS.row
                :if={@use_case_rows == []}
                id={"usage-breakdown-empty-#{row.project.slug}"}
                cols={@cols}
                index={1}
                tone={:neutral}
              >
                <span style="font-size:12.5px;color:var(--tx-2);padding-left:29px;">
                  No generations in this window.
                </span>
              </DS.row>
            </div>
          </div>
        </DS.table>

        <SC.info_box id="usage-note" icon="info" style="margin-top:12px;">
          Cost comes from what the provider reported, or from the catalog price when it didn't.
          Billing does not exist yet — this page only counts what already happened.
        </SC.info_box>
      </DS.screen>
    </Layouts.app>
    """
  end
end
