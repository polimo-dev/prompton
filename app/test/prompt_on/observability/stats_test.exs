defmodule PromptOn.Observability.StatsTest do
  @moduledoc "On-demand time-series aggregation (plan.md §9.4)."

  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Observability.Stats

  setup do
    project = project_fixture()
    use_case = use_case_fixture(project, %{key: "chat_response"})
    %{project: project, use_case: use_case}
  end

  test "counts, tokens, cost and latency percentiles per bucket / group", %{
    project: project,
    use_case: use_case
  } do
    now = DateTime.utc_now()
    started = fn offset_s -> now |> DateTime.add(offset_s, :second) |> DateTime.to_iso8601() end

    payloads = [
      generation_payload_fixture(use_case, %{"latency_ms" => 100, "started_at" => started.(-10)}),
      generation_payload_fixture(use_case, %{"latency_ms" => 200, "started_at" => started.(-20)}),
      generation_payload_fixture(use_case, %{"latency_ms" => 300, "started_at" => started.(-30)}),
      generation_payload_fixture(use_case, %{
        "latency_ms" => 1_000,
        "started_at" => started.(-40),
        "finish_reason" => "length",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "cost_usd" => "0.5"}
      }),
      generation_payload_fixture(use_case, %{
        "latency_ms" => 50,
        "started_at" => started.(-50),
        "status" => "error",
        "error" => %{"kind" => "timeout"},
        "usage" => %{}
      }),
      generation_payload_fixture("other_use_case", %{
        "latency_ms" => 999,
        "started_at" => started.(-60)
      })
    ]

    assert %{accepted: 6, rejected: []} = ingest_fixture(project, payloads)

    from = DateTime.add(now, -1, :day)
    to = DateTime.add(now, 1, :minute)

    rows = Stats.time_series(project.id, from: from, to: to, bucket: :day)

    total =
      Enum.reduce(rows, %{count: 0, error: 0, trunc: 0}, fn r, acc ->
        %{
          count: acc.count + r.count,
          error: acc.error + r.error_count,
          trunc: acc.trunc + r.truncated_count
        }
      end)

    assert total == %{count: 6, error: 1, trunc: 1}
    assert length(rows) in 1..2
    assert Enum.all?(rows, &match?(%DateTime{}, &1.bucket))

    [row] =
      Stats.time_series(project.id,
        from: from,
        to: to,
        bucket: :day,
        use_case_key: "chat_response"
      )

    assert row.count == 5 and row.ok_count == 4 and row.error_count == 1 and
             row.truncated_count == 1

    assert row.group == nil
    # tokens: 100/20 × 3 + 10/5 + 0 = 310 / 65
    assert row.input_tokens == 310 and row.output_tokens == 65
    assert Decimal.equal?(row.cost_usd, Decimal.new("0.503"))
    # latency [50,100,200,300,1000]: p50 = 200, p95 = 860
    assert_in_delta row.p50_latency_ms, 200.0, 0.001
    assert_in_delta row.p95_latency_ms, 860.0, 0.001
    assert_in_delta row.avg_latency_ms, 330.0, 0.001

    grouped =
      Stats.time_series(project.id, from: from, to: to, bucket: :day, group_by: :use_case_key)

    counts =
      grouped
      |> Enum.group_by(& &1.group, & &1.count)
      |> Map.new(fn {k, v} -> {k, Enum.sum(v)} end)

    assert counts == %{"chat_response" => 5, "other_use_case" => 1}

    assert Stats.time_series(project.id,
             from: DateTime.add(now, 1, :hour),
             to: DateTime.add(now, 2, :hour)
           ) == []

    assert Stats.time_series(Ash.UUIDv7.generate(), from: from, to: to) == []

    assert_raise ArgumentError, fn ->
      Stats.time_series(project.id, from: from, group_by: :status)
    end
  end
end
