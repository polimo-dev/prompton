defmodule PromptOn.Observability.AIUsageTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.{Accounts, Observability, Projects}
  alias PromptOn.Observability.{AIUsage, Generation}

  setup do
    owner = user_fixture()
    organization = team_org_fixture(%{user: owner}) |> set_plan(:team)
    project = project_fixture(%{user: owner, organization: organization})
    use_case = use_case_fixture(project)

    %{
      owner: owner,
      organization: organization,
      project: project,
      attrs: %{
        use_case_key: use_case.key,
        operation: :draft,
        model: "openai/test-model",
        input_tokens: 100,
        output_tokens: 20,
        cost_usd: "0.125",
        started_at: DateTime.utc_now()
      }
    }
  end

  test "project members read only their granted projects", ctx do
    member = user_fixture()

    Accounts.add_member!(
      %{organization_id: ctx.organization.id, user_id: member.id, role: :member},
      actor: system_actor()
    )

    Projects.grant_project_membership!(
      %{project_id: ctx.project.id, user_id: member.id},
      actor: ctx.owner
    )

    other = project_fixture(%{user: ctx.owner, organization: ctx.organization})
    own_usage = Observability.record_ai_usage!(ctx.attrs, scope(ctx.project))
    other_usage = Observability.record_ai_usage!(ctx.attrs, scope(other))

    assert [visible] = Ash.read!(AIUsage, scope(ctx.project, member))
    assert visible.id == own_usage.id
    assert Ash.read!(AIUsage, scope(other, member)) == []
    assert Ash.read!(AIUsage, scope(ctx.project, user_fixture())) == []

    # Even an owner who can read both projects gets only the requested tenant's rows.
    assert [visible] = Ash.read!(AIUsage, scope(other, ctx.owner))
    assert visible.id == other_usage.id
  end

  test "API keys cannot read AI accounting in either tenant", ctx do
    other = project_fixture()
    Observability.record_ai_usage!(ctx.attrs, scope(ctx.project))
    Observability.record_ai_usage!(ctx.attrs, scope(other))
    {api_key, _raw} = api_key_fixture(ctx.project, scopes: [:read, :logs])

    assert Ash.read!(AIUsage, scope(ctx.project, api_key)) == []
    assert Ash.read!(AIUsage, scope(other, api_key)) == []
    assert Ash.read!(AIUsage, tenant: ctx.project.id, actor: nil) == []
  end

  test "only the system actor can record completed calls", ctx do
    member = user_fixture()

    Accounts.add_member!(
      %{organization_id: ctx.organization.id, user_id: member.id, role: :member},
      actor: system_actor()
    )

    Projects.grant_project_membership!(
      %{project_id: ctx.project.id, user_id: member.id},
      actor: ctx.owner
    )

    {api_key, _raw} = api_key_fixture(ctx.project, scopes: [:read, :logs])

    for actor <- [ctx.owner, member, user_fixture(), api_key, nil] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Observability.record_ai_usage(ctx.attrs, tenant: ctx.project.id, actor: actor)
    end

    assert Ash.read!(AIUsage, scope(ctx.project)) == []

    assert {:ok, usage} = Observability.record_ai_usage(ctx.attrs, scope(ctx.project))
    assert usage.project_id == ctx.project.id
  end

  test "unknown cost remains distinct from an explicitly free completion", ctx do
    unknown =
      Observability.record_ai_usage!(Map.put(ctx.attrs, :cost_usd, nil), scope(ctx.project))

    free =
      Observability.record_ai_usage!(
        Map.merge(ctx.attrs, %{operation: :evaluation, cost_usd: "0"}),
        scope(ctx.project)
      )

    assert Ash.get!(AIUsage, unknown.id, scope(ctx.project)).cost_usd == nil
    assert Decimal.equal?(Ash.get!(AIUsage, free.id, scope(ctx.project)).cost_usd, 0)
  end

  test "repeated identical calls append immutable accounting without monitoring logs", ctx do
    first = Observability.record_ai_usage!(ctx.attrs, scope(ctx.project))
    second = Observability.record_ai_usage!(ctx.attrs, scope(ctx.project))

    assert first.id != second.id
    rows = Ash.read!(AIUsage, scope(ctx.project))
    assert MapSet.new(rows, & &1.id) == MapSet.new([first.id, second.id])
    assert Enum.all?(rows, &Decimal.equal?(&1.cost_usd, "0.125"))
    assert Ash.read!(Generation, scope(ctx.project)) == []

    refute Enum.any?(Ash.Resource.Info.actions(AIUsage), &(&1.type in [:update, :destroy]))
  end
end
