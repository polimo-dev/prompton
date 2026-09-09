defmodule PromptOn.Accounts.OrganizationPlanTest do
  @moduledoc """
  `Organization.plan`, `Organization.judge_model`, and `Organization.draft_model` (ADR 0010 §2.8):
  the plan defaults to `:free` and is writable by the system actor alone (there is no billing and
  no self-serve change), while model settings are manager-editable organization settings.
  """
  use PromptOn.DataCase, async: true

  alias PromptOn.Accounts
  alias PromptOn.Fixtures

  setup do
    user = Fixtures.user_fixture()
    %{user: user, organization: Fixtures.organization_for(user)}
  end

  describe "plan" do
    test "defaults to free", %{organization: organization} do
      assert organization.plan == :free
      assert is_nil(organization.judge_model)
      assert is_nil(organization.draft_model)
    end

    test "the system actor sets it", %{organization: organization} do
      assert {:ok, updated} =
               Accounts.set_organization_plan(organization, %{plan: :pro},
                 actor: Fixtures.system_actor()
               )

      assert updated.plan == :pro
    end

    test "a member cannot set it, and neither can a stranger or an ApiKey", %{
      user: user,
      organization: organization
    } do
      project = Fixtures.project_fixture(%{user: user, organization: organization})
      {api_key, _raw} = Fixtures.api_key_fixture(project)
      stranger = Fixtures.user_fixture()

      for actor <- [user, stranger, api_key] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.set_organization_plan(organization, %{plan: :pro}, actor: actor)
      end

      assert Fixtures.organization_for(user).plan == :free
    end

    test "only the listed values are accepted", %{organization: organization} do
      assert {:error, error} =
               Accounts.set_organization_plan(organization, %{plan: :enterprise},
                 actor: Fixtures.system_actor()
               )

      assert PromptOnWeb.ErrorText.message(error) =~ "plan"
    end
  end

  describe "judge_model" do
    test "an owner sets and clears it", %{user: user, organization: organization} do
      assert {:ok, updated} =
               Accounts.set_organization_judge_model(
                 organization,
                 %{judge_model: "openai/gpt-4.1-mini"},
                 actor: user
               )

      assert updated.judge_model == "openai/gpt-4.1-mini"

      assert {:ok, cleared} =
               Accounts.set_organization_judge_model(updated, %{judge_model: nil}, actor: user)

      assert is_nil(cleared.judge_model)
    end

    test "a stranger cannot", %{organization: organization} do
      stranger = Fixtures.user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.set_organization_judge_model(organization, %{judge_model: "x"},
                 actor: stranger
               )
    end
  end

  describe "draft_model" do
    test "has no draft model until one is selected", %{organization: organization} do
      for value <- [nil, "", "   "] do
        assert is_nil(
                 PromptOn.Accounts.Organization.effective_draft_model(%{
                   organization
                   | draft_model: value
                 })
               )
      end
    end

    test "an owner sets and clears it", %{user: user, organization: organization} do
      assert {:ok, updated} =
               Accounts.set_organization_draft_model(
                 organization,
                 %{draft_model: "openai/gpt-4.1-mini"},
                 actor: user
               )

      assert updated.draft_model == "openai/gpt-4.1-mini"

      assert PromptOn.Accounts.Organization.effective_draft_model(updated) ==
               "openai/gpt-4.1-mini"

      assert {:ok, cleared} =
               Accounts.set_organization_draft_model(updated, %{draft_model: nil}, actor: user)

      assert is_nil(cleared.draft_model)

      assert is_nil(PromptOn.Accounts.Organization.effective_draft_model(cleared))
    end

    test "an admin can set it, while a member and stranger cannot" do
      owner = Fixtures.user_fixture()
      organization = Fixtures.team_org_fixture(%{user: owner}) |> Fixtures.set_plan(:pro)
      admin = add_member!(organization, :admin)
      member = add_member!(organization, :member)
      stranger = Fixtures.user_fixture()

      assert {:ok, updated} =
               Accounts.set_organization_draft_model(
                 organization,
                 %{draft_model: "anthropic/claude-opus-4"},
                 actor: admin
               )

      assert updated.draft_model == "anthropic/claude-opus-4"

      for actor <- [member, stranger] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.set_organization_draft_model(
                   updated,
                   %{draft_model: "openai/gpt-4.1-mini"},
                   actor: actor
                 )
      end
    end
  end

  defp add_member!(organization, role) do
    user = Fixtures.user_fixture()

    {:ok, _membership} =
      Accounts.add_member(
        %{organization_id: organization.id, user_id: user.id, role: role},
        actor: Fixtures.system_actor()
      )

    user
  end
end
