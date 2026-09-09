defmodule PromptOn.Observability.UsageTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Observability
  alias PromptOn.Observability.{Generation, Usage}

  setup do
    project = project_fixture()
    use_case = use_case_fixture(project, %{key: "chat_response"})
    to = DateTime.utc_now()
    from = DateTime.add(to, -1, :hour)
    %{project: project, use_case: use_case, from: from, to: to}
  end

  test "costs combine by use case while counts, errors and tokens describe monitoring calls",
       ctx do
    started_at = DateTime.add(ctx.to, -10, :second)

    assert %{accepted: 2, rejected: []} =
             ingest_fixture(ctx.project, [
               log(ctx.use_case, started_at, "0.25"),
               log(ctx.use_case, started_at, "0.5", %{
                 "status" => "error",
                 "error" => %{"kind" => "timeout"}
               })
             ])

    record_ai(ctx.project, ctx.use_case.key, :draft, started_at, "0.125")
    record_ai(ctx.project, ctx.use_case.key, :evaluation, started_at, "0.375")

    assert [row] = usage(ctx)
    assert row.use_case_key == ctx.use_case.key
    assert row.count == 2
    assert row.error_count == 1
    assert row.tokens == 240
    assert row.unknown_cost_count == 0
    assert_costs(row, "0.75", "0.125", "0.375", "1.25")
  end

  test "both cost sources include from and exclude to at microsecond precision", ctx do
    for {started_at, cost} <- [
          {DateTime.add(ctx.from, -1, :microsecond), "10"},
          {ctx.from, "1"},
          {DateTime.add(ctx.to, -1, :microsecond), "2"},
          {ctx.to, "20"}
        ] do
      assert %{accepted: 1, rejected: []} =
               ingest_fixture(ctx.project, [log(ctx.use_case, started_at, cost)])

      for operation <- [:draft, :evaluation] do
        record_ai(ctx.project, ctx.use_case.key, operation, started_at, cost)
      end
    end

    assert [row] = usage(ctx)
    assert row.count == 2
    assert row.error_count == 0
    assert row.tokens == 240
    assert_costs(row, "3", "3", "3", "9")
  end

  test "AI-only use cases appear separately without creating monitoring logs", ctx do
    started_at = DateTime.add(ctx.to, -10, :second)
    draft_case = use_case_fixture(ctx.project, %{key: "draft_only"})
    evaluation_case = use_case_fixture(ctx.project, %{key: "evaluation_only"})

    record_ai(ctx.project, draft_case.key, :draft, started_at, "0.4")
    record_ai(ctx.project, evaluation_case.key, :evaluation, started_at, "0.6")

    rows = Map.new(usage(ctx), &{&1.use_case_key, &1})
    assert Map.keys(rows) |> Enum.sort() == ["draft_only", "evaluation_only"]
    assert_costs(rows[draft_case.key], "0", "0.4", "0", "0.4")
    assert_costs(rows[evaluation_case.key], "0", "0", "0.6", "0.6")

    for row <- Map.values(rows) do
      assert row.count == 0
      assert row.error_count == 0
      assert row.tokens == 0
    end

    assert Ash.read!(Generation, scope(ctx.project)) == []
  end

  test "unknown costs are counted while explicit zero costs are complete", ctx do
    started_at = DateTime.add(ctx.to, -10, :second)

    assert %{accepted: 2, rejected: []} =
             ingest_fixture(ctx.project, [
               log(ctx.use_case, started_at, nil),
               log(ctx.use_case, started_at, "0")
             ])

    record_ai(ctx.project, ctx.use_case.key, :draft, started_at, nil)
    record_ai(ctx.project, ctx.use_case.key, :evaluation, started_at, "0")

    assert [row] = usage(ctx)
    assert row.unknown_cost_count == 2
    assert row.count == 2
    assert row.tokens == 240
    assert_costs(row, "0", "0", "0", "0")
  end

  test "repeated calls all count toward cost without crossing project boundaries", ctx do
    other = project_fixture()
    started_at = DateTime.add(ctx.to, -10, :second)

    for _attempt <- 1..3 do
      record_ai(ctx.project, ctx.use_case.key, :draft, started_at, "0.1")
      record_ai(ctx.project, ctx.use_case.key, :evaluation, started_at, "0.2")
    end

    record_ai(other, ctx.use_case.key, :draft, started_at, "100")
    record_ai(other, ctx.use_case.key, :evaluation, started_at, "200")

    assert %{accepted: 1, rejected: []} =
             ingest_fixture(other, [log(ctx.use_case, started_at, "300")])

    assert [row] = usage(ctx)
    assert row.count == 0
    assert row.tokens == 0
    assert_costs(row, "0", "0.3", "0.6", "0.9")

    assert [other_row] = Usage.for_project(other.id, from: ctx.from, to: ctx.to)
    assert other_row.count == 1
    assert_costs(other_row, "300", "100", "200", "600")

    assert Usage.for_project(Ash.UUIDv7.generate(), from: ctx.from, to: ctx.to) == []
  end

  defp usage(ctx), do: Usage.for_project(ctx.project.id, from: ctx.from, to: ctx.to)

  defp record_ai(project, use_case_key, operation, started_at, cost) do
    Observability.record_ai_usage!(
      %{
        use_case_key: use_case_key,
        operation: operation,
        model: "openai/test-model",
        input_tokens: 1_000,
        output_tokens: 500,
        cost_usd: cost,
        started_at: started_at
      },
      scope(project)
    )
  end

  defp log(use_case, started_at, cost, attrs \\ %{}) do
    generation_payload_fixture(
      use_case,
      Map.merge(
        %{
          "started_at" => DateTime.to_iso8601(started_at),
          "usage" => %{"input_tokens" => 100, "output_tokens" => 20, "cost_usd" => cost}
        },
        attrs
      )
    )
  end

  defp assert_costs(row, calls, draft, evaluation, total) do
    assert Decimal.equal?(row.calls_cost_usd, calls)
    assert Decimal.equal?(row.draft_cost_usd, draft)
    assert Decimal.equal?(row.evaluation_cost_usd, evaluation)
    assert Decimal.equal?(row.cost_usd, total)
  end
end
