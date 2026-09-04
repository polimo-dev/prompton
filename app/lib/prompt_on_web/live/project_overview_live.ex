defmodule PromptOnWeb.ProjectOverviewLive do
  @moduledoc """
  Project overview (`/:org_slug/:project_slug`), the project's **root screen**.

  Every number comes only from what already exists. This screen aggregates nothing new:

  | Block | Source |
  |---|---|
  | generations · errors · tokens · cost | `PromptOn.Observability.Stats.time_series/2` (`source: nil`: monitoring logs and arena alike) |
  | use case count and whether deployed | `PromptOn.Prompts.list_use_cases/1` + the live `Deployment` per environment |
  | live deployment count per environment | `PromptOn.Deployments.current_deployments_for_environment/2` |
  | how long those logs live | `PromptOnWeb.SettingsComponents.retention_note/1` ← `PromptOn.Entitlements` |

  The period travels in the URL as `?period=24h\\|7d\\|30d` (CLAUDE.md zero-downtime deployment
  discipline). The segment definitions and number formatting (`compact/1` `cost_label/1`) are taken
  as is from the organization Usage screen (`PromptOnWeb.OrgUsageLive`): two screens must not round
  the same fact differently.

  **What does not exist is not drawn** (CLAUDE.md UI section): slots like a success rate trend, a
  latency graph or a cost budget get attached when a rollup table or a budget domain appears. Every
  number on the screen right now comes from real rows.
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Deployments
  alias PromptOn.Entitlements
  alias PromptOn.Observability.Stats
  alias PromptOn.Prompts
  alias PromptOnWeb.OrgUsageLive
  alias PromptOnWeb.SettingsComponents, as: SC

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Overview · #{socket.assigns.project.slug}",
       period: default_period(),
       totals: empty_totals()
     )
     |> load_deployments()
     |> load_use_cases()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    period = period_param(params)

    {:noreply, assign(socket, period: period, totals: totals(socket, period))}
  end

  # ---------------------------------------------------------------------------
  # Period (URL state)

  defp periods, do: OrgUsageLive.periods()

  defp default_period, do: periods() |> hd() |> elem(0)

  defp period_param(%{"period" => value}) do
    if Enum.any?(periods(), fn {v, _label, _days} -> v == value end),
      do: value,
      else: default_period()
  end

  defp period_param(_params), do: default_period()

  defp period_days(period) do
    Enum.find_value(periods(), 1, fn {v, _label, days} -> v == period && days end)
  end

  # ---------------------------------------------------------------------------
  # Data

  defp scope(socket),
    do: [tenant: socket.assigns.project.id, actor: socket.assigns.current_user]

  # An aggregation failure must not kill the screen; it falls back to 0 (the same rule as
  # `OrgUsageLive`).
  defp totals(socket, period) do
    from = DateTime.add(DateTime.utc_now(), -period_days(period) * 86_400, :second)

    socket.assigns.project.id
    |> Stats.time_series(from: from, bucket: :day, source: nil)
    |> Enum.reduce(empty_totals(), fn row, acc ->
      %{
        count: acc.count + row.count,
        error_count: acc.error_count + row.error_count,
        tokens: acc.tokens + row.input_tokens + row.output_tokens,
        cost_usd: Decimal.add(acc.cost_usd, row.cost_usd)
      }
    end)
  rescue
    _ -> empty_totals()
  end

  defp empty_totals, do: %{count: 0, error_count: 0, tokens: 0, cost_usd: Decimal.new(0)}

  # Read the live deployments **once** per environment (`current_for_environment` returns one row
  # per use case, its highest revision). That single result is folded into both the per-environment
  # count and "which environments is each use case live in".
  defp load_deployments(socket) do
    opts = scope(socket)

    {rows, live_envs} =
      Enum.reduce(socket.assigns.envs, {[], %{}}, fn env, {rows, live_envs} ->
        deployments = live_deployments(env, opts)

        live_envs =
          Enum.reduce(deployments, live_envs, fn deployment, acc ->
            Map.update(acc, deployment.use_case_id, [env.slug], &(&1 ++ [env.slug]))
          end)

        {rows ++ [%{env: env, count: length(deployments)}], live_envs}
      end)

    assign(socket, env_rows: rows, live_envs: live_envs)
  end

  defp live_deployments(env, opts) do
    case Deployments.current_deployments_for_environment(env.id, opts) do
      {:ok, deployments} -> deployments
      {:error, _error} -> []
    end
  end

  defp load_use_cases(socket) do
    use_cases =
      case Prompts.list_use_cases(scope(socket)) do
        {:ok, list} -> Enum.sort_by(list, & &1.key)
        {:error, _error} -> []
      end

    assign(socket, :use_cases, use_cases)
  end

  @doc """
  The line naming the environments a use case is live in. With no deployment it is
  `"not deployed"`; never a blank cell (`—`).

      iex> PromptOnWeb.ProjectOverviewLive.live_label([])
      "not deployed"

      iex> PromptOnWeb.ProjectOverviewLive.live_label(["production"])
      "live in production"

      iex> PromptOnWeb.ProjectOverviewLive.live_label(["production", "staging"])
      "live in production, staging"
  """
  @spec live_label([String.t()]) :: String.t()
  def live_label([]), do: "not deployed"
  def live_label(env_slugs), do: "live in " <> Enum.join(env_slugs, ", ")

  @doc """
  Number of use cases with at least one live deployment.

      iex> PromptOnWeb.ProjectOverviewLive.deployed_count(%{"a" => ["production"]})
      1

      iex> PromptOnWeb.ProjectOverviewLive.deployed_count(%{})
      0
  """
  @spec deployed_count(map()) :: non_neg_integer()
  def deployed_count(live_envs), do: map_size(live_envs)

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
      nav={:overview}
    >
      <DS.screen
        id="project-overview-screen"
        title="Overview"
        sub={@project.name}
        max_w={980}
      >
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <:crumb label={@project.slug} />
        <:actions>
          <DS.seg
            id="overview-period"
            value={@period}
            options={
              for {value, label, _days} <- periods() do
                %{
                  value: value,
                  label: label,
                  patch: ~p"/#{@org_slug}/#{@project.slug}?period=#{value}"
                }
              end
            }
          />
        </:actions>

        <div
          id="overview-totals"
          style="display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:14px;"
        >
          <DS.stat_tile
            label="generations"
            value={OrgUsageLive.compact(@totals.count)}
            icon="activity"
          />
          <DS.stat_tile
            label="errors"
            value={OrgUsageLive.compact(@totals.error_count)}
            icon="alert"
            tone={@totals.error_count > 0 && :err}
          />
          <DS.stat_tile label="tokens" value={OrgUsageLive.compact(@totals.tokens)} icon="cpu" />
          <DS.stat_tile
            label="cost"
            value={OrgUsageLive.cost_label(@totals.cost_usd)}
            icon="dollar"
          />
        </div>

        <SC.retention_note id="overview-retention-note" plan={Entitlements.plan(@organization)} />

        <SC.setting_card
          id="overview-use-cases-card"
          title="Use cases"
          desc="A use case is the unit the SDK asks for. It goes live by being deployed to an environment."
        >
          <div
            id="overview-use-case-count"
            style="font-size:13px;color:var(--tx-2);margin-bottom:10px;"
          >
            <span class="font-mono" style="color:var(--tx-0);">{length(@use_cases)}</span>
            defined ·
            <span class="font-mono" style="color:var(--tx-0);">{deployed_count(@live_envs)}</span>
            with a live deployment
          </div>

          <div :if={@use_cases == []} style="font-size:13px;color:var(--tx-2);">
            No use cases yet.
          </div>
          <div :if={@use_cases != []} style="display:flex;flex-direction:column;gap:6px;">
            <SC.row_box :for={use_case <- @use_cases} id={"overview-use-case-#{use_case.key}"}>
              <DSIcons.icon name="target" size={14} class="tx2" />
              <.link
                navigate={~p"/#{@org_slug}/#{@project.slug}/use-cases/#{use_case.key}/prompt"}
                class="font-mono"
                style="font-size:13.5px;font-weight:500;color:var(--tx-0);text-decoration:none;"
              >
                {use_case.key}
              </.link>
              <DS.badge tone={:neutral} mono style="font-size:10px;">{use_case.kind}</DS.badge>
              <span style="margin-left:auto;font-size:12px;color:var(--tx-2);white-space:nowrap;">
                {live_label(Map.get(@live_envs, use_case.id, []))}
              </span>
            </SC.row_box>
          </div>
          <:footer>
            <DS.btn_link
              id="overview-open-use-cases"
              variant="outline"
              icon="target"
              style="margin-left:auto;"
              navigate={~p"/#{@org_slug}/#{@project.slug}/use-cases"}
            >
              Open use cases
            </DS.btn_link>
          </:footer>
        </SC.setting_card>

        <SC.setting_card
          id="overview-environments-card"
          title="Environments"
          desc="Each environment serves the latest committed deployment revision of every use case."
        >
          <div style="display:flex;flex-direction:column;gap:6px;">
            <SC.row_box :for={row <- @env_rows} id={"overview-env-#{row.env.slug}"}>
              <DSIcons.icon
                name={if row.env.protected?, do: "lock", else: "globe"}
                size={14}
                class="tx2"
              />
              <span class="font-mono" style="font-size:13.5px;font-weight:500;">{row.env.slug}</span>
              <DS.badge :if={row.env.protected?} tone={:accent} mono style="font-size:10px;">
                protected
              </DS.badge>
              <span class="font-mono" style="margin-left:auto;font-size:12px;color:var(--tx-2);">
                {row.count} live deployments
              </span>
            </SC.row_box>
          </div>
          <:footer>
            <DS.btn_link
              id="overview-open-settings"
              variant="ghost"
              icon="settings"
              style="margin-left:auto;"
              navigate={~p"/#{@org_slug}/#{@project.slug}/settings"}
            >
              Project settings
            </DS.btn_link>
          </:footer>
        </SC.setting_card>

        <SC.info_box id="overview-note" icon="info">
          Every number on this page is counted from rows that already exist — generations recorded in
          the selected window (monitoring logs your apps reported, plus arena runs) and deployment
          revisions that are live right now.
        </SC.info_box>
      </DS.screen>
    </Layouts.app>
    """
  end
end
