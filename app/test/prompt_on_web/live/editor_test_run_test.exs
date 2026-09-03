defmodule PromptOnWeb.EditorTestRunTest do
  @moduledoc """
  The arena execution unit (`PromptOnWeb.EditorTestRun`), tested without a screen: only request
  assembly, the context window and recording.

  Two things matter:

  1. **The request context window**: what goes into the request is the last 30 turns of that
     pane, and failed turns are left out (`context_turns/2`). However long the conversation
     grows, the messages sent to the provider must stay bounded.
  2. **Does a run of an unsaved buffer still leave a `Generation`?** The arena requires neither a
     deployment nor a save (ADR 0007), so if this path is blocked the draft-first flow becomes
     unobservable.
  """
  use PromptOn.DataCase, async: true

  alias PromptOn.Fixtures
  alias PromptOn.Observability
  alias PromptOnWeb.EditorTestRun

  doctest PromptOnWeb.EditorTestRun

  setup do
    project = Fixtures.project_fixture()
    use_case = Fixtures.use_case_fixture(project, %{key: "diary_generation"})
    model = Fixtures.model_fixture(project, %{model_id: "m/a", display_name: "Model A"})

    %{project: project, use_case: use_case, model: model}
  end

  defp context(ctx, overrides) do
    Map.merge(
      %{
        project: ctx.project,
        use_case: ctx.use_case,
        model: ctx.model,
        buffer: [%{role: "system", content: "Be terse."}, %{role: "user", content: "{{ input }}"}],
        variables: %{"input" => "hi"},
        turns: []
      },
      overrides
    )
  end

  describe "build_messages/4" do
    test "a chat buffer renders every message" do
      buffer = [%{role: "system", content: "Be terse."}, %{role: "user", content: "{{ input }}"}]

      assert {:ok, messages} =
               EditorTestRun.build_messages(%{kind: :chat}, buffer, %{"input" => "hi"})

      assert messages == [
               %{"role" => "system", "content" => "Be terse."},
               %{"role" => "user", "content" => "hi"}
             ]
    end

    test "a text buffer becomes a single user message" do
      buffer = [%{role: "text", content: "Transcribe {{ lang }}."}]

      assert {:ok, [%{"role" => "user", "content" => "Transcribe ko."}]} =
               EditorTestRun.build_messages(%{kind: :text}, buffer, %{"lang" => "ko"})
    end

    test "a variable without a value is a render error" do
      buffer = [%{role: "user", content: "{{ input }}"}]

      assert {:error, {:missing_variable, "input"}} =
               EditorTestRun.build_messages(%{kind: :chat}, buffer, %{})
    end
  end

  describe "run/1" do
    test "appends the conversation turns **after** the rendered buffer", ctx do
      turns = [%{role: "assistant", content: "prior answer"}, %{role: "user", content: "next"}]

      assert %{status: :ok, messages: messages, outcome: outcome} =
               EditorTestRun.run(context(ctx, %{turns: turns}))

      assert Enum.map(messages, & &1["content"]) == ["Be terse.", "hi", "prior answer", "next"]
      assert Enum.map(messages, & &1["role"]) == ["system", "user", "assistant", "user"]
      assert outcome.content =~ "[fake:m/a]"
    end

    test "when rendering fails it skips the call and gives one human-readable line", ctx do
      assert %{status: :error, stage: :render, message: message, messages: nil} =
               EditorTestRun.run(context(ctx, %{variables: %{}}))

      assert message =~ "input"
    end
  end

  describe "record/2: without saving" do
    test "a draft test result is recorded as a Generation", ctx do
      context = context(ctx, %{prompt_version_id: nil})
      result = EditorTestRun.run(context)

      assert {:ok, generation} = EditorTestRun.record(context, result)

      assert generation.prompt_version_id == nil
      assert generation.use_case_id == ctx.use_case.id
      assert generation.use_case_key == "diary_generation"
      assert generation.model == "m/a"
      assert generation.model_id == ctx.model.id
      assert generation.provider == :openrouter
      assert generation.source == :playground
      assert generation.status == :ok
      assert generation.payload_state == :dropped
      assert generation.metadata["screen"] == "use_case_arena"

      assert {:ok, %{results: [listed]}} =
               Observability.list_generations(Fixtures.scope(ctx.project))

      assert listed.id == generation.id
    end

    test "attaches the chosen version when there is one", ctx do
      version = Fixtures.prompt_version_fixture(ctx.use_case)
      context = context(ctx, %{prompt_version_id: version.id})

      assert {:ok, generation} = EditorTestRun.record(context, EditorTestRun.run(context))
      assert generation.prompt_version_id == version.id
    end

    test "a failed call is recorded too", ctx do
      context = context(ctx, %{variables: %{}})

      assert {:ok, generation} = EditorTestRun.record(context, EditorTestRun.run(context))
      assert generation.status == :error
      assert generation.error_kind == :app
      assert generation.error_message =~ "input"
    end
  end

  describe "context_turns/2: the request context window" do
    test "carries only the last 30 turns (the on-screen history is not truncated)" do
      messages =
        Enum.map(1..80, fn n ->
          %{role: if(rem(n, 2) == 1, do: :user, else: :assistant), content: "turn #{n}"}
        end)

      turns = EditorTestRun.context_turns(messages)

      assert length(turns) == 30
      assert List.first(turns).content == "turn 51"
      assert List.last(turns).content == "turn 80"
    end

    test "filters out failed turns **before** truncating" do
      messages =
        Enum.map(1..40, fn n ->
          %{role: :assistant, content: "turn #{n}", status: if(n < 20, do: :error, else: :ok)}
        end)

      turns = EditorTestRun.context_turns(messages)

      # Dropping the 19 errors out of 39 leaves 21, which is under the window (30), so all of
      # them stay.
      assert length(turns) == 21
      assert List.first(turns).content == "turn 20"
      refute Enum.any?(turns, &(&1.content == "turn 1"))
    end

    test "role is frozen as a string and limit can be passed explicitly" do
      messages = [
        %{role: :user, content: "a"},
        %{role: :assistant, content: "b"},
        %{role: :user, content: "c"}
      ]

      assert EditorTestRun.context_turns(messages, 2) == [
               %{role: "assistant", content: "b"},
               %{role: "user", content: "c"}
             ]
    end

    test "an empty history is an empty list" do
      assert EditorTestRun.context_turns([]) == []
      assert EditorTestRun.context_turns(nil) == []
    end
  end

  describe "variable casting (absorbed from Playground)" do
    test "only declared names are cast to their types" do
      schema = [
        %{name: "lines", type: :list, required?: false},
        %{name: "n", type: :number, required?: false},
        %{name: "flag", type: :boolean, required?: false},
        %{name: "raw", type: :string, required?: false}
      ]

      values = %{"lines" => "a\n\nb", "n" => "3", "flag" => "true", "raw" => "x", "gone" => "y"}

      assert EditorTestRun.cast_variables(schema, values) == %{
               "lines" => ["a", "b"],
               "n" => 3,
               "flag" => true,
               "raw" => "x"
             }
    end

    test "returns the names of empty required variables" do
      schema = [
        %{name: "a", type: :string, required?: true},
        %{name: "b", type: :string, required?: true},
        %{name: "c", type: :string, required?: false}
      ]

      assert EditorTestRun.missing_required(schema, %{"a" => "ok", "b" => "  "}) == ["b"]
    end
  end

  describe "error messages" do
    test "states render and call failures in one line" do
      assert EditorTestRun.render_error_message({:missing_variable, "input"}) =~ "input"
      assert EditorTestRun.llm_error_message(:no_provider_key) =~ "No provider key"
      assert EditorTestRun.llm_error_message({:http_error, 429, "slow down"}) =~ "429"
    end
  end
end
