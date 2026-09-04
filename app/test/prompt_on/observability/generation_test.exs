defmodule PromptOn.Observability.GenerationTest do
  @moduledoc "Generation `:ingest` + the Ingest service (plan.md §5.7, §6.4, §9.2)."

  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Observability
  alias PromptOn.Observability.{Generation, Ingest}

  setup do
    project = project_fixture()
    use_case = use_case_fixture(project, %{key: "diary_generation"})
    {api_key, _raw} = api_key_fixture(project, scopes: [:logs])
    %{project: project, use_case: use_case, api_key: api_key}
  end

  defp list(project) do
    {:ok, page} = Observability.list_generations(scope(project))
    page.results
  end

  describe "ingest" do
    test "stores a valid record with use_case resolved and metadata moved", %{
      project: project,
      use_case: use_case
    } do
      payload = generation_payload_fixture(use_case, %{"error" => %{"status" => 200}})
      assert %{accepted: 1, duplicates: 0, rejected: []} = ingest_fixture(project, [payload])

      [gen] = list(project)
      assert gen.id == payload["id"]
      assert gen.use_case_id == use_case.id
      assert gen.use_case_key == "diary_generation"
      assert gen.model == "anthropic/claude-sonnet-4"
      assert gen.provider == :openrouter
      assert gen.status == :ok
      assert gen.stop_kind == :stop
      assert gen.finish_reason == "stop"
      assert gen.input_tokens == 100 and gen.output_tokens == 20
      assert Decimal.equal?(gen.cost_usd, Decimal.new("0.001"))
      assert gen.cost_source == :provider
      assert gen.source == :live
      assert gen.kind == :chat
      assert gen.resolution_source == :remote
      assert gen.trace_id == "oban:1" and gen.sequence == 1
      assert gen.end_user_ref == "u_1"
      assert gen.sdk_version == "0.2.0"
      assert gen.context == %{"language" => "ko", "plan" => "pro"}
      assert gen.params == %{"temperature" => 0.5}
      assert gen.metadata["job_id"] == 1
      assert gen.metadata["model_used"] == "anthropic/claude-sonnet-4"
      assert gen.metadata["upstream_provider"] == "Anthropic"
      assert gen.metadata["http_status"] == 200
      assert gen.payload_state == :stored
      assert %DateTime{} = gen.received_at

      loaded = Ash.load!(gen, [:truncated?, :total_tokens], scope(project))
      assert loaded.truncated? == false
      assert loaded.total_tokens == 120
    end

    test "duplicate ids: same batch twice and resend are absorbed", %{
      project: project,
      use_case: use_case
    } do
      payload = generation_payload_fixture(use_case)

      assert %{accepted: 1, duplicates: 1, rejected: []} =
               ingest_fixture(project, [payload, payload])

      assert %{accepted: 0, duplicates: 1, rejected: []} = ingest_fixture(project, [payload])
      assert length(list(project)) == 1
    end

    test "environment is forced by the request while use-case source is preserved", %{
      project: project,
      use_case: use_case
    } do
      staging = environment(project, "staging")
      production = environment(project, "production")
      {api_key, _} = api_key_fixture(project, scopes: [:logs])

      payload =
        generation_payload_fixture(use_case, %{
          "environment_id" => production.id,
          "project_id" => Ash.UUIDv7.generate(),
          "source" => "disk"
        })

      # the request picked staging, so even though the record claims production it is recorded
      # under staging.
      assert %{accepted: 1} =
               ingest_fixture(project, [payload], api_key: api_key, env: "staging")

      [gen] = list(project)
      assert gen.environment_id == staging.id
      assert gen.project_id == project.id
      assert gen.source == :live
      assert gen.resolution_source == :disk
    end

    test "unknown use_case key is stored with use_case_id nil", %{project: project} do
      payload = generation_payload_fixture("not_registered_yet")
      assert %{accepted: 1, rejected: []} = ingest_fixture(project, [payload])
      [gen] = list(project)
      assert gen.use_case_key == "not_registered_yet"
      assert gen.use_case_id == nil
    end

    test "stop_kind normalization: tool_calls → tool_call, length → length, truncated? only for length",
         %{
           project: project,
           use_case: use_case
         } do
      payloads = [
        generation_payload_fixture(use_case, %{"finish_reason" => "tool_calls"}),
        generation_payload_fixture(use_case, %{"finish_reason" => "max_tokens"}),
        generation_payload_fixture(use_case, %{
          "finish_reason" => "length",
          "stop_kind" => "length"
        }),
        generation_payload_fixture(use_case, %{
          "finish_reason" => "end_turn",
          "stop_kind" => "weird"
        }),
        generation_payload_fixture(use_case, %{"finish_reason" => nil, "stop_kind" => nil}),
        # canonical values pass through as is (decision #1 -- normalize must not turn tool_call
        # into :other)
        generation_payload_fixture(use_case, %{"finish_reason" => nil, "stop_kind" => "tool_call"}),
        generation_payload_fixture(use_case, %{
          "finish_reason" => "tool_use",
          "stop_kind" => "content_filter"
        }),
        generation_payload_fixture(use_case, %{"finish_reason" => nil, "stop_kind" => "weird"})
      ]

      assert %{accepted: 8, rejected: []} = ingest_fixture(project, payloads)

      by_id =
        project
        |> list()
        |> Enum.map(&Ash.load!(&1, [:truncated?], scope(project)))
        |> Map.new(&{&1.id, &1})

      [tool, max_tokens, length, weird, none, canonical_tool, canonical_filter, weird_only] =
        Enum.map(payloads, &Map.fetch!(by_id, &1["id"]))

      assert tool.stop_kind == :tool_call and tool.truncated? == false
      assert max_tokens.stop_kind == :length and max_tokens.truncated? == true
      assert length.stop_kind == :length and length.truncated? == true

      # a non-canonical stop_kind is ignored and derived from finish_reason instead
      assert weird.stop_kind == :stop
      assert none.stop_kind == nil and none.truncated? == false
      assert canonical_tool.stop_kind == :tool_call and canonical_tool.truncated? == false
      assert canonical_filter.stop_kind == :content_filter
      # only a non-canonical value and no finish_reason → :other
      assert weird_only.stop_kind == :other
    end

    test "unknown provider becomes :other, unknown enum values are rejected", %{
      project: project,
      use_case: use_case
    } do
      ok = generation_payload_fixture(use_case, %{"provider" => "mystery-cloud"})
      bad_kind = generation_payload_fixture(use_case, %{"kind" => "video"})
      bad_status = generation_payload_fixture(use_case, %{"status" => "meh"})

      assert %{accepted: 1, rejected: [r1, r2]} =
               ingest_fixture(project, [ok, bad_kind, bad_status])

      assert r1.index == 1 and r1.message =~ "kind must be one of"
      assert r2.index == 2 and r2.message =~ "status must be one of"
      [gen] = list(project)
      assert gen.provider == :other
    end

    test "cost: provider kept, catalog fallback from Model pricing, otherwise unknown", %{
      project: project,
      use_case: use_case
    } do
      model =
        model_fixture(project, %{
          model_id: "openai/gpt-5-mini",
          pricing: %{
            "input_per_m" => 1,
            "output_per_m" => 4,
            "currency" => "USD",
            "unit" => "token"
          }
        })

      provider = generation_payload_fixture(use_case)

      catalog =
        generation_payload_fixture(use_case, %{
          "model" => "openai/gpt-5-mini",
          "usage" => %{"input_tokens" => 1_000_000, "output_tokens" => 500_000}
        })

      by_model_id =
        generation_payload_fixture(use_case, %{
          "model" => "some-alias",
          "provider" => "other",
          "model_id" => model.id,
          "usage" => %{"input_tokens" => 2_000_000, "output_tokens" => 0}
        })

      unknown =
        generation_payload_fixture(use_case, %{
          "model" => "unlisted/model",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
        })

      no_usage = generation_payload_fixture(use_case, %{"usage" => %{}})

      assert %{accepted: 5, rejected: []} =
               ingest_fixture(project, [provider, catalog, by_model_id, unknown, no_usage])

      by_id = project |> list() |> Map.new(&{&1.id, &1})

      g = by_id[provider["id"]]
      assert Decimal.equal?(g.cost_usd, Decimal.new("0.001")) and g.cost_source == :provider

      g = by_id[catalog["id"]]
      # 1M × $1/M + 0.5M × $4/M = 3.0
      assert Decimal.equal?(g.cost_usd, Decimal.new("3")) and g.cost_source == :catalog
      assert g.model_id == model.id

      g = by_id[by_model_id["id"]]
      assert Decimal.equal?(g.cost_usd, Decimal.new("2")) and g.cost_source == :catalog

      g = by_id[unknown["id"]]
      assert g.cost_usd == nil and g.cost_source == :unknown

      g = by_id[no_usage["id"]]
      assert g.cost_usd == nil and g.cost_source == :unknown and g.input_tokens == nil
    end

    test "error records: error.kind/message stored, message truncated to 2KB", %{
      project: project,
      use_case: use_case
    } do
      # Korean "가" is a 3-byte UTF-8 character: the 2KB cut must not split a character
      long = String.duplicate("가", 3_000)

      payload =
        generation_payload_fixture(use_case, %{
          "status" => "error",
          "finish_reason" => nil,
          "output" => nil,
          "error" => %{"kind" => "rate_limited", "status" => 429, "message" => long}
        })

      assert %{accepted: 1} = ingest_fixture(project, [payload])
      [gen] = list(project)
      assert gen.status == :error
      assert gen.error_kind == :rate_limited
      assert gen.metadata["http_status"] == 429
      assert byte_size(gen.error_message) <= 2_048
      assert String.valid?(gen.error_message)
      assert String.starts_with?(gen.error_message, "가가가")
    end

    test "validation: started_at window, required fields, sizes, types", %{
      project: project,
      use_case: use_case
    } do
      future = DateTime.utc_now() |> DateTime.add(10, :minute) |> DateTime.to_iso8601()
      old = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.to_iso8601()

      payloads = [
        generation_payload_fixture(use_case, %{"started_at" => future}),
        generation_payload_fixture(use_case, %{"started_at" => old}),
        generation_payload_fixture(use_case, %{"id" => "not-a-uuid"}),
        generation_payload_fixture(use_case) |> Map.delete("model"),
        generation_payload_fixture(use_case, %{"usage" => %{"input_tokens" => "12"}}),
        generation_payload_fixture(use_case, %{
          "context" => %{"blob" => String.duplicate("x", 3_000)}
        }),
        generation_payload_fixture(use_case, %{
          "metadata" => %{"blob" => String.duplicate("x", 5_000)}
        }),
        generation_payload_fixture(use_case, %{"prompt" => 42}),
        "not a map",
        generation_payload_fixture(use_case)
      ]

      assert %{accepted: 1, duplicates: 0, rejected: rejected} = ingest_fixture(project, payloads)
      messages = Map.new(rejected, &{&1.index, &1.message})

      assert messages[0] =~ "future"
      assert messages[1] =~ "past"
      assert messages[2] =~ "id must be a UUID"
      assert messages[3] =~ "model is required"
      assert messages[4] =~ "usage.input_tokens must be integer"
      assert messages[5] =~ "context must be at most 2048 bytes"
      assert messages[6] =~ "metadata must be at most 4096 bytes"
      assert messages[7] =~ "prompt must be a string"
      assert messages[8] =~ "must be an object"
      assert Enum.all?(rejected, &(&1.code == "invalid_request"))
      assert length(list(project)) == 1
    end

    test "values the database would reject are rejected per record, not per batch (decision #7)",
         %{project: project, use_case: use_case} do
      payloads = [
        generation_payload_fixture(use_case),
        generation_payload_fixture(use_case, %{
          "usage" => %{"input_tokens" => Integer.pow(2, 63), "output_tokens" => 1}
        }),
        generation_payload_fixture(use_case, %{"model" => "anthropic/claude\0sonnet"}),
        generation_payload_fixture(use_case, %{"latency_ms" => Integer.pow(2, 64)}),
        generation_payload_fixture(use_case, %{"params" => %{"k\0ey" => 1}}),
        generation_payload_fixture(use_case, %{"metadata" => %{"note" => <<0xFF, 0xFE>>}}),
        generation_payload_fixture(use_case, %{
          "usage" => %{"input_tokens" => 1, "raw" => %{"nested" => [%{"x" => "a\0b"}]}}
        }),
        generation_payload_fixture(use_case, %{"input" => %{"text" => "bad\0text"}}),
        generation_payload_fixture(use_case, %{"error" => %{"status" => Integer.pow(2, 63)}}),
        generation_payload_fixture(use_case)
      ]

      assert %{accepted: 2, duplicates: 0, rejected: rejected} = ingest_fixture(project, payloads)
      messages = Map.new(rejected, &{&1.index, &1.message})

      assert messages[1] =~ "usage.input_tokens must be within the 64-bit integer range"
      assert messages[2] =~ "model must not contain NUL"
      assert messages[3] =~ "latency_ms must be within the 64-bit integer range"
      assert messages[4] =~ "params must not contain NUL"
      assert messages[5] =~ "metadata must be valid UTF-8"
      assert messages[6] =~ "usage.raw must not contain NUL"
      assert messages[7] =~ "input must not contain NUL"
      assert messages[8] =~ "error.status must be within the 64-bit integer range"
      assert Enum.all?(rejected, &(&1.code == "invalid_request"))
      assert length(list(project)) == 2
    end

    test "string input/output are wrapped, params/usage.raw over their caps are dropped", %{
      project: project,
      use_case: use_case
    } do
      big_params = %{"blob" => String.duplicate("p", 5_000)}
      big_raw = %{"blob" => String.duplicate("r", 17_000)}

      wrapped =
        generation_payload_fixture(use_case, %{"input" => "raw text", "output" => "raw out"})

      capped =
        generation_payload_fixture(use_case, %{
          "params" => big_params,
          "usage" => %{"input_tokens" => 1, "raw" => big_raw},
          "metadata" => %{"job_id" => 7}
        })

      assert %{accepted: 2, rejected: []} = ingest_fixture(project, [wrapped, capped])

      payload =
        Observability.get_payload!(wrapped["id"], scope(project) ++ [load: [:input, :output]])

      assert payload.input == %{"text" => "raw text"}
      assert payload.output == %{"content" => "raw out"}

      gen = Observability.get_generation!(capped["id"], scope(project))
      assert gen.params == %{}
      assert gen.metadata["truncated_fields"] == ["params", "usage.raw"]
      assert gen.metadata["job_id"] == 7
      assert Observability.get_payload!(capped["id"], scope(project)).usage_raw == nil

      # within the caps, kept as is
      ok = generation_payload_fixture(use_case)
      assert %{accepted: 1} = ingest_fixture(project, [ok])
      gen = Observability.get_generation!(ok["id"], scope(project))
      assert gen.params == %{"temperature" => 0.5}
      refute Map.has_key?(gen.metadata, "truncated_fields")
    end

    test "id already stored in another project is rejected with code conflict (decision #10)",
         %{project: project, use_case: use_case} do
      other = project_fixture()
      other_use_case = use_case_fixture(other, %{key: "k"})
      taken = generation_payload_fixture(other_use_case)
      assert %{accepted: 1} = ingest_fixture(other, [taken])

      mine = generation_payload_fixture(use_case)
      clash = generation_payload_fixture(use_case, %{"id" => taken["id"]})

      assert %{accepted: 1, duplicates: 0, rejected: [rejected]} =
               ingest_fixture(project, [mine, clash])

      assert rejected.index == 1
      assert rejected.id == taken["id"]
      assert rejected.code == "conflict"
      assert rejected.message =~ "another project"

      # only mine in this project; the other project's row is untouched
      assert [gen] = list(project)
      assert gen.id == mine["id"]
      assert Observability.get_generation!(taken["id"], scope(other)).project_id == other.id
    end

    test "api key cannot ingest into another project (decision #10)", %{
      use_case: use_case,
      api_key: api_key
    } do
      other = project_fixture()
      payload = generation_payload_fixture(use_case)

      assert {:error, :forbidden} =
               Ingest.ingest([payload], actor: api_key, tenant: other.id)

      # the policy itself also pins the tenant to the key's project
      assert {:error, %Ash.Error.Forbidden{}} =
               Observability.ingest_generation(
                 %{
                   id: Ash.UUIDv7.generate(),
                   use_case_key: "k",
                   model: "m",
                   status: :ok,
                   started_at: DateTime.utc_now()
                 },
                 tenant: other.id,
                 actor: api_key
               )

      assert {:ok, %{results: []}} = Observability.list_generations(scope(other))
    end

    test "batch limits and shapes", %{project: project, api_key: api_key} do
      assert {:error, {:invalid_request, msg}} =
               Ingest.ingest(%{}, actor: api_key, tenant: project.id)

      assert msg =~ "list"

      too_many = List.duplicate(generation_payload_fixture("k"), 201)

      assert {:error, {:invalid_request, msg}} =
               Ingest.ingest(too_many, actor: api_key, tenant: project.id)

      assert msg =~ "200"

      assert {:ok, %{accepted: 0, duplicates: 0, rejected: []}} =
               Ingest.ingest([], actor: api_key, tenant: project.id)
    end

    test "system actor can ingest with an explicit environment and source", %{
      project: project,
      use_case: use_case
    } do
      staging = environment(project, "staging")

      {:ok, gen} =
        Observability.ingest_generation(
          %{
            id: Ash.UUIDv7.generate(),
            use_case_key: use_case.key,
            use_case_id: use_case.id,
            environment_id: staging.id,
            model: "m",
            provider: :openai,
            source: :playground,
            status: :ok,
            finish_reason: "stop",
            started_at: DateTime.utc_now()
          },
          scope(project)
        )

      assert gen.environment_id == staging.id
      assert gen.source == :playground
      assert gen.stop_kind == :stop
      assert gen.cost_source == :unknown
    end
  end

  describe "reads" do
    test "for_trace sorts by sequence, for_end_user filters, list filters", %{
      project: project,
      use_case: use_case
    } do
      p1 =
        generation_payload_fixture(use_case, %{
          "trace_id" => "t1",
          "sequence" => 2,
          "end_user_ref" => "a"
        })

      p2 =
        generation_payload_fixture(use_case, %{
          "trace_id" => "t1",
          "sequence" => 1,
          "end_user_ref" => "a"
        })

      p3 =
        generation_payload_fixture(use_case, %{
          "trace_id" => "t2",
          "sequence" => 1,
          "end_user_ref" => "b",
          "status" => "error",
          "error" => %{"kind" => "timeout"}
        })

      assert %{accepted: 3} = ingest_fixture(project, [p1, p2, p3])

      {:ok, trace} = Observability.generations_for_trace("t1", scope(project))
      assert Enum.map(trace, & &1.id) == [p2["id"], p1["id"]]

      {:ok, page} = Observability.generations_for_end_user("b", scope(project))
      assert Enum.map(page.results, & &1.id) == [p3["id"]]

      {:ok, page} = Observability.list_generations(%{status: :error}, scope(project))
      assert Enum.map(page.results, & &1.id) == [p3["id"]]

      {:ok, page} = Observability.list_generations(%{use_case_key: use_case.key}, scope(project))
      assert length(page.results) == 3

      {:ok, page} = Observability.list_generations(%{use_case_key: "nope"}, scope(project))
      assert page.results == []

      {:ok, page} =
        Observability.list_generations(%{trace_id: "t2"}, scope(project) ++ [page: [limit: 1]])

      assert length(page.results) == 1
    end
  end

  describe "policies" do
    test "member reads own project, non-member and api key get nothing", %{
      project: project,
      use_case: use_case,
      api_key: api_key
    } do
      assert %{accepted: 1} = ingest_fixture(project, [generation_payload_fixture(use_case)])

      member = organization_owner(project)
      {:ok, page} = Observability.list_generations(tenant: project.id, actor: member)
      assert length(page.results) == 1

      stranger = user_fixture()
      {:ok, page} = Observability.list_generations(tenant: project.id, actor: stranger)
      assert page.results == []

      # ApiKey reads are a static forbid → empty results (config
      # `no_filter_static_forbidden_reads?: false`)
      assert {:ok, %{results: []}} =
               Observability.list_generations(tenant: project.id, actor: api_key)

      assert {:ok, []} = Ash.read(Generation, tenant: project.id, actor: api_key)
    end

    test "read-only api key cannot ingest, users cannot ingest", %{
      project: project,
      use_case: use_case
    } do
      {read_key, _} = api_key_fixture(project, scopes: [:read])
      payload = generation_payload_fixture(use_case)

      assert {:ok, %{accepted: 0, rejected: [%{message: message}]}} =
               Ingest.ingest([payload], actor: read_key, tenant: project.id)

      assert message =~ "forbidden"

      member = organization_owner(project)

      assert {:error, %Ash.Error.Forbidden{}} =
               Observability.ingest_generation(
                 %{
                   id: Ash.UUIDv7.generate(),
                   use_case_key: "k",
                   model: "m",
                   status: :ok,
                   started_at: DateTime.utc_now()
                 },
                 tenant: project.id,
                 actor: member
               )
    end
  end

  defp organization_owner(project) do
    org =
      Ash.load!(project, [organization: [memberships: [:user]]],
        actor: system_actor(),
        tenant: project.id
      ).organization

    hd(org.memberships).user
  end
end
