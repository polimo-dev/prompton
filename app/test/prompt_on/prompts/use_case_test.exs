defmodule PromptOn.Prompts.UseCaseTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Prompts
  alias PromptOn.Prompts.Prompt
  alias PromptOn.Prompts.PromptVersion

  test "define creates the default prompt for chat and text, not for embedding" do
    project = project_fixture()

    chat = use_case_fixture(project, %{key: "diary_generation", kind: :chat})
    assert [%{name: "default"}] = chat.prompts

    text = use_case_fixture(project, %{key: "voice_transcription", kind: :text})
    assert [%{name: "default"}] = text.prompts

    embedding = use_case_fixture(project, %{key: "diary_embedding", kind: :embedding})
    assert embedding.prompts == []

    {:ok, loaded} =
      Prompts.get_use_case(
        chat.id,
        Keyword.put(scope(project), :load, [:prompt_count])
      )

    assert loaded.prompt_count == 1
  end

  test "key must match ^[a-z][a-z0-9_]*$ and be unique per project" do
    project = project_fixture()

    for bad <- ["Diary", "1abc", "diary-generation", "", " diary"] do
      assert {:error, %Ash.Error.Invalid{}} =
               Prompts.define_use_case(%{key: bad, name: "bad"}, scope(project)),
             "expected #{inspect(bad)} to be rejected"
    end

    use_case_fixture(project, %{key: "chat_response"})

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.define_use_case(%{key: "chat_response", name: "dup"}, scope(project))

    other = project_fixture()
    assert %{key: "chat_response"} = use_case_fixture(other, %{key: "chat_response"})
  end

  test "input_schema, default_params, payload_policy, describe, archive" do
    project = project_fixture()
    use_case = use_case_fixture(project)

    {:ok, use_case} =
      Prompts.set_use_case_input_schema(
        use_case,
        %{
          input_schema: [%{name: "transcriptions", type: :list, required?: true}, %{name: "mode"}]
        },
        scope(project)
      )

    assert [
             %{name: "transcriptions", type: :list, required?: true},
             %{name: "mode", type: :string}
           ] =
             use_case.input_schema

    # Ash raises an embedded match-constraint violation (on the update path) as the Unknown class;
    # only check that it is rejected
    assert {:error, %{errors: [_ | _]}} =
             Prompts.set_use_case_input_schema(
               use_case,
               %{input_schema: [%{name: "Bad-Name"}]},
               scope(project)
             )

    {:ok, use_case} =
      Prompts.set_use_case_default_params(
        use_case,
        %{default_params: %{temperature: 0.5}},
        scope(project)
      )

    assert use_case.default_params == %{"temperature" => 0.5} or
             use_case.default_params == %{temperature: 0.5}

    assert use_case.payload_policy == nil

    {:ok, use_case} =
      Prompts.set_use_case_payload_policy(
        use_case,
        %{payload_policy: %{mode: :hash, sample_rate: 0.5}},
        scope(project)
      )

    assert use_case.payload_policy.mode == :hash

    {:ok, use_case} =
      Prompts.set_use_case_payload_policy(use_case, %{payload_policy: nil}, scope(project))

    assert use_case.payload_policy == nil

    {:ok, use_case} =
      Prompts.describe_use_case(use_case, %{name: "Diary", tags: ["core"]}, scope(project))

    assert use_case.tags == ["core"]

    {:ok, _} = Prompts.archive_use_case(use_case, scope(project))
    assert {:ok, []} = Prompts.list_use_cases(scope(project))

    assert {:ok, nil} =
             Prompts.get_use_case_by_key(
               use_case.key,
               scope(project, elem(api_key_fixture(project), 0))
             )
  end

  test "policies: member RW, stranger nothing, api key reads active only" do
    owner = user_fixture()
    project = project_fixture(%{user: owner})
    stranger = user_fixture()
    {api_key, _} = api_key_fixture(project)

    {:ok, use_case} =
      Prompts.define_use_case(%{key: "diary_generation", name: "Diary"}, scope(project, owner))

    archived = use_case_fixture(project)
    {:ok, _} = Prompts.archive_use_case(archived, scope(project, owner))

    assert {:ok, [_, _]} = Prompts.list_all_use_cases(scope(project, owner))
    assert {:ok, []} = Prompts.list_all_use_cases(scope(project, stranger))
    assert {:ok, [visible]} = Prompts.list_all_use_cases(scope(project, api_key))
    assert visible.id == use_case.id

    assert {:error, %Ash.Error.Forbidden{}} =
             Prompts.define_use_case(%{key: "x", name: "x"}, scope(project, stranger))

    assert {:error, %Ash.Error.Forbidden{}} =
             Prompts.define_use_case(%{key: "y", name: "y"}, scope(project, api_key))

    assert {:error, %Ash.Error.Forbidden{}} =
             Prompts.describe_use_case(use_case, %{name: "n"}, scope(project, api_key))

    assert {:ok, %{name: "Renamed"}} =
             Prompts.describe_use_case(use_case, %{name: "Renamed"}, scope(project, owner))
  end

  test "prompt: open/rename/archive, identity per use case, aggregates, tenant check" do
    project = project_fixture()
    use_case = use_case_fixture(project)
    [default] = use_case.prompts

    {:ok, ko} = Prompts.open_prompt(%{use_case_id: use_case.id, name: "ko"}, scope(project))

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.open_prompt(%{use_case_id: use_case.id, name: "ko"}, scope(project))

    other = project_fixture()

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.open_prompt(%{use_case_id: use_case.id, name: "leak"}, scope(other))

    prompt_version_fixture(default)
    prompt_version_fixture(default)

    {:ok, loaded} =
      Prompts.get_prompt(
        default.id,
        Keyword.put(scope(project), :load, [:version_count, :latest_version_number])
      )

    assert loaded.version_count == 2
    assert loaded.latest_version_number == 2

    {:ok, ko} = Prompts.rename_prompt(ko, %{name: "korean"}, scope(project))
    assert ko.name == "korean"
    {:ok, _} = Prompts.archive_prompt(ko, scope(project))
    assert {:ok, [%{id: id}]} = Prompts.list_prompts(use_case.id, scope(project))
    assert id == default.id
  end

  test "prompt draft: save_draft touches only the mutable draft and creates no version" do
    project = project_fixture()
    use_case = use_case_fixture(project)
    [prompt] = use_case.prompts

    # no draft at first: the effective draft is the latest version (an empty document when there
    # is none)
    assert prompt.draft == nil
    assert Prompt.draft_content(prompt) == nil

    draft =
      Prompt.draft_map(:liquid, [%{role: "system", content: "draft instructions"}], nil)

    assert {:ok, saved} = Prompts.save_prompt_draft(prompt, %{draft: draft}, scope(project))
    assert saved.draft == draft

    # it must be the same value after a jsonb round trip for "do not write if unchanged" to hold.
    {:ok, reloaded} =
      Prompts.get_prompt(prompt.id, Keyword.put(scope(project), :load, [:version_count]))

    assert reloaded.draft == draft
    assert reloaded.version_count == 0

    assert %{engine: :liquid, text_template: nil, messages: [%{role: "system", content: content}]} =
             Prompt.draft_content(reloaded)

    assert content == "draft instructions"

    # clearing the draft returns to the "latest version is the effective draft" state.
    assert {:ok, cleared} = Prompts.save_prompt_draft(reloaded, %{draft: nil}, scope(project))
    assert cleared.draft == nil
  end

  test "prompt draft: the draft hash uses the same code as a committed version's content_sha256" do
    project = project_fixture()
    use_case = use_case_fixture(project)
    [prompt] = use_case.prompts

    version =
      prompt_version_fixture(prompt, %{messages: [%{role: :system, content: "same content"}]})

    same = PromptVersion.content_hash(:liquid, [%{role: "system", content: "same content"}], nil)

    other =
      PromptVersion.content_hash(:liquid, [%{role: "system", content: "other content"}], nil)

    assert version.content_sha256 == same
    refute version.content_sha256 == other
  end
end
