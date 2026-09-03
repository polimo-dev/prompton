defmodule PromptOn.Observability.GenerationPayloadTest do
  @moduledoc """
  GenerationPayload -- policy (mode/sampling/truncation), encryption, retention (plan.md §5.7,
  §9.3, §9.7).
  """

  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.{Observability, Projects, Prompts}
  alias PromptOn.Observability.{GenerationPayload, PayloadPolicy}
  alias PromptOn.Observability.Ingest.Truncation

  setup do
    project = project_fixture()
    use_case = use_case_fixture(project, %{key: "diary_generation"})
    %{project: project, use_case: use_case}
  end

  defp set_project_policy(project, policy) do
    {:ok, project} =
      Projects.set_project_payload_policy(project, %{payload_policy: policy},
        actor: system_actor()
      )

    project
  end

  defp generation(project, id), do: Observability.get_generation!(id, scope(project))

  defp payload(project, id, load \\ []) do
    Observability.get_payload!(id, scope(project) ++ [load: load])
  end

  describe "policy modes" do
    test "full stores decrypted-on-load input/output/variables and hashes", %{
      project: project,
      use_case: use_case
    } do
      p = generation_payload_fixture(use_case)
      assert %{accepted: 1} = ingest_fixture(project, [p])

      assert generation(project, p["id"]).payload_state == :stored

      payload = payload(project, p["id"], [:input, :output, :variables])
      assert payload.input == %{"messages" => p["input"]["messages"]}
      assert payload.variables == %{"input" => "hello"}
      assert payload.output == %{"content" => "Hi there!", "tool_calls" => []}
      assert payload.usage_raw == %{"prompt_tokens" => 100}
      assert payload.encrypted? == true
      assert payload.truncated? == false
      assert payload.bytes_in == byte_size(Jason.encode!(p["input"]))
      assert payload.bytes_out == byte_size(Jason.encode!(p["output"]))

      assert payload.input_sha256 ==
               :crypto.hash(:sha256, Jason.encode!(p["input"])) |> Base.encode16(case: :lower)

      assert String.length(payload.output_sha256) == 64
    end

    test "hash keeps only hashes and sizes", %{project: project, use_case: use_case} do
      project = set_project_policy(project, %{mode: :hash})
      p = generation_payload_fixture(use_case)
      assert %{accepted: 1} = ingest_fixture(project, [p])

      assert generation(project, p["id"]).payload_state == :hashed
      payload = payload(project, p["id"], [:input, :output, :variables])
      assert payload.input == nil and payload.output == nil and payload.variables == nil
      assert payload.encrypted? == false
      assert is_binary(payload.input_sha256) and is_integer(payload.bytes_in)
    end

    test "SDK pre-hashed {sha256, bytes} wrappers are stored as hashes, never hashed again (decision #3)",
         %{project: project, use_case: use_case} do
      in_hash = String.duplicate("a", 64)
      out_hash = String.duplicate("B", 64)

      p =
        generation_payload_fixture(use_case, %{
          "input" => %{"sha256" => in_hash, "bytes" => 1234},
          "output" => %{"sha256" => out_hash, "bytes" => 56, "hashed" => true}
        })

      # the project policy is :full, but once the SDK has hashed, it is :hashed with those values
      assert %{accepted: 1, rejected: []} = ingest_fixture(project, [p])
      assert generation(project, p["id"]).payload_state == :hashed
      payload = payload(project, p["id"], [:input, :output, :variables])
      assert payload.input == nil and payload.output == nil and payload.variables == nil
      assert payload.input_sha256 == in_hash and payload.bytes_in == 1234
      assert payload.output_sha256 == String.downcase(out_hash) and payload.bytes_out == 56
      assert payload.encrypted? == false

      # when only one side is pre-hashed, the server hashes the other and stores no raw content
      mixed =
        generation_payload_fixture(use_case, %{
          "input" => %{"sha256" => in_hash, "bytes" => 1},
          "output" => %{"content" => "plain"}
        })

      assert %{accepted: 1} = ingest_fixture(project, [mixed])
      assert generation(project, mixed["id"]).payload_state == :hashed
      payload = payload(project, mixed["id"], [:output])
      assert payload.output == nil

      assert payload.output_sha256 ==
               :crypto.hash(:sha256, Jason.encode!(%{"content" => "plain"}))
               |> Base.encode16(case: :lower)

      # wrapper-shaped but with a bad value: only that record is rejected
      bad = generation_payload_fixture(use_case, %{"input" => %{"sha256" => "zz", "bytes" => 1}})
      assert %{accepted: 0, rejected: [%{message: message}]} = ingest_fixture(project, [bad])
      assert message =~ "input.sha256"

      # a map with three or more keys, or different keys, is just raw content (stored under :full)
      plain =
        generation_payload_fixture(use_case, %{"input" => %{"sha256" => in_hash, "text" => "x"}})

      assert %{accepted: 1} = ingest_fixture(project, [plain])
      assert generation(project, plain["id"]).payload_state == :stored

      # under mode :none even a pre-hash is dropped
      project = set_project_policy(project, %{mode: :none})

      p2 =
        generation_payload_fixture(use_case, %{"input" => %{"sha256" => in_hash, "bytes" => 1}})

      assert %{accepted: 1} = ingest_fixture(project, [p2])
      assert generation(project, p2["id"]).payload_state == :dropped
      assert {:ok, nil} = Observability.get_payload(p2["id"], scope(project))
    end

    test "none stores nothing, even for errors", %{project: project, use_case: use_case} do
      project = set_project_policy(project, %{mode: :none})

      err =
        generation_payload_fixture(use_case, %{
          "status" => "error",
          "error" => %{"kind" => "timeout"}
        })

      ok = generation_payload_fixture(use_case)
      assert %{accepted: 2} = ingest_fixture(project, [err, ok])

      assert generation(project, err["id"]).payload_state == :dropped
      assert generation(project, ok["id"]).payload_state == :dropped
      assert {:ok, nil} = Observability.get_payload(ok["id"], scope(project))
    end

    test "use case override beats project default", %{project: project, use_case: use_case} do
      project = set_project_policy(project, %{mode: :none})

      {:ok, _} =
        Prompts.set_use_case_payload_policy(
          use_case,
          %{payload_policy: %{mode: :full}},
          scope(project)
        )

      p = generation_payload_fixture(use_case)
      other = generation_payload_fixture("other_key")
      assert %{accepted: 2} = ingest_fixture(project, [p, other])
      assert generation(project, p["id"]).payload_state == :stored
      assert generation(project, other["id"]).payload_state == :dropped
    end

    test "records without input/output are dropped even in full mode", %{
      project: project,
      use_case: use_case
    } do
      p = generation_payload_fixture(use_case, %{"input" => nil, "output" => nil})
      assert %{accepted: 1} = ingest_fixture(project, [p])
      assert generation(project, p["id"]).payload_state == :dropped
    end
  end

  describe "sampling" do
    test "rate 0 keeps only error and length records; rate 1 keeps all", %{
      project: project,
      use_case: use_case
    } do
      project = set_project_policy(project, %{mode: :full, sample_rate: 0.0})

      ok = generation_payload_fixture(use_case)

      err =
        generation_payload_fixture(use_case, %{"status" => "error", "error" => %{"kind" => "app"}})

      cut = generation_payload_fixture(use_case, %{"finish_reason" => "length"})
      tool = generation_payload_fixture(use_case, %{"finish_reason" => "tool_calls"})

      assert %{accepted: 4} = ingest_fixture(project, [ok, err, cut, tool])
      assert generation(project, ok["id"]).payload_state == :dropped
      assert generation(project, err["id"]).payload_state == :stored
      assert generation(project, cut["id"]).payload_state == :stored
      assert generation(project, tool["id"]).payload_state == :dropped
    end

    test "sample? is deterministic on sha256(id) buckets" do
      id = "0192a3b4-0000-7000-8000-000000000001"
      bucket = PayloadPolicy.bucket(id)
      assert bucket == PayloadPolicy.bucket(id)
      assert bucket in 0..9_999

      <<n::unsigned-big-32, _::binary>> = :crypto.hash(:sha256, id)
      assert bucket == rem(n, 10_000)

      rate_just_above = (bucket + 1) / 10_000
      rate_just_below = bucket / 10_000
      assert PayloadPolicy.sample?(%{sample_rate: rate_just_above}, id)
      refute PayloadPolicy.sample?(%{sample_rate: rate_just_below}, id)
      assert PayloadPolicy.sample?(%{sample_rate: 1.0}, id)
      refute PayloadPolicy.sample?(%{sample_rate: 0.0}, id)
    end

    test "bucket = first 4 bytes of sha256(id) big-endian rem 10_000 (decision #2, shared vector with the SDK)" do
      # fixed vectors -- the SDK tests must use the same values. (The whole digest mod 10_000 gives
      # 513 / 2296 instead, which is different.)
      assert PayloadPolicy.bucket("0192a3b4-0000-7000-8000-000000000001") == 2656
      assert PayloadPolicy.bucket("00000000-0000-0000-0000-000000000000") == 8252

      for id <- Enum.map(1..20, fn _ -> Ash.UUIDv7.generate() end) do
        <<n::unsigned-big-32, _::binary>> = :crypto.hash(:sha256, id)
        assert PayloadPolicy.bucket(id) == rem(n, 10_000)
      end
    end
  end

  describe "truncation" do
    test "max_bytes 8KB: long messages/output are middle-truncated, head and tail preserved", %{
      project: project,
      use_case: use_case
    } do
      project = set_project_policy(project, %{mode: :full, max_bytes: 8_192})
      limits = Truncation.limits(8_192)
      assert limits == %{message: 1_024, input: 8_192, output: 2_048}

      # Korean "가" is a 3-byte UTF-8 character: the middle cut must land on a character boundary
      long_message = "HEAD-" <> String.duplicate("가", 2_000) <> "-TAIL"
      long_output = "OUT-HEAD-" <> String.duplicate("b", 5_000) <> "-OUT-TAIL"

      p =
        generation_payload_fixture(use_case, %{
          "input" => %{
            "variables" => %{"x" => 1},
            "messages" => [
              %{"role" => "system", "content" => "short"},
              %{"role" => "user", "content" => long_message}
            ]
          },
          "output" => %{"content" => long_output, "tool_calls" => []}
        })

      assert %{accepted: 1} = ingest_fixture(project, [p])
      assert generation(project, p["id"]).payload_state == :truncated

      payload = payload(project, p["id"], [:input, :output])
      assert payload.truncated? == true
      [_system, user] = payload.input["messages"]
      assert String.starts_with?(user["content"], "HEAD-가")
      assert String.ends_with?(user["content"], "가-TAIL")
      assert user["content"] =~ "…[truncated"
      assert byte_size(user["content"]) <= 1_024
      assert String.valid?(user["content"])

      assert String.starts_with?(payload.output["content"], "OUT-HEAD-")
      assert String.ends_with?(payload.output["content"], "-OUT-TAIL")
      assert byte_size(payload.output["content"]) <= 2_048

      # sizes and hashes are based on the raw content before truncation
      assert payload.bytes_in == byte_size(Jason.encode!(p["input"]))
    end

    test "input total over max_bytes drops middle messages, keeps first and tail", %{
      project: project,
      use_case: use_case
    } do
      project = set_project_policy(project, %{mode: :full, max_bytes: 8_192})
      msg = fn i -> %{"role" => "user", "content" => "m#{i}-" <> String.duplicate("x", 900)} end

      p =
        generation_payload_fixture(use_case, %{
          "input" => %{
            "messages" => [%{"role" => "system", "content" => "sys"} | Enum.map(1..20, msg)]
          }
        })

      assert %{accepted: 1} = ingest_fixture(project, [p])
      payload = payload(project, p["id"], [:input])
      [first, marker | tail] = payload.input["messages"]
      assert first["content"] == "sys"
      assert marker["truncated"] == true and marker["content"] =~ "messages truncated"
      assert List.last(tail)["content"] =~ "m20-"
      assert Truncation.json_size(payload.input["messages"]) <= 8_192
      assert generation(project, p["id"]).payload_state == :truncated
    end

    test "message-list truncation never exceeds the input budget, marker included", %{
      project: project,
      use_case: use_case
    } do
      max_bytes = 8_192
      limits = Truncation.limits(max_bytes)
      msg = fn i, n -> %{"role" => "user", "content" => "m#{i}-" <> String.duplicate("x", n)} end

      # several shapes: sizes straddling the budget boundary -- catches the regression where the
      # list overflowed by the size of the marker message
      shapes = [
        Enum.map(1..20, &msg.(&1, 900)),
        Enum.map(1..40, &msg.(&1, 200)),
        Enum.map(1..12, &msg.(&1, 700)),
        Enum.map(1..300, &msg.(&1, 25)),
        [msg.(1, 1_000), msg.(2, 1_000)] ++ Enum.map(3..30, &msg.(&1, 260))
      ]

      for messages <- shapes do
        input = %{"messages" => [%{"role" => "system", "content" => "sys"} | messages]}
        {out, _output, truncated?} = Truncation.apply(input, nil, max_bytes)
        assert truncated?
        assert Truncation.json_size(out["messages"]) <= limits.input
        assert byte_size(Jason.encode!(out["messages"])) <= max_bytes
        [first, marker | tail] = out["messages"]
        assert first["content"] == "sys"
        assert marker["truncated"] == true and marker["content"] =~ "messages truncated"
        assert List.last(tail)["content"] == List.last(messages)["content"]
      end

      # the same guarantee holds all the way through the storage path
      project = set_project_policy(project, %{mode: :full, max_bytes: max_bytes})

      p =
        generation_payload_fixture(use_case, %{
          "input" => %{"messages" => [%{"role" => "system", "content" => "sys"} | hd(shapes)]}
        })

      assert %{accepted: 1} = ingest_fixture(project, [p])
      payload = payload(project, p["id"], [:input])
      assert Truncation.json_size(payload.input["messages"]) <= max_bytes
    end

    test "client truncated flag is honored", %{project: project, use_case: use_case} do
      p =
        generation_payload_fixture(use_case, %{
          "output" => %{"content" => "x", "truncated" => true}
        })

      assert %{accepted: 1} = ingest_fixture(project, [p])
      assert generation(project, p["id"]).payload_state == :truncated
      assert payload(project, p["id"]).truncated? == true
    end

    test "string helpers keep UTF-8 boundaries" do
      # Korean "가" is a 3-byte UTF-8 character, so a byte cut can land mid-character
      s = String.duplicate("가", 100)
      assert Truncation.head(s, 10) == String.duplicate("가", 3)
      assert Truncation.tail(s, 10) == String.duplicate("가", 3)
      m = Truncation.middle(s, 100)
      assert String.valid?(m) and byte_size(m) <= 100
      assert String.starts_with?(m, "가") and String.ends_with?(m, "가")
      assert Truncation.middle("short", 100) == "short"
    end
  end

  describe "encryption" do
    test "raw columns hold ciphertext, calculations decrypt", %{
      project: project,
      use_case: use_case
    } do
      p = generation_payload_fixture(use_case, %{"output" => %{"content" => "SECRET-DIARY-TEXT"}})
      assert %{accepted: 1} = ingest_fixture(project, [p])

      %{rows: [[enc_in, enc_out, enc_vars]]} =
        Ecto.Adapters.SQL.query!(
          PromptOn.Repo,
          "SELECT encrypted_input, encrypted_output, encrypted_variables FROM generation_payloads WHERE generation_id = $1",
          [Ecto.UUID.dump!(p["id"])]
        )

      for enc <- [enc_in, enc_out, enc_vars] do
        assert is_binary(enc)
        refute enc =~ "SECRET-DIARY-TEXT"
        refute enc =~ "hello"
        refute enc =~ "helpful"
      end

      # the column is base64(term_to_binary → AES-GCM); decrypting through the vault directly
      # yields the raw term
      decrypted =
        enc_out |> Base.decode64!() |> PromptOn.Vault.decrypt!() |> :erlang.binary_to_term()

      assert decrypted == %{"content" => "SECRET-DIARY-TEXT"}

      loaded = payload(project, p["id"], [:output])
      assert loaded.output == %{"content" => "SECRET-DIARY-TEXT"}
      # the default load does not decrypt
      assert %Ash.NotLoaded{} = payload(project, p["id"]).output
    end
  end

  describe "retention" do
    test "expires_at = received_at + retention_days", %{project: project, use_case: use_case} do
      project = set_project_policy(project, %{retention_days: 7})
      p = generation_payload_fixture(use_case)
      assert %{accepted: 1} = ingest_fixture(project, [p])

      payload = payload(project, p["id"])
      gen = generation(project, p["id"])
      assert payload.received_at == gen.received_at
      assert DateTime.diff(payload.expires_at, payload.received_at, :day) == 7
    end

    test "purge_expired deletes only expired payloads (per tenant and globally)", %{
      project: project,
      use_case: use_case
    } do
      other_project = project_fixture()
      other_use_case = use_case_fixture(other_project, %{key: "k"})

      fresh = generation_payload_fixture(use_case)
      old = generation_payload_fixture(use_case)
      old_other = generation_payload_fixture(other_use_case)
      assert %{accepted: 2} = ingest_fixture(project, [fresh, old])
      assert %{accepted: 1} = ingest_fixture(other_project, [old_other])

      # expire two records into the past (raw SQL -- expires_at has no write action)
      Ecto.Adapters.SQL.query!(
        PromptOn.Repo,
        "UPDATE generation_payloads SET expires_at = now() - interval '1 day' WHERE generation_id = ANY($1)",
        [[Ecto.UUID.dump!(old["id"]), Ecto.UUID.dump!(old_other["id"])]]
      )

      {:ok, expired} = Observability.expired_payloads(scope(project))
      assert Enum.map(expired, & &1.generation_id) == [old["id"]]

      assert {:ok, %{deleted: 1}} =
               Observability.purge_expired_payloads(%{batch_size: 1}, scope(project))

      assert {:ok, nil} = Observability.get_payload(old["id"], scope(project))
      assert %GenerationPayload{} = payload(project, fresh["id"])
      # the other tenant was left alone
      assert %GenerationPayload{} = payload(other_project, old_other["id"])

      # called without a tenant, it covers every project
      assert {:ok, %{deleted: 1}} =
               Observability.purge_expired_payloads(%{}, actor: system_actor())

      assert {:ok, nil} = Observability.get_payload(old_other["id"], scope(other_project))

      assert {:ok, %{deleted: 0}} =
               Observability.purge_expired_payloads(%{}, actor: system_actor())

      # the Generation row remains
      assert generation(project, old["id"]).payload_state == :stored
    end

    test "archived projects are still purged (list_tenants includes them)", %{
      project: project,
      use_case: use_case
    } do
      old = generation_payload_fixture(use_case)
      assert %{accepted: 1} = ingest_fixture(project, [old])

      Ecto.Adapters.SQL.query!(
        PromptOn.Repo,
        "UPDATE generation_payloads SET expires_at = now() - interval '1 day' WHERE generation_id = $1",
        [Ecto.UUID.dump!(old["id"])]
      )

      {:ok, _} = Projects.archive_project(project, actor: system_actor())
      assert project.id in PromptOn.Observability.ProjectTenants.list_tenants([])

      # both the job's per-tenant run and the tenant-less global run delete the archived project's
      # expired raw content
      assert {:ok, %{deleted: 1}} =
               Observability.purge_expired_payloads(%{}, actor: system_actor())

      assert {:ok, nil} = Observability.get_payload(old["id"], scope(project))
    end

    test "purge_for_end_user removes only that user's payloads", %{
      project: project,
      use_case: use_case
    } do
      a1 = generation_payload_fixture(use_case, %{"end_user_ref" => "alice"})
      a2 = generation_payload_fixture(use_case, %{"end_user_ref" => "alice"})
      b = generation_payload_fixture(use_case, %{"end_user_ref" => "bob"})
      assert %{accepted: 3} = ingest_fixture(project, [a1, a2, b])

      assert {:ok, %{deleted: 2}} =
               Observability.purge_payloads_for_end_user("alice", scope(project))

      assert {:ok, nil} = Observability.get_payload(a1["id"], scope(project))
      assert {:ok, nil} = Observability.get_payload(a2["id"], scope(project))
      assert %GenerationPayload{} = payload(project, b["id"])

      assert {:ok, %{deleted: 0}} =
               Observability.purge_payloads_for_end_user("alice", scope(project))
    end

    test "scheduled action is registered on the maintenance queue" do
      [schedule] = AshOban.Info.oban_scheduled_actions(GenerationPayload)
      assert schedule.action == :purge_expired
      assert schedule.queue == :maintenance
      assert schedule.cron == "10 3 * * *"
      assert Code.ensure_loaded?(schedule.worker)
      assert PromptOn.Observability.ProjectTenants.list_tenants([]) |> is_list()
    end
  end

  describe "policies" do
    test "member reads, stranger and api key cannot; only system writes", %{
      project: project,
      use_case: use_case
    } do
      p = generation_payload_fixture(use_case)
      assert %{accepted: 1} = ingest_fixture(project, [p])
      {api_key, _} = api_key_fixture(project)

      org =
        Ash.load!(project, [organization: [memberships: [:user]]], scope(project)).organization

      member = hd(org.memberships).user

      assert {:ok, %GenerationPayload{}} =
               Observability.get_payload(p["id"], tenant: project.id, actor: member)

      assert {:ok, nil} =
               Observability.get_payload(p["id"], tenant: project.id, actor: user_fixture())

      assert {:ok, nil} = Observability.get_payload(p["id"], tenant: project.id, actor: api_key)

      attrs = %{generation_id: p["id"], input: %{"x" => 1}}

      assert {:error, %Ash.Error.Forbidden{}} =
               Observability.store_payload(attrs, tenant: project.id, actor: member)

      assert {:error, %Ash.Error.Forbidden{}} =
               Observability.store_payload(attrs, tenant: project.id, actor: api_key)

      assert {:error, %Ash.Error.Forbidden{}} =
               Observability.purge_payloads_for_end_user("u_1", tenant: project.id, actor: member)
    end
  end
end
