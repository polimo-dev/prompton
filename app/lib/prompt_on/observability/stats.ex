defmodule PromptOn.Observability.Stats do
  @moduledoc """
  Dashboard aggregation -- on-demand raw scans (plan.md §9.4). Reads only the narrow `generations`
  table (`date_trunc` + `percentile_cont`). Rollup tables are P2.

  It queries through Ecto directly, so **authorization is the caller's responsibility** (the
  LiveView calls it only for project members). The `project_id` argument is the tenant boundary.
  """

  import Ecto.Query

  alias PromptOn.Observability.Generation
  alias PromptOn.Repo

  @buckets %{minute: "minute", hour: "hour", day: "day"}
  @group_bys [:use_case_key, :prompt, :model, :deployment_id, :environment_id]

  @type row :: %{
          bucket: DateTime.t(),
          group: term() | nil,
          count: non_neg_integer(),
          ok_count: non_neg_integer(),
          error_count: non_neg_integer(),
          truncated_count: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cost_usd: Decimal.t(),
          p50_latency_ms: float() | nil,
          p95_latency_ms: float() | nil,
          avg_latency_ms: float() | nil
        }

  @doc """
  Time-series aggregation. Options:

  - `from:` (required), `to:` (default now) -- `started_at` range `[from, to)`
  - `bucket:` `:minute | :hour | :day` (default `:hour`)
  - `group_by:` `nil | :use_case_key | :prompt | :model | :deployment_id | :environment_id`
  - Filters: `use_case_key:`, `prompt:`, `deployment_id:`, `environment_id:`, `source:` (default
    `:live`; `nil` means all)

  The result is a list of `row()` sorted by `bucket asc, group asc`. Truncated = `stop_kind ==
  :length`.
  """
  @spec time_series(Ecto.UUID.t(), keyword()) :: [row()]
  def time_series(project_id, opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.get(opts, :to) || DateTime.utc_now()
    bucket = Map.fetch!(@buckets, Keyword.get(opts, :bucket, :hour))
    group_by = Keyword.get(opts, :group_by)

    if group_by && group_by not in @group_bys do
      raise ArgumentError, "group_by must be one of #{inspect(@group_bys)}"
    end

    query =
      from(g in Generation,
        where: g.project_id == ^project_id and g.started_at >= ^from and g.started_at < ^to
      )
      |> apply_filters(opts)
      |> select_stats(bucket)
      |> group(bucket, group_by)

    query
    |> Repo.all()
    |> Enum.map(&normalize_row/1)
  end

  defp apply_filters(query, opts) do
    query =
      case Keyword.get(opts, :source, :live) do
        nil -> query
        source -> where(query, [g], g.source == ^source)
      end

    Enum.reduce([:use_case_key, :prompt, :deployment_id, :environment_id], query, fn key, q ->
      case Keyword.get(opts, key) do
        nil -> q
        value -> where(q, [g], field(g, ^key) == ^value)
      end
    end)
  end

  defp select_stats(query, bucket) do
    select(query, [g], %{
      bucket: selected_as(fragment("date_trunc(?, ?)", ^bucket, g.started_at), :bucket),
      count: count(g.id),
      ok_count: filter(count(g.id), g.status == ^:ok),
      error_count: filter(count(g.id), g.status == ^:error),
      truncated_count: filter(count(g.id), g.stop_kind == ^:length),
      input_tokens: type(coalesce(sum(g.input_tokens), 0), :integer),
      output_tokens: type(coalesce(sum(g.output_tokens), 0), :integer),
      cost_usd: coalesce(sum(g.cost_usd), 0),
      p50_latency_ms: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", g.latency_ms),
      p95_latency_ms: fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", g.latency_ms),
      avg_latency_ms: type(avg(g.latency_ms), :float)
    })
  end

  defp group(query, _bucket, nil) do
    query
    |> group_by([g], selected_as(:bucket))
    |> order_by([g], asc: selected_as(:bucket))
    |> select_merge([g], %{group: nil})
  end

  defp group(query, _bucket, group_by) do
    query
    |> group_by([g], [selected_as(:bucket), field(g, ^group_by)])
    |> order_by([g], asc: selected_as(:bucket), asc: field(g, ^group_by))
    |> select_merge([g], %{group: field(g, ^group_by)})
  end

  defp normalize_row(row) do
    row
    |> Map.update!(:bucket, &to_utc/1)
    |> Map.update!(:cost_usd, &to_decimal/1)
  end

  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_utc(%DateTime{} = dt), do: dt

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(nil), do: Decimal.new(0)
end
