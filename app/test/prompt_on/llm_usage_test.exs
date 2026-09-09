defmodule PromptOn.LLMUsageTest do
  use PromptOn.DataCase, async: false

  import ExUnit.CaptureLog
  import PromptOn.Fixtures

  alias PromptOn.LLM

  setup do
    on_exit(&LLM.Fake.reset/0)
    project = project_fixture()
    %{project: project, use_case: use_case_fixture(project)}
  end

  test "an accounting failure preserves the paid answer without repeating the provider call", %{
    use_case: use_case
  } do
    parent = self()
    secret = "private provider response must not be logged"

    LLM.Fake.set_response(fn request ->
      send(parent, :provider_called)
      {:ok, %{LLM.Fake.default_outcome(request) | content: secret}}
    end)

    log =
      capture_log(fn ->
        assert {:ok, %{content: ^secret}} =
                 LLM.complete(%{model: "openai/test", messages: []},
                   usage: %{use_case: %{use_case | key: nil}, operation: :draft}
                 )
      end)

    assert_received :provider_called
    refute_received :provider_called
    assert log =~ "AI usage recording failed"
    refute log =~ secret
  end

  test "calls without authoring attribution do not duplicate Arena accounting", %{
    project: project
  } do
    assert {:ok, _outcome} = LLM.complete(%{model: "openai/test", messages: []})
    assert Ash.read!(PromptOn.Observability.AIUsage, scope(project)) == []
  end
end
