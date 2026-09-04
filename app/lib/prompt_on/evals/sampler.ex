defmodule PromptOn.Evals.Sampler do
  @moduledoc """
  Picks the monitoring logs an eval can actually look at (ADR 0010 §2.2).

  A log is **eligible** when it is a real production call (`source :live`, `status :ok`) that
  decided to keep its raw content (`payload_state :stored`) **and whose payload row still exists**.
  The two payload conditions are not redundant: `payload_state` records the decision made at
  ingest, while the row itself may have been deleted since by the payload retention purge. Both
  together mean "the raw content is really there right now".

  The query is built here rather than as a read action on `PromptOn.Observability.Generation`
  because the evals area does not edit the observability resources (ADR 0010 §7).

  `pick/2` reduces a candidate list to `n` **evenly spaced** entries, newest first. There is no
  RNG: clicking "Sample 10 logs" twice on unchanged data gives the same set, which is what makes
  the calibration flow and its tests reproducible.
  """

  require Ash.Query
  require Logger

  alias PromptOn.Observability.Generation

  @doc """
  The eligible logs of a use case, newest first.

  Returns `{:ok, generations}` or `{:error, error}`. It deliberately does **not** collapse a failure
  into `[]`: every caller turns "no rows" into a confident sentence ("this use case has no logs with
  stored log content"), and saying that because a read was forbidden or the database hiccuped is a
  lie the user cannot act on.

  Options: `:limit` (required), `:tenant` (required), `:actor` (default the system actor),
  `:deployment_id` and `:environment_id` (both optional filters).
  """
  @spec eligible(map(), keyword()) :: {:ok, [Generation.t()]} | {:error, term()}
  def eligible(use_case, opts) do
    limit = Keyword.fetch!(opts, :limit)
    tenant = Keyword.fetch!(opts, :tenant)
    actor = Keyword.get(opts, :actor) || PromptOn.SystemActor.new()

    Generation
    |> Ash.Query.for_read(:read, %{}, tenant: tenant, actor: actor)
    |> Ash.Query.filter(
      use_case_id == ^use_case.id and source == :live and status == :ok and
        payload_state == :stored and exists(payload, not is_nil(generation_id))
    )
    |> filter_deployment(Keyword.get(opts, :deployment_id))
    |> filter_environment(Keyword.get(opts, :environment_id))
    |> Ash.Query.sort(started_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read()
  end

  @doc """
  `eligible/2` with the error already reduced to a count and a flag, for a screen that only needs
  "how many, and was the number trustworthy": `{count, ok?}`. The error itself is logged id-only —
  an Ash error carries the query, and this query names the tenant.
  """
  @spec count_eligible(map(), keyword()) :: {non_neg_integer(), boolean()}
  def count_eligible(use_case, opts) do
    case eligible(use_case, opts) do
      {:ok, generations} ->
        {length(generations), true}

      {:error, _error} ->
        Logger.warning("evals: could not read eligible logs of use case #{use_case.id}")
        {0, false}
    end
  end

  @doc """
  `n` evenly spaced entries of `candidates`, in the candidate order. Fewer candidates than `n`
  returns them all. The stride is `div(length, n)`, so the picks span the whole window instead of
  clustering at the newest end.

      iex> PromptOn.Evals.Sampler.pick([1, 2, 3, 4, 5, 6], 3)
      [1, 3, 5]

      iex> PromptOn.Evals.Sampler.pick([1, 2], 5)
      [1, 2]
  """
  @spec pick([term()], pos_integer()) :: [term()]
  def pick(candidates, n) when is_list(candidates) and is_integer(n) and n > 0 do
    length = length(candidates)

    if length <= n do
      candidates
    else
      stride = div(length, n)

      candidates
      |> Enum.with_index()
      |> Enum.filter(fn {_item, index} -> rem(index, stride) == 0 end)
      |> Enum.take(n)
      |> Enum.map(fn {item, _index} -> item end)
    end
  end

  defp filter_deployment(query, nil), do: query
  defp filter_deployment(query, id), do: Ash.Query.filter(query, deployment_id == ^id)

  defp filter_environment(query, nil), do: query
  defp filter_environment(query, id), do: Ash.Query.filter(query, environment_id == ^id)
end
