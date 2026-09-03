defmodule PromptOn.Contract.SdkIngestContractTest do
  @moduledoc """
  SDK <-> server contract test (plan.md §6.2/§6.4, §7.4). Pins down that the SDK decodes,
  resolves and renders a server-built snapshot as is, and that the §6.4 maps produced by the SDK's
  `with_generation/3` (all four outcome shapes) enter the server ingest **without rejection**.
  The SDK is used in `mode: :test` without being started (logs come to the calling process).
  """

  use PromptOn.DataCase, async: false

  import PromptOn.Fixtures

  alias PromptOn.{Observability, Projects}
  alias PromptOnSDK.Test, as: SDKTest

  setup do
    prev = Application.get_env(:prompton_sdk, :mode)
    Application.put_env(:prompton_sdk, :mode, :test)
    on_exit(fn -> restore(prev) end)
    SDKTest.clear()

    fx = heydiary_project_fixture()

    {:ok, snap} =
      Projects.config_snapshot(fx.production.id, actor: fx.user, tenant: fx.project.id)

    :ok = SDKTest.put_snapshot(snap.map)
    {key, _raw} = api_key_fixture(fx.project, scopes: [:logs])
    %{fx: fx, key: key, snapshot: snap}
  end

  defp restore(nil), do: Application.delete_env(:prompton_sdk, :mode)
  defp restore(prev), do: Application.put_env(:prompton_sdk, :mode, prev)

  test "snapshot round-trips through the SDK and every with_generation shape is accepted by ingest",
       %{
         fx: fx,
         key: key
       } do
    assert {:ok, r} = PromptOnSDK.resolve("diary_generation", prompt: "ko")

    assert r.prompt == "ko"
    assert r.deployment_id
    assert r.prompt_version_id == fx.prompt_versions.diary_ko.id
    assert r.model =~ "/"

    # A name that is not pinned is an error, not a silent fallback
    assert PromptOnSDK.resolve("diary_generation", prompt: "ja") == {:error, :unknown_prompt}

    assert {:ok, [_system, %{content: rendered}]} =
             PromptOnSDK.render(r, %{transcriptions: ["a", "b"], mode: "fresh"})

    assert rendered ==
             "Please write a diary entry based on these voice transcriptions:\n\n1. a\n\n2. b\n\n"

    msgs = [%{"role" => "system", "content" => "s"}, %{"role" => "user", "content" => rendered}]

    base = %{
      trace_id: "oban:1",
      end_user_ref: "u_1",
      input_messages: msgs,
      context: %{language: "ko", plan: "pro"}
    }

    # 1) ok + tool_calls (stop_kind tool_call must survive all the way through)
    resp_tool = %{
      "choices" => [
        %{
          "finish_reason" => "tool_calls",
          "message" => %{
            "content" => nil,
            "tool_calls" => [%{"id" => "c1", "function" => %{"name" => "f", "arguments" => "{}"}}]
          }
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => 0.001},
      "model" => "anthropic/claude-sonnet-4"
    }

    {:ok, _} =
      PromptOnSDK.with_generation(r, Map.put(base, :sequence, 1), fn ->
        {:ok, PromptOnSDK.OpenRouter.outcome(resp_tool)}
      end)

    # 2) plain error
    {:error, _} =
      PromptOnSDK.with_generation(r, Map.put(base, :sequence, 2), fn ->
        {:error, %{kind: :http_5xx, status: 502, message: "bad gateway"}}
      end)

    # 3) 3-tuple: usage preserved + status error/parse
    resp_ok = %{
      "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => "not a number"}}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "cost" => 0.0004}
    }

    {:error, _, _} =
      PromptOnSDK.with_generation(r, Map.put(base, :sequence, 3), fn ->
        {:error, %{kind: :parse, message: "no integer"}, PromptOnSDK.OpenRouter.outcome(resp_ok)}
      end)

    # 4) exception → error_kind app, and the exception is re-raised
    assert_raise RuntimeError, fn ->
      PromptOnSDK.with_generation(r, Map.put(base, :sequence, 4), fn -> raise "boom" end)
    end

    gens = SDKTest.logged()
    assert length(gens) == 4

    result = ingest_fixture(fx.project, gens, api_key: key)
    assert result.rejected == []
    assert result.accepted == 4
    assert result.duplicates == 0

    {:ok, page} =
      Observability.generations_for_trace("oban:1", tenant: fx.project.id, actor: fx.user)

    rows = Enum.sort_by(List.wrap(page), & &1.sequence)
    assert Enum.map(rows, & &1.status) == [:ok, :error, :error, :error]
    assert Enum.map(rows, & &1.stop_kind) |> hd() == :tool_call
    assert Enum.map(rows, & &1.error_kind) == [nil, :http_5xx, :parse, :app]

    assert Enum.all?(
             rows,
             &(&1.prompt == "ko" and &1.deployment_id == r.deployment_id and
                 &1.prompt_version_id == r.prompt_version_id)
           )

    assert Enum.all?(rows, &(&1.context == %{"language" => "ko", "plan" => "pro"}))

    # The 3-tuple preserves usage
    assert Enum.at(rows, 2).input_tokens == 5

    # A resend (same ids) is absorbed entirely as duplicates
    again = ingest_fixture(fx.project, gens, api_key: key)
    assert again.duplicates == 4 and again.accepted == 0
  end

  test "hash payload policy from the snapshot produces payload_state :hashed on the server", %{
    fx: fx,
    key: key
  } do
    {:ok, _} =
      Projects.set_project_payload_policy(
        fx.project,
        %{
          payload_policy: %{
            mode: :hash,
            sample_rate: 1.0,
            max_bytes: 262_144,
            retention_days: 30,
            encrypt?: true
          }
        },
        actor: fx.user
      )

    {:ok, snap} =
      Projects.config_snapshot(fx.production.id, actor: fx.user, tenant: fx.project.id)

    :ok = SDKTest.put_snapshot(snap.map)

    {:ok, r} = PromptOnSDK.resolve("diary_generation")

    assert to_string(r.payload_policy[:mode] || r.payload_policy["mode"]) == "hash"

    {:ok, _} =
      PromptOnSDK.with_generation(
        r,
        %{input_messages: [%{"role" => "user", "content" => "diary text"}]},
        fn ->
          {:ok,
           %{content: "2", finish_reason: "stop", usage: %{input_tokens: 3, output_tokens: 1}}}
        end
      )

    [gen] = SDKTest.logged()
    assert %{"sha256" => _, "bytes" => _} = gen["input"]

    result = ingest_fixture(fx.project, [gen], api_key: key)
    assert result.rejected == [] and result.accepted == 1

    {:ok, stored} = Observability.get_generation(gen["id"], tenant: fx.project.id, actor: fx.user)
    assert stored.payload_state == :hashed
  end
end
