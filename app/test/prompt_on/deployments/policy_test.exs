defmodule PromptOn.Deployments.PolicyTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Deployments
  alias PromptOn.Deployments.Deployment

  setup do
    project = project_fixture()
    production = environment(project, "production")
    staging = environment(project, "staging")
    use_case = use_case_fixture(project)
    version = prompt_version_fixture(use_case)
    model = model_fixture(project)

    {:ok, loaded} =
      Ash.load(project, [organization: [memberships: [:user]]], actor: system_actor())

    member = hd(loaded.organization.memberships).user

    live =
      deployment_fixture(use_case, production, %{
        model_id: model.id,
        prompt_pins: %{"default" => version.id}
      })

    %{
      project: project,
      production: production,
      staging: staging,
      use_case: use_case,
      version: version,
      model: model,
      member: member,
      live: live,
      opts: scope(project)
    }
  end

  defp commit_input(ctx),
    do: %{
      use_case_id: ctx.use_case.id,
      environment_id: ctx.production.id,
      model_id: ctx.model.id,
      prompt_pins: %{"default" => ctx.version.id}
    }

  test "a project member reads and commits", ctx do
    opts = scope(ctx.project, ctx.member)

    {:ok, [%Deployment{id: id}]} = Ash.read(Deployment, opts)
    assert id == ctx.live.id

    assert {:ok, %Deployment{revision: 2}} =
             Deployments.commit_deployment(commit_input(ctx), opts)

    assert {:ok, %Deployment{revision: 3}} =
             Deployments.rollback_deployment(ctx.live.id, %{}, opts)

    assert {:ok, %Deployment{revision: 3}} =
             Deployments.current_deployment(ctx.use_case.id, ctx.production.id, opts)
  end

  test "a non-member sees nothing and cannot commit", ctx do
    opts = scope(ctx.project, user_fixture())

    assert {:ok, []} = Ash.read(Deployment, opts)

    assert {:ok, nil} =
             Deployments.current_deployment(ctx.use_case.id, ctx.production.id, opts)

    assert {:ok, []} = Deployments.current_deployments_for_environment(ctx.production.id, opts)
    assert {:ok, []} = Deployments.deployment_history(ctx.use_case.id, ctx.production.id, opts)

    assert {:error, %Ash.Error.Forbidden{}} =
             Deployments.commit_deployment(commit_input(ctx), opts)

    assert {:error, %Ash.Error.Forbidden{}} =
             Deployments.rollback_deployment(ctx.live.id, %{}, opts)
  end

  test "an ApiKey reads every environment of its own project but never writes", ctx do
    {api_key, _raw} = api_key_fixture(ctx.project)
    opts = scope(ctx.project, api_key)

    {:ok, [%Deployment{id: id}]} = Ash.read(Deployment, opts)
    assert id == ctx.live.id

    assert {:ok, %Deployment{id: ^id}} =
             Deployments.current_deployment(ctx.use_case.id, ctx.production.id, opts)

    assert {:ok, [%Deployment{id: ^id}]} =
             Deployments.current_deployments_for_environment(ctx.production.id, opts)

    assert {:ok, [%Deployment{id: ^id}]} =
             Deployments.deployment_history(ctx.use_case.id, ctx.production.id, opts)

    assert {:error, %Ash.Error.Forbidden{}} =
             Deployments.commit_deployment(commit_input(ctx), opts)

    assert {:error, %Ash.Error.Forbidden{}} =
             Deployments.rollback_deployment(ctx.live.id, %{}, opts)
  end

  test "an ApiKey is no longer bound to one environment (2026-09-01)", ctx do
    staging_live =
      deployment_fixture(ctx.use_case, ctx.staging, %{
        model_id: ctx.model.id,
        prompt_pins: %{"default" => ctx.version.id}
      })

    {api_key, _raw} = api_key_fixture(ctx.project)
    opts = scope(ctx.project, api_key)

    # one key reads both production and staging: the environment is chosen by a request parameter.
    assert {:ok, [%Deployment{id: production_id}]} =
             Deployments.current_deployments_for_environment(ctx.production.id, opts)

    assert production_id == ctx.live.id

    assert {:ok, [%Deployment{id: staging_id}]} =
             Deployments.current_deployments_for_environment(ctx.staging.id, opts)

    assert staging_id == staging_live.id
  end

  test "an ApiKey of another project sees nothing even when the tenant option is spoofed", ctx do
    other_project = project_fixture()
    {foreign_key, _raw} = api_key_fixture(other_project)

    # a call that would pass if only the tenant option were trusted; the policy pins it to the
    # actor's project_id
    assert {:ok, []} = Ash.read(Deployment, tenant: ctx.project.id, actor: foreign_key)

    assert {:ok, nil} =
             Deployments.current_deployment(
               ctx.use_case.id,
               ctx.production.id,
               tenant: ctx.project.id,
               actor: foreign_key
             )

    assert {:ok, []} =
             Deployments.current_deployments_for_environment(
               ctx.production.id,
               tenant: ctx.project.id,
               actor: foreign_key
             )
  end

  test "the system actor bypasses everything", ctx do
    assert {:ok, [_]} = Ash.read(Deployment, ctx.opts)

    assert {:ok, %Deployment{revision: 2}} =
             Deployments.commit_deployment(commit_input(ctx), ctx.opts)
  end
end
