defmodule PromptOn.Contract.SdkIngestContractTest do
  @moduledoc """
  SDK <-> server contract test (plan.md §6.2/§6.4, §7.4). Pins down that the SDK decodes
  and renders a server-built use-case document as is, and that the §6.4 log maps produced by
  `track/3` (all four result shapes) enter the server ingest **without rejection**. The SDK is used
  in `mode: :test` without being started (logs come to the calling process).
  """

  use PromptOn.DataCase, async: false

  import PromptOn.Fixtures

  alias PromptOn.{Observability, Projects}
  alias PromptOnSDK.Result
  alias PromptOnSDK.Test, as: SDKTest

  setup do
    prev = Application.get_env(:prompton_sdk, :mode)
    Application.put_env(:prompton_sdk, :mode, :test)
    on_exit(fn -> restore(prev) end)
    SDKTest.clear()

    fx = heydiary_project_fixture()

    {:ok, document} =
      Projects.config_snapshot(fx.production.id, actor: fx.user, tenant: fx.project.id)

    :ok = SDKTest.put_use_case_document(document.map)
    {key, _raw} = api_key_fixture(fx.project, scopes: [:logs])
    %{fx: fx, key: key, use_case_document: document}
  end

  defp restore(nil), do: Application.delete_env(:prompton_sdk, :mode)
  defp restore(prev), do: Application.put_env(:prompton_sdk, :mode, prev)

  test "use-case document round-trips through the SDK and every track result shape is accepted by ingest",
       %{
         fx: fx,
         key: key
       } do
    assert {:ok, use_case} = PromptOnSDK.use_case("diary_generation", prompt: "ko")

    assert use_case.prompt == "ko"
    assert use_case.deployment.id
    assert use_case.prompt_version.id == fx.prompt_versions.diary_ko.id
    assert use_case.model =~ "/"

    # A name that is not pinned is an error, not a silent fallback
    assert PromptOnSDK.use_case("diary_generation", prompt: "ja") == {:error, :unknown_prompt}

    assert {:ok, [_system, %{content: rendered}]} =
             PromptOnSDK.messages(use_case, %{transcriptions: ["a", "b"], mode: "fresh"})

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
      PromptOnSDK.track(use_case, Map.put(base, :sequence, 1), fn ->
        {:ok, Result.from_openai(resp_tool)}
      end)

    # 2) plain error
    {:error, _} =
      PromptOnSDK.track(use_case, Map.put(base, :sequence, 2), fn ->
        {:error, %{kind: :http_5xx, status: 502, message: "bad gateway"}}
      end)

    # 3) 3-tuple: usage preserved + status error/parse
    resp_ok = %{
      "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => "not a number"}}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "cost" => 0.0004}
    }

    {:error, _, _} =
      PromptOnSDK.track(use_case, Map.put(base, :sequence, 3), fn ->
        {:error, %{kind: :parse, message: "no integer"}, Result.from_openai(resp_ok)}
      end)

    # 4) exception → error_kind app, and the exception is re-raised
    assert_raise RuntimeError, fn ->
      PromptOnSDK.track(use_case, Map.put(base, :sequence, 4), fn -> raise "boom" end)
    end

    logs = SDKTest.logged()
    assert length(logs) == 4

    result = ingest_fixture(fx.project, logs, api_key: key)
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
             &(&1.prompt == "ko" and &1.deployment_id == use_case.deployment.id and
                 &1.prompt_version_id == use_case.prompt_version.id)
           )

    assert Enum.all?(rows, &(&1.context == %{"language" => "ko", "plan" => "pro"}))

    # The 3-tuple preserves usage
    assert Enum.at(rows, 2).input_tokens == 5

    # A resend (same ids) is absorbed entirely as duplicates
    again = ingest_fixture(fx.project, logs, api_key: key)
    assert again.duplicates == 4 and again.accepted == 0
  end

  test "hash log content policy from the use-case document produces payload_state :hashed on the server",
       %{
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

    {:ok, document} =
      Projects.config_snapshot(fx.production.id, actor: fx.user, tenant: fx.project.id)

    :ok = SDKTest.put_use_case_document(document.map)

    {:ok, use_case} = PromptOnSDK.use_case("diary_generation")

    assert to_string(use_case.payload_policy[:mode] || use_case.payload_policy["mode"]) == "hash"

    {:ok, _} =
      PromptOnSDK.track(
        use_case,
        %{input_messages: [%{"role" => "user", "content" => "diary text"}]},
        fn ->
          {:ok,
           %{content: "2", finish_reason: "stop", usage: %{input_tokens: 3, output_tokens: 1}}}
        end
      )

    [log] = SDKTest.logged()
    assert %{"sha256" => _, "bytes" => _} = log["input"]

    result = ingest_fixture(fx.project, [log], api_key: key)
    assert result.rejected == [] and result.accepted == 1

    {:ok, stored} = Observability.get_generation(log["id"], tenant: fx.project.id, actor: fx.user)
    assert stored.payload_state == :hashed
  end
end
