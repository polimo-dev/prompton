defmodule PromptOn.Observability.Usage do
  @moduledoc """
  Organization Usage aggregation, grouped by use case within an authorized project.

  Like Stats, this reads through Ecto and the caller must authorize the project first. A single
  SQL snapshot combines monitoring/Arena logs and the separate AI usage ledger. Log counts,
  errors and tokens retain their monitoring/Arena meaning; cost totals include all three kinds.
  """

  import Ecto.Query

  alias PromptOn.Observability.{AIUsage, Generation}
  alias PromptOn.Repo

  @spec for_project(Ecto.UUID.t(), keyword()) :: [map()]
  def for_project(project_id, opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)

    calls =
      from(g in Generation,
        where: g.project_id == ^project_id and g.started_at >= ^from and g.started_at < ^to,
        group_by: g.use_case_key,
        select: %{
          use_case_key: g.use_case_key,
          count: count(g.id),
          error_count: filter(count(g.id), g.status == ^:error),
          tokens:
            type(coalesce(sum(g.input_tokens), 0) + coalesce(sum(g.output_tokens), 0), :integer),
          calls_cost_usd: coalesce(sum(g.cost_usd), 0),
          draft_cost_usd: type(^0, :decimal),
          evaluation_cost_usd: type(^0, :decimal),
          unknown_cost_count: filter(count(g.id), is_nil(g.cost_usd))
        }
      )

    ai =
      from(u in AIUsage,
        where: u.project_id == ^project_id and u.started_at >= ^from and u.started_at < ^to,
        group_by: u.use_case_key,
        select: %{
          use_case_key: u.use_case_key,
          count: type(^0, :integer),
          error_count: type(^0, :integer),
          tokens: type(^0, :integer),
          calls_cost_usd: type(^0, :decimal),
          draft_cost_usd: coalesce(filter(sum(u.cost_usd), u.operation == ^:draft), 0),
          evaluation_cost_usd: coalesce(filter(sum(u.cost_usd), u.operation == ^:evaluation), 0),
          unknown_cost_count: filter(count(u.id), is_nil(u.cost_usd))
        }
      )

    combined = union_all(calls, ^ai)

    from(row in subquery(combined),
      group_by: row.use_case_key,
      order_by: [desc: sum(row.count), asc: row.use_case_key],
      select: %{
        use_case_key: row.use_case_key,
        count: type(sum(row.count), :integer),
        error_count: type(sum(row.error_count), :integer),
        tokens: type(sum(row.tokens), :integer),
        calls_cost_usd: sum(row.calls_cost_usd),
        draft_cost_usd: sum(row.draft_cost_usd),
        evaluation_cost_usd: sum(row.evaluation_cost_usd),
        unknown_cost_count: type(sum(row.unknown_cost_count), :integer)
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      total =
        row.calls_cost_usd
        |> Decimal.add(row.draft_cost_usd)
        |> Decimal.add(row.evaluation_cost_usd)

      Map.put(row, :cost_usd, total)
    end)
  end
end
