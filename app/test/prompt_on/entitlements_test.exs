defmodule PromptOn.EntitlementsTest do
  @moduledoc """
  `PromptOn.Entitlements` (ADR 0010 §2.9) — the table, the boundary of `check/4`, the shape of the
  refusal, and the self-hosting override. Enforcement at the four creation sites is
  `entitlements_enforcement_test.exs`.
  """
  use PromptOn.DataCase, async: false

  alias PromptOn.Entitlements
  alias PromptOn.Fixtures

  doctest PromptOn.Entitlements

  @limits [
    :projects_per_organization,
    :use_cases_per_project,
    :log_count_per_use_case,
    :log_retention_days,
    :members_per_organization,
    :team_organizations,
    :automatic_evaluation,
    :evaluation_sample_limit
  ]

  describe "the table" do
    test "every plan answers every limit" do
      assert Entitlements.plans() == [:free, :team, :pro]

      for plan <- Entitlements.plans(), limit <- @limits do
        value = Entitlements.limit(plan, limit)
        assert is_integer(value) or is_boolean(value), "#{plan}/#{limit} is #{inspect(value)}"
      end
    end

    test "free is the smallest and pro keeps logs longest" do
      assert Entitlements.limit(:free, :projects_per_organization) == 2
      assert Entitlements.limit(:free, :use_cases_per_project) == 10
      assert Entitlements.limit(:free, :log_count_per_use_case) == 1_000
      assert Entitlements.limit(:free, :log_retention_days) == 7
      assert Entitlements.limit(:free, :members_per_organization) == 1

      assert Entitlements.limit(:team, :log_retention_days) == 30
      assert Entitlements.limit(:pro, :log_retention_days) == 90
    end

    test "the boolean limits are the two paid features" do
      refute Entitlements.allows?(:free, :team_organizations)
      assert Entitlements.allows?(:team, :team_organizations)
      assert Entitlements.allows?(:pro, :team_organizations)

      refute Entitlements.allows?(:free, :automatic_evaluation)
      refute Entitlements.allows?(:team, :automatic_evaluation)
      assert Entitlements.allows?(:pro, :automatic_evaluation)
    end

    test "an unknown plan value falls back to free" do
      assert Entitlements.plan(:enterprise) == :free
      assert Entitlements.plan(nil) == :free
      assert Entitlements.limits(:enterprise) == Entitlements.limits(:free)
    end

    test "labels are the words the UI shows" do
      assert Entitlements.label(:free) == "Free"
      assert Entitlements.label(:team) == "Team"
      assert Entitlements.label(:pro) == "Pro"
    end
  end

  describe "check/4" do
    test "passes one below the limit and refuses at it" do
      assert :ok = Entitlements.check(:free, :projects_per_organization, 0, :plan)
      assert :ok = Entitlements.check(:free, :projects_per_organization, 1, :plan)
      assert {:error, _} = Entitlements.check(:free, :projects_per_organization, 2, :plan)
      assert {:error, _} = Entitlements.check(:free, :projects_per_organization, 9, :plan)

      # the same count is fine two plans up
      assert :ok = Entitlements.check(:team, :projects_per_organization, 2, :plan)
    end

    test "the refusal is an InvalidAttribute on the given field, naming the plan and the number" do
      assert {:error, error} =
               Entitlements.check(:free, :use_cases_per_project, 10, :plan)

      assert %Ash.Error.Changes.InvalidAttribute{} = error
      assert error.field == :plan
      assert error.message =~ "Free"
      assert error.message =~ "10"

      # ErrorText prefixes the field, so the sentence has to read on after "plan: ".
      assert PromptOnWeb.ErrorText.message(error) =~ "plan: the Free plan allows 10 use cases"
    end

    test "every limit has a sentence, and every sentence names its plan" do
      for plan <- Entitlements.plans(), limit <- @limits do
        message = Entitlements.message(plan, limit)
        assert message != ""
        assert message =~ ~r/Free|Team|Pro/
      end
    end
  end

  describe "reading a plan from a record" do
    test "an organization, its id and a project all resolve to the same plan" do
      user = Fixtures.user_fixture()
      organization = Fixtures.organization_for(user)
      project = Fixtures.project_fixture(%{user: user, organization: organization})

      assert Entitlements.plan(organization) == :free
      assert Entitlements.plan(organization.id) == :free
      assert Entitlements.plan_for_project(project) == :free
      assert Entitlements.plan_for_project(project.id) == :free

      Fixtures.set_plan(organization, :pro)

      assert Entitlements.plan(organization.id) == :pro
      assert Entitlements.plan_for_project(project.id) == :pro
      # a stale struct still carries the old value; the id is the source of truth
      assert Entitlements.plan(organization) == :free
    end

    test "an unknown id is free rather than an error" do
      assert Entitlements.plan(Ash.UUIDv7.generate()) == :free
      assert Entitlements.plan_for_project(Ash.UUIDv7.generate()) == :free
    end

    # `:free` is the safe direction for a creation gate and the destructive direction for the
    # retention job, which deletes. It gets an answer it can refuse to act on.
    test "plan_for_project_result/1 says when it could not read the plan" do
      user = Fixtures.user_fixture()
      organization = Fixtures.organization_for(user)
      project = Fixtures.project_fixture(%{user: user, organization: organization})

      assert Entitlements.plan_for_project_result(project) == {:ok, :free}
      assert Entitlements.plan_for_project_result(project.id) == {:ok, :free}

      Fixtures.set_plan(organization, :pro)
      assert Entitlements.plan_for_project_result(project.id) == {:ok, :pro}

      assert Entitlements.plan_for_project_result(Ash.UUIDv7.generate()) == :error
      assert Entitlements.plan_for_project_result(nil) == :error
    end
  end

  describe "entitlements_plan_override (self-hosting)" do
    setup do
      previous = Application.get_env(:prompton, :entitlements_plan_override)
      on_exit(fn -> Application.put_env(:prompton, :entitlements_plan_override, previous) end)
      :ok
    end

    test "makes every organization the overridden plan" do
      user = Fixtures.user_fixture()
      organization = Fixtures.organization_for(user)
      project = Fixtures.project_fixture(%{user: user, organization: organization})

      assert Entitlements.plan(organization) == :free

      Application.put_env(:prompton, :entitlements_plan_override, :pro)

      assert Entitlements.plan(organization) == :pro
      assert Entitlements.plan(organization.id) == :pro
      assert Entitlements.plan_for_project(project) == :pro
      assert Entitlements.plan_for_project_result(project) == {:ok, :pro}
      assert Entitlements.limits(organization) == Entitlements.limits(:pro)
      assert Entitlements.allows?(organization, :automatic_evaluation)
    end

    test "a nonsense override value is ignored" do
      Application.put_env(:prompton, :entitlements_plan_override, :enterprise)
      assert Entitlements.plan(:team) == :team
    end
  end
end
