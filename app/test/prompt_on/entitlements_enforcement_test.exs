defmodule PromptOn.EntitlementsEnforcementTest do
  @moduledoc """
  The four creation sites that ask `PromptOn.Entitlements` for permission (ADR 0010 §6): projects
  per organization, use cases per project, team organizations, and members per organization.

  Each one is checked at the boundary (the last allowed one succeeds, the next is refused with the
  sentence people read) and one plan up, plus the two escape hatches that must never break: the
  system actor (seeds, the HeyDiary import, fixtures) and the first owner membership of a fresh
  organization (the sign-up path).
  """
  use PromptOn.DataCase, async: true

  alias PromptOn.Accounts
  alias PromptOn.Fixtures
  alias PromptOn.Projects
  alias PromptOn.Prompts
  alias PromptOnWeb.ErrorText

  defp create_project(organization, user, slug) do
    Projects.create_project(
      %{organization_id: organization.id, name: slug, slug: slug},
      actor: user
    )
  end

  describe "projects per organization" do
    setup do
      user = Fixtures.user_fixture()
      %{user: user, organization: Fixtures.organization_for(user)}
    end

    test "free allows two and refuses the third", %{user: user, organization: organization} do
      assert {:ok, _} = create_project(organization, user, "one")
      assert {:ok, _} = create_project(organization, user, "two")

      assert {:error, error} = create_project(organization, user, "three")

      assert ErrorText.message(error) ==
               "plan: the Free plan allows 2 projects per organization. " <>
                 "Archive a project, or upgrade the organization to Team."
    end

    test "team allows the third", %{user: user, organization: organization} do
      assert {:ok, _} = create_project(organization, user, "one")
      assert {:ok, _} = create_project(organization, user, "two")

      Fixtures.set_plan(organization, :team)

      assert {:ok, _} = create_project(organization, user, "three")
    end

    test "an archived project makes room again", %{user: user, organization: organization} do
      assert {:ok, first} = create_project(organization, user, "one")
      assert {:ok, _} = create_project(organization, user, "two")
      assert {:error, _} = create_project(organization, user, "three")

      {:ok, _archived} = Projects.archive_project(first, actor: Fixtures.system_actor())

      assert {:ok, _} = create_project(organization, user, "three")
    end

    test "the system actor is never blocked", %{organization: organization} do
      for slug <- ~w(a b c d) do
        assert {:ok, _} =
                 Projects.create_project(
                   %{organization_id: organization.id, name: slug, slug: slug},
                   actor: Fixtures.system_actor()
                 )
      end
    end
  end

  describe "use cases per project" do
    setup do
      user = Fixtures.user_fixture()
      %{user: user, project: Fixtures.project_fixture(%{user: user})}
    end

    defp define_use_case(project, actor, key) do
      Prompts.define_use_case(%{key: key, name: key}, tenant: project.id, actor: actor)
    end

    test "free allows ten and refuses the eleventh", %{user: user, project: project} do
      for i <- 1..10 do
        assert {:ok, _} = define_use_case(project, user, "uc_#{i}")
      end

      assert {:error, error} = define_use_case(project, user, "uc_11")

      assert ErrorText.message(error) ==
               "plan: the Free plan allows 10 use cases per project. " <>
                 "Archive a use case, or upgrade the organization to Team."
    end

    test "team allows the eleventh", %{user: user, project: project} do
      for i <- 1..10 do
        assert {:ok, _} = define_use_case(project, user, "uc_#{i}")
      end

      Fixtures.set_plan(project, :team)

      assert {:ok, _} = define_use_case(project, user, "uc_11")
    end

    test "the system actor is never blocked (the HeyDiary import path)", %{project: project} do
      for i <- 1..12 do
        assert {:ok, _} = define_use_case(project, Fixtures.system_actor(), "uc_#{i}")
      end
    end
  end

  describe "team organizations" do
    test "a free account cannot create one; a team account can" do
      user = Fixtures.user_fixture()

      assert {:error, error} =
               Accounts.create_organization(%{name: "Acme", slug: "acme-free"}, actor: user)

      assert ErrorText.message(error) ==
               "plan: team organizations are a Team plan feature. " <>
                 "Your account is on the Free plan."

      Fixtures.set_plan(Fixtures.organization_for(user), :team)

      assert {:ok, organization} =
               Accounts.create_organization(%{name: "Acme", slug: "acme-paid"}, actor: user)

      # the creator's plan comes with them (`Changes.AddCreatorAsOwner`): a team organization born
      # on `:free` would accept no second member, which is what the plan just paid for
      assert organization.plan == :team
    end

    test "the system actor is never blocked (fixtures and seeds)" do
      assert {:ok, _} =
               Accounts.create_organization(%{name: "Seeded", slug: "seeded-org"},
                 actor: Fixtures.system_actor()
               )
    end
  end

  describe "members per organization" do
    test "the first owner membership of a fresh organization always succeeds" do
      # sign-up itself: personal organization + owner membership
      user = Fixtures.user_fixture()
      organization = Fixtures.organization_for(user)
      assert organization.personal?

      # and the first membership of a team organization, which starts free
      owner = Fixtures.user_fixture()
      Fixtures.set_plan(Fixtures.organization_for(owner), :team)

      assert {:ok, team} =
               Accounts.create_organization(%{name: "Acme", slug: "acme-members"}, actor: owner)

      # `AddCreatorAsOwner` runs inside `:create`, so a refused owner membership would have failed
      # the creation above. It did not, and the row is there.
      assert {:ok, [membership]} = memberships(team)
      assert membership.user_id == owner.id
      assert membership.role == :owner
    end

    defp memberships(organization) do
      with {:ok, all} <- Accounts.list_memberships(actor: Fixtures.system_actor()) do
        {:ok, Enum.filter(all, &(&1.organization_id == organization.id))}
      end
    end

    test "a second member is refused on free and allowed on team" do
      owner = Fixtures.user_fixture()
      Fixtures.set_plan(Fixtures.organization_for(owner), :team)

      {:ok, team} =
        Accounts.create_organization(%{name: "Acme", slug: "acme-second"}, actor: owner)

      mate = Fixtures.user_fixture()

      # the organization inherited :team from its creator, so the second member goes in
      assert {:ok, _} =
               Accounts.add_member(%{organization_id: team.id, user_id: mate.id, role: :editor},
                 actor: Fixtures.system_actor()
               )

      # dropped back to free by the admin: the next member is refused
      Fixtures.set_plan(team, :free)
      third = Fixtures.user_fixture()

      assert {:error, error} =
               Accounts.add_member(%{organization_id: team.id, user_id: third.id, role: :editor},
                 actor: Fixtures.system_actor()
               )

      assert ErrorText.message(error) ==
               "plan: the Free plan is a single-member organization. " <>
                 "Upgrade to Team to invite members."
    end

    test "a personal organization is skipped entirely" do
      user = Fixtures.user_fixture()
      personal = Fixtures.organization_for(user)
      mate = Fixtures.user_fixture()

      # personal organizations are single-member by product rule, not by plan limit — the owner row
      # must always be creatable, so the validation does not run here at all
      assert {:ok, _} =
               Accounts.add_member(
                 %{organization_id: personal.id, user_id: mate.id, role: :viewer},
                 actor: Fixtures.system_actor()
               )
    end
  end
end
