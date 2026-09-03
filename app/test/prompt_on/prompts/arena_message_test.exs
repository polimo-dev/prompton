defmodule PromptOn.Prompts.ArenaMessageTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Prompts

  setup do
    project = project_fixture()
    use_case = use_case_fixture(project, %{key: "chat_response"})
    sonnet = model_fixture(project, %{display_name: "Sonnet"})
    mini = model_fixture(project, %{display_name: "Mini"})

    %{project: project, use_case: use_case, sonnet: sonnet, mini: mini}
  end

  test "append records a user turn and a model answer with its observability columns", ctx do
    version = prompt_version_fixture(ctx.use_case)

    user_turn =
      arena_message_fixture(ctx.use_case, ctx.sonnet, %{role: :user, content: "  hi  "})

    assert user_turn.role == :user
    # @raw_string: the source text is the contract, so no trim
    assert user_turn.content == "  hi  "
    assert user_turn.status == :ok
    assert user_turn.params == %{}
    assert user_turn.prompt_version_number == nil
    assert user_turn.author_id == nil

    author = user_fixture()

    {:ok, answer} =
      Prompts.append_arena_message(
        %{
          use_case_id: ctx.use_case.id,
          model_id: ctx.sonnet.id,
          role: :assistant,
          content: "hello there",
          prompt_version_number: version.number,
          params: %{"temperature" => 0.2},
          latency_ms: 1234,
          input_tokens: 11,
          output_tokens: 22,
          cost_usd: Decimal.new("0.000123"),
          author_id: author.id
        },
        scope(ctx.project)
      )

    assert answer.role == :assistant
    assert answer.status == :ok
    assert answer.prompt_version_number == version.number
    assert answer.params == %{"temperature" => 0.2}
    assert answer.latency_ms == 1234
    assert answer.input_tokens == 11
    assert answer.output_tokens == 22
    assert Decimal.equal?(answer.cost_usd, Decimal.new("0.000123"))
    assert answer.author_id == author.id
    assert answer.project_id == ctx.project.id
  end

  test "an error turn keeps an empty content and carries the message", ctx do
    {:ok, failed} =
      Prompts.append_arena_message(
        %{
          use_case_id: ctx.use_case.id,
          model_id: ctx.mini.id,
          role: :assistant,
          status: :error,
          error_message: "provider returned 429"
        },
        scope(ctx.project)
      )

    assert failed.status == :error
    assert failed.content == ""
    assert failed.error_message == "provider returned 429"
  end

  test "role and status are constrained, use_case and model are required", ctx do
    base = %{use_case_id: ctx.use_case.id, model_id: ctx.sonnet.id, role: :user, content: "x"}

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.append_arena_message(%{base | role: :system}, scope(ctx.project))

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.append_arena_message(
               Map.put(base, :status, :pending),
               scope(ctx.project)
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.append_arena_message(Map.delete(base, :model_id), scope(ctx.project))

    assert {:error, %Ash.Error.Invalid{}} =
             Prompts.append_arena_message(Map.delete(base, :use_case_id), scope(ctx.project))
  end

  test "for_use_case returns every column in insert order, and filters by model", ctx do
    a = arena_message_fixture(ctx.use_case, ctx.sonnet, %{content: "one"})
    b = arena_message_fixture(ctx.use_case, ctx.mini, %{content: "one"})

    c =
      arena_message_fixture(ctx.use_case, ctx.sonnet, %{role: :assistant, content: "sonnet says"})

    d = arena_message_fixture(ctx.use_case, ctx.mini, %{role: :assistant, content: "mini says"})

    other_use_case = use_case_fixture(ctx.project, %{key: "diary_generation"})
    _elsewhere = arena_message_fixture(other_use_case, ctx.sonnet, %{content: "not here"})

    {:ok, all} = Prompts.arena_messages_for_use_case(ctx.use_case.id, scope(ctx.project))
    assert Enum.map(all, & &1.id) == [a.id, b.id, c.id, d.id]

    {:ok, sonnet_only} =
      Prompts.arena_messages_for_use_case(
        ctx.use_case.id,
        %{model_id: ctx.sonnet.id},
        scope(ctx.project)
      )

    assert Enum.map(sonnet_only, & &1.id) == [a.id, c.id]

    {:ok, mini_only} =
      Prompts.arena_messages_for_use_case(
        ctx.use_case.id,
        %{model_id: ctx.mini.id},
        scope(ctx.project)
      )

    assert Enum.map(mini_only, & &1.id) == [b.id, d.id]
  end

  test "insert order stays stable when many rows land in the same instant", ctx do
    inserted =
      for n <- 1..25 do
        arena_message_fixture(ctx.use_case, ctx.sonnet, %{content: "row #{n}"})
      end

    {:ok, listed} = Prompts.arena_messages_for_use_case(ctx.use_case.id, scope(ctx.project))
    assert Enum.map(listed, & &1.id) == Enum.map(inserted, & &1.id)
    assert Enum.map(listed, & &1.content) == Enum.map(1..25, &"row #{&1}")
  end

  test "clear_arena prunes one model column and leaves the rest of the use case alone", ctx do
    keep_use_case = use_case_fixture(ctx.project, %{key: "diary_generation"})

    _s1 = arena_message_fixture(ctx.use_case, ctx.sonnet)
    _s2 = arena_message_fixture(ctx.use_case, ctx.sonnet, %{role: :assistant})
    m1 = arena_message_fixture(ctx.use_case, ctx.mini)
    other = arena_message_fixture(keep_use_case, ctx.sonnet)

    assert %Ash.BulkResult{status: :success} =
             Prompts.clear_arena(
               ctx.use_case.id,
               %{model_id: ctx.sonnet.id},
               scope(ctx.project)
             )

    {:ok, left} = Prompts.arena_messages_for_use_case(ctx.use_case.id, scope(ctx.project))
    assert Enum.map(left, & &1.id) == [m1.id]

    {:ok, untouched} =
      Prompts.arena_messages_for_use_case(keep_use_case.id, scope(ctx.project))

    assert Enum.map(untouched, & &1.id) == [other.id]
  end

  test "clear_arena without a model wipes the whole use case only", ctx do
    keep_use_case = use_case_fixture(ctx.project, %{key: "diary_generation"})

    arena_message_fixture(ctx.use_case, ctx.sonnet)
    arena_message_fixture(ctx.use_case, ctx.mini)
    other = arena_message_fixture(keep_use_case, ctx.mini)

    assert %Ash.BulkResult{status: :success} =
             Prompts.clear_arena(ctx.use_case.id, scope(ctx.project))

    assert {:ok, []} = Prompts.arena_messages_for_use_case(ctx.use_case.id, scope(ctx.project))

    {:ok, untouched} = Prompts.arena_messages_for_use_case(keep_use_case.id, scope(ctx.project))
    assert Enum.map(untouched, & &1.id) == [other.id]
  end

  test "clear_arena never reaches another project's arena", ctx do
    arena_message_fixture(ctx.use_case, ctx.sonnet)

    other_project = project_fixture()
    other_use_case = use_case_fixture(other_project, %{key: "chat_response"})
    other_model = model_fixture(other_project)
    survivor = arena_message_fixture(other_use_case, other_model)

    # even when called with another project's use case id, nothing outside the tenant is touched
    assert %Ash.BulkResult{status: :success} =
             Prompts.clear_arena(other_use_case.id, scope(ctx.project))

    {:ok, still_there} =
      Prompts.arena_messages_for_use_case(other_use_case.id, scope(other_project))

    assert Enum.map(still_there, & &1.id) == [survivor.id]

    {:ok, mine} = Prompts.arena_messages_for_use_case(ctx.use_case.id, scope(ctx.project))
    assert length(mine) == 1
  end

  test "policies: member RW, stranger nothing, ApiKey nothing at all" do
    owner = user_fixture()
    project = project_fixture(%{user: owner})
    stranger = user_fixture()
    {api_key, _} = api_key_fixture(project)
    use_case = use_case_fixture(project, %{key: "chat_response"})
    model = model_fixture(project)

    input = %{
      use_case_id: use_case.id,
      model_id: model.id,
      role: :user,
      content: "hello"
    }

    assert {:ok, message} = Prompts.append_arena_message(input, scope(project, owner))

    assert {:error, %Ash.Error.Forbidden{}} =
             Prompts.append_arena_message(input, scope(project, stranger))

    assert {:error, %Ash.Error.Forbidden{}} =
             Prompts.append_arena_message(input, scope(project, api_key))

    assert {:ok, [seen]} = Prompts.arena_messages_for_use_case(use_case.id, scope(project, owner))
    assert seen.id == message.id

    assert {:ok, []} =
             Prompts.arena_messages_for_use_case(use_case.id, scope(project, stranger))

    # An ApiKey has no read bypass at all. Ash folds read policies into a filter, so the result is
    # always an empty list (not an error): unlike other resources, not even "its own project's"
    # rows leak.
    assert {:ok, []} =
             Prompts.arena_messages_for_use_case(use_case.id, scope(project, api_key))

    # non-member: ProjectMember is a filter check, so the bulk destroy deletes 0 rows (it succeeds
    # but deletes nothing)
    assert %Ash.BulkResult{status: :success} =
             Prompts.clear_arena(use_case.id, scope(project, stranger))

    # ApiKey: `forbid_if always()` cannot be expressed as a filter, so Forbidden surfaces as is
    assert %Ash.BulkResult{status: :error, errors: [%Ash.Error.Forbidden{} | _]} =
             Prompts.clear_arena(use_case.id, scope(project, api_key))

    assert {:ok, [survivor]} =
             Prompts.arena_messages_for_use_case(use_case.id, scope(project, owner))

    assert survivor.id == message.id

    assert %Ash.BulkResult{status: :success} =
             Prompts.clear_arena(use_case.id, scope(project, owner))

    assert {:ok, []} = Prompts.arena_messages_for_use_case(use_case.id, scope(project, owner))
  end

  test "arena_model_ids round-trips through set_arena_models and defaults to []", ctx do
    assert ctx.use_case.arena_model_ids == []

    {:ok, use_case} =
      Prompts.set_use_case_arena_models(
        ctx.use_case,
        %{arena_model_ids: [ctx.sonnet.id, ctx.mini.id]},
        scope(ctx.project)
      )

    assert use_case.arena_model_ids == [ctx.sonnet.id, ctx.mini.id]

    {:ok, reloaded} = Prompts.get_use_case(ctx.use_case.id, scope(ctx.project))
    assert reloaded.arena_model_ids == [ctx.sonnet.id, ctx.mini.id]

    # it is a replacement (not a merge)
    {:ok, replaced} =
      Prompts.set_use_case_arena_models(
        reloaded,
        %{arena_model_ids: [ctx.mini.id]},
        scope(ctx.project)
      )

    assert replaced.arena_model_ids == [ctx.mini.id]

    {:ok, emptied} =
      Prompts.set_use_case_arena_models(replaced, %{arena_model_ids: []}, scope(ctx.project))

    assert emptied.arena_model_ids == []
  end

  test "set_arena_models is forbidden for a stranger and for an ApiKey", ctx do
    stranger = user_fixture()
    {api_key, _} = api_key_fixture(ctx.project)

    for actor <- [stranger, api_key] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Prompts.set_use_case_arena_models(
                 ctx.use_case,
                 %{arena_model_ids: [ctx.sonnet.id]},
                 scope(ctx.project, actor)
               )
    end
  end
end
