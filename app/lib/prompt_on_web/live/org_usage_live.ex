defmodule PromptOnWeb.OrgUsageLive do
  @moduledoc """
  Organization usage (`/:org_slug/usage?period=24h|7d|30d`).

  Logs, errors and tokens count monitoring and Arena generations. Costs also include Draft and
  Evaluation calls. One `PromptOn.Observability.Usage.for_project/2` snapshot per authorized project
  supplies both its totals and per-use-case breakdown, including use cases with only AI usage.

  The period and expanded project stay in the URL. Project access is refreshed before each query,
  because the aggregation leaves authorization to the caller.
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Observability.Usage
  alias PromptOnWeb.SettingsComponents, as: SC

  @periods [
    {"24h", "24h", 1},
    {"7d", "7d", 7},
    {"30d", "30d", 30}
  ]

  @cols [
    %{label: "project", w: "minmax(180px,2fr)"},
    %{label: "logs", w: "56px", align: "right"},
    %{label: "errors", w: "56px", align: "right"},
    %{label: "tokens", w: "70px", align: "right"},
    %{label: "calls cost", w: "100px", align: "right"},
    %{label: "draft", w: "100px", align: "right"},
    %{label: "evaluation", w: "100px", align: "right"},
    %{label: "total cost", w: "110px", align: "right"}
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
       usage_error?: false
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    # Grants may change while this LiveView is connected. Usage bypasses resource policies,
    # so refresh the authorized project list before every aggregation.
    projects =
      PromptOnWeb.LiveProjectScope.list_projects(
        socket.assigns.organization,
        socket.assigns.current_user
      )

    period = period_param(params)

    # Compute the window **once** so the project totals and the use case breakdown see the same
    # `[from, to)`; if each called `utc_now/0`, one generation arriving in between would put the
    # totals out of step.
    window = window(period)
    open = open_param(params, projects)
    {rows, usage_error?} = usage_rows(projects, window)

    {:noreply,
     assign(socket,
       projects: projects,
       period: period,
       open: open,
       rows: rows,
       totals: totals(rows),
       usage_error?: usage_error?
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

  defp usage_rows(projects, window) do
    {Enum.map(projects, &usage_row(&1, window)), false}
  rescue
    _ -> {[], true}
  end

  defp usage_row(project, {from, to}) do
    rows = Usage.for_project(project.id, from: from, to: to)

    Map.merge(totals(rows), %{
      project: project,
      color: DS.project_color(project.slug),
      use_case_rows: rows
    })
  end

  defp totals(rows) do
    Enum.reduce(rows, empty_totals(), fn row, acc ->
      %{
        count: acc.count + row.count,
        error_count: acc.error_count + row.error_count,
        tokens: acc.tokens + row.tokens,
        calls_cost_usd: Decimal.add(acc.calls_cost_usd, row.calls_cost_usd),
        draft_cost_usd: Decimal.add(acc.draft_cost_usd, row.draft_cost_usd),
        evaluation_cost_usd: Decimal.add(acc.evaluation_cost_usd, row.evaluation_cost_usd),
        cost_usd: Decimal.add(acc.cost_usd, row.cost_usd),
        unknown_cost_count: acc.unknown_cost_count + row.unknown_cost_count
      }
    end)
  end

  defp empty_totals do
    %{
      count: 0,
      error_count: 0,
      tokens: 0,
      calls_cost_usd: Decimal.new(0),
      draft_cost_usd: Decimal.new(0),
      evaluation_cost_usd: Decimal.new(0),
      cost_usd: Decimal.new(0),
      unknown_cost_count: 0
    }
  end

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
        max_w={1180}
      >
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <div style="display:flex;align-items:center;flex-wrap:wrap;gap:10px;margin-bottom:12px;">
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
            Logs, errors and tokens cover monitoring and Arena calls. Costs also include Draft and
            Evaluation. Expand a project to see its use cases.
          </span>
        </div>

        <div
          :if={!@usage_error?}
          id="usage-totals"
          style="display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-bottom:14px;"
        >
          <DS.stat_tile label="logs" value={compact(@totals.count)} icon="activity" />
          <DS.stat_tile
            label="errors"
            value={compact(@totals.error_count)}
            icon="alert"
            tone={@totals.error_count > 0 && :err}
          />
          <DS.stat_tile label="tokens" value={compact(@totals.tokens)} icon="cpu" />
          <DS.stat_tile label="total cost" value={cost_label(@totals.cost_usd)} icon="dollar" />
        </div>

        <div
          :if={!@usage_error?}
          id="usage-cost-breakdown"
          style="display:flex;flex-wrap:wrap;gap:8px 24px;margin-bottom:16px;font-size:12.5px;color:var(--tx-2);"
        >
          <span id="usage-cost-calls">
            Monitoring + Arena <strong class="font-mono">{cost_label(@totals.calls_cost_usd)}</strong>
          </span>
          <span id="usage-cost-draft">
            Draft <strong class="font-mono">{cost_label(@totals.draft_cost_usd)}</strong>
          </span>
          <span id="usage-cost-evaluation">
            Evaluation <strong class="font-mono">{cost_label(@totals.evaluation_cost_usd)}</strong>
          </span>
        </div>

        <SC.info_box :if={@usage_error?} id="usage-load-error" icon="alert">
          Usage could not be loaded.
          <.link patch={usage_path(@org_slug, @period, @open)} class="underline">Try again</.link>
        </SC.info_box>

        <DS.empty
          :if={@rows == [] && !@usage_error?}
          id="usage-empty"
          icon="layers"
          title="No projects yet"
          sub="Usage is counted per project — create one to see numbers here."
        />

        <div :if={@rows != []} id="usage-table-scroll" style="overflow-x:auto;">
          <DS.table id="usage-table" cols={@cols} style="min-width:900px;">
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
                    patch={toggle_path(@org_slug, @period, @open, row.project.slug)}
                    aria-expanded={to_string(open?(@open, row.project))}
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
                  {cost_label(row.calls_cost_usd)}
                </span>
                <span class="font-mono" style="font-size:13px;text-align:right;">
                  {cost_label(row.draft_cost_usd)}
                </span>
                <span class="font-mono" style="font-size:13px;text-align:right;">
                  {cost_label(row.evaluation_cost_usd)}
                </span>
                <span class="font-mono" style="font-size:13px;text-align:right;font-weight:600;">
                  {cost_label(row.cost_usd)}
                </span>
              </DS.row>

              <div :if={open?(@open, row.project)} id={"usage-breakdown-#{row.project.slug}"}>
                <DS.row
                  :for={uc <- row.use_case_rows}
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
                    {cost_label(uc.calls_cost_usd)}
                  </span>
                  <span class="font-mono" style="font-size:12.5px;text-align:right;">
                    {cost_label(uc.draft_cost_usd)}
                  </span>
                  <span class="font-mono" style="font-size:12.5px;text-align:right;">
                    {cost_label(uc.evaluation_cost_usd)}
                  </span>
                  <span class="font-mono" style="font-size:12.5px;text-align:right;font-weight:600;">
                    {cost_label(uc.cost_usd)}
                  </span>
                </DS.row>

                <DS.row
                  :if={row.use_case_rows == []}
                  id={"usage-breakdown-empty-#{row.project.slug}"}
                  cols={@cols}
                  index={1}
                  tone={:neutral}
                >
                  <span style="grid-column:1 / -1;font-size:12.5px;color:var(--tx-2);padding-left:29px;">
                    No usage in this window.
                  </span>
                </DS.row>
              </div>
            </div>
          </DS.table>
        </div>

        <SC.info_box
          :if={!@usage_error? && @totals.unknown_cost_count > 0}
          id="usage-incomplete-costs"
          icon="info"
          style="margin-top:12px;"
        >
          Calls with unavailable cost: {@totals.unknown_cost_count}. Totals include known costs only.
        </SC.info_box>

        <SC.info_box id="usage-note" icon="info" style="margin-top:12px;">
          Calls cost covers monitoring and Arena. Costs use provider reports or available catalog
          prices. Historical Evaluation costs include retained scores only; earlier Draft,
          rubric-generation and overwritten score costs are unavailable.
        </SC.info_box>
      </DS.screen>
    </Layouts.app>
    """
  end
end
