defmodule PromptOn.Prompts.PromptVersionTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Prompts
  alias PromptOn.Prompts.PromptVersion

  @messages [
    %{role: :system, content: "You are helpful."},
    %{
      role: :user,
      content:
        "{% if mode == \"incremental\" %}{{ existing_diary }}{% endif %}{{ transcriptions | join: \", \" }}"
    }
  ]

  @variables ~w(existing_diary mode transcriptions)

  setup do
    project = project_fixture()
    use_case = use_case_fixture(project, %{key: "diary_generation"})
    %{project: project, use_case: use_case, prompt: default_prompt(use_case)}
  end

  test "commits are numbered 1, 2, ... per prompt; other prompts have their own sequence", ctx do
    v1 = prompt_version_fixture(ctx.prompt)
    v2 = prompt_version_fixture(ctx.prompt)
    assert {v1.number, v2.number} == {1, 2}

    {:ok, ko} =
      Prompts.open_prompt(%{use_case_id: ctx.use_case.id, name: "ko"}, scope(ctx.project))

    assert prompt_version_fixture(ko).number == 1

    # concurrent commits: two processes numbering in their own transactions never collide
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(PromptOn.Repo, parent, self())
          prompt_version_fixture(ctx.prompt).number
        end)
      end

    numbers = Task.await_many(tasks)
    assert Enum.sort(numbers) == [3, 4]
  end

  test "commit computes detected_variables (sorted union) and content_sha256", ctx do
    version = prompt_version_fixture(ctx.prompt, %{messages: @messages})
    assert version.detected_variables == @variables
    assert version.content_sha256 == PromptVersion.content_hash(:liquid, @messages, nil)
    assert String.length(version.content_sha256) == 64
    assert version.engine == :liquid

    {:ok, loaded} =
      Prompts.get_prompt_version(
        version.id,
        Keyword.put(scope(ctx.project), :load, [:variable_names, :missing_in_schema])
      )

    assert loaded.variable_names == @variables
    assert loaded.missing_in_schema == @variables

    {:ok, _} =
      Prompts.set_use_case_input_schema(
        ctx.use_case,
        %{input_schema: [%{name: "transcriptions", type: :list, required?: true}]},
        scope(ctx.project)
      )

    {:ok, loaded} =
      Prompts.get_prompt_version(
        version.id,
        Keyword.put(scope(ctx.project), :load, [:missing_in_schema])
      )

    assert loaded.missing_in_schema == ["existing_diary", "mode"]

    raw =
      prompt_version_fixture(ctx.prompt, %{
        engine: :raw,
        messages: [%{role: :user, content: "{{ literal }}"}]
      })

    assert raw.detected_variables == []
  end

  test "lint rejects whitespace control, unknown filters and disallowed tags", ctx do
    for bad <- [
          "{%- if x -%}a{% endif %}",
          "{{ name | upcase }}",
          "{% capture x %}a{% endcapture %}",
          "{{ a "
        ] do
      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               Prompts.commit_prompt_version(
                 %{prompt_id: ctx.prompt.id, messages: [%{role: :user, content: bad}]},
                 scope(ctx.project)
               ),
             "expected #{inspect(bad)} to be rejected"

      assert error.field == :messages
      assert error.message =~ "template lint failed: message 1:"
    end

    # engine :raw is not linted
    assert {:ok, _} =
             Prompts.commit_prompt_version(
               %{
                 prompt_id: ctx.prompt.id,
                 engine: :raw,
                 messages: [%{role: :user, content: "{%- raw -%}"}]
               },
               scope(ctx.project)
             )
  end

  test "content must match the use case kind", ctx do
    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.commit_prompt_version(
               %{prompt_id: ctx.prompt.id, messages: []},
               scope(ctx.project)
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.commit_prompt_version(
               %{prompt_id: ctx.prompt.id, messages: @messages, text_template: "x"},
               scope(ctx.project)
             )

    text_uc = use_case_fixture(ctx.project, %{key: "voice_transcription", kind: :text})
    text_prompt = default_prompt(text_uc)

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.commit_prompt_version(
               %{prompt_id: text_prompt.id, messages: @messages},
               scope(ctx.project)
             )

    assert {:ok,
            %{text_template: "Diary entry, {{ language }}", detected_variables: ["language"]}} =
             Prompts.commit_prompt_version(
               %{prompt_id: text_prompt.id, text_template: "Diary entry, {{ language }}"},
               scope(ctx.project)
             )

    # a prompt_id of another project is "not found"
    other = project_fixture()

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.commit_prompt_version(
               %{prompt_id: ctx.prompt.id, messages: @messages},
               scope(other)
             )
  end

  test "versions are immutable — there is no update action, Save always commits a new one", ctx do
    v1 = prompt_version_fixture(ctx.prompt, %{messages: @messages, commit_message: "first"})

    actions =
      PromptVersion
      |> Ash.Resource.Info.actions()
      |> Enum.filter(&(&1.type in [:update, :destroy]))

    assert actions == []

    v2 =
      prompt_version_fixture(ctx.prompt, %{
        messages: [%{role: :user, content: "changed"}],
        commit_message: "second"
      })

    assert v2.number == v1.number + 1

    {:ok, reloaded} = Prompts.get_prompt_version(v1.id, scope(ctx.project))
    assert reloaded.content_sha256 == v1.content_sha256
    assert reloaded.commit_message == "first"
  end

  test "fork copies content, sets parent_version_id, numbers in target prompt", ctx do
    source = prompt_version_fixture(ctx.prompt, %{messages: @messages})

    {:ok, fork} =
      Prompts.fork_prompt_version(source.id, %{commit_message: "fork"}, scope(ctx.project))

    assert fork.number == 2
    assert fork.prompt_id == ctx.prompt.id
    assert fork.parent_version_id == source.id

    assert Enum.map(fork.messages, &{&1.role, &1.content}) ==
             Enum.map(source.messages, &{&1.role, &1.content})

    assert fork.content_sha256 == source.content_sha256
    assert fork.detected_variables == source.detected_variables

    {:ok, ko} =
      Prompts.open_prompt(%{use_case_id: ctx.use_case.id, name: "ko"}, scope(ctx.project))

    {:ok, fork_ko} =
      Prompts.fork_prompt_version(source.id, %{prompt_id: ko.id}, scope(ctx.project))

    assert fork_ko.prompt_id == ko.id
    assert fork_ko.number == 1
    assert fork_ko.parent_version_id == source.id

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.fork_prompt_version(Ash.UUIDv7.generate(), %{}, scope(ctx.project))
  end

  test "author_id is set from a User actor", ctx do
    owner = user_fixture()
    project = project_fixture(%{user: owner})
    use_case = use_case_fixture(project)

    {:ok, version} =
      Prompts.commit_prompt_version(
        %{prompt_id: default_prompt(use_case).id, messages: @messages},
        scope(project, owner)
      )

    assert version.author_id == owner.id
    assert prompt_version_fixture(ctx.prompt).author_id == nil
  end

  test "policies: member RW, stranger nothing, api key reads without a publish gate", ctx do
    owner = user_fixture()
    project = project_fixture(%{user: owner})
    stranger = user_fixture()
    {api_key, _} = api_key_fixture(project)
    use_case = use_case_fixture(project)
    prompt = default_prompt(use_case)

    v1 = prompt_version_fixture(prompt)
    v2 = prompt_version_fixture(prompt)

    assert {:ok, [_, _]} = Prompts.list_prompt_versions(prompt.id, scope(project, owner))
    assert {:ok, []} = Prompts.list_prompt_versions(prompt.id, scope(project, stranger))

    # No state machine: what is live is decided by the Deployment. An ApiKey reads every version
    # of the project.
    assert {:ok, visible} = Prompts.list_prompt_versions(prompt.id, scope(project, api_key))
    assert Enum.map(visible, & &1.id) |> Enum.sort() == Enum.sort([v1.id, v2.id])

    assert {:error, %Ash.Error.Forbidden{}} =
             Prompts.commit_prompt_version(
               %{prompt_id: prompt.id, messages: @messages},
               scope(project, stranger)
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Prompts.commit_prompt_version(
               %{prompt_id: prompt.id, messages: @messages},
               scope(project, api_key)
             )

    assert {:ok, _} =
             Prompts.commit_prompt_version(
               %{prompt_id: prompt.id, messages: @messages},
               scope(project, owner)
             )

    # another project's versions are not visible
    assert {:ok, []} = Prompts.list_prompt_versions(ctx.prompt.id, scope(project, owner))
  end
end
