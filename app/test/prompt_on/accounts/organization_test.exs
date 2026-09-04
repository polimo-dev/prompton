defmodule PromptOn.Accounts.OrganizationTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Accounts
  alias PromptOn.Accounts.Organization

  describe "personal organizations" do
    test "signup creates exactly one personal organization with no slug" do
      user = user_fixture(%{email: "alice@example.com"})

      assert {:ok, %Organization{} = org} =
               Accounts.personal_organization_for(user.id, actor: user)

      assert org.personal?
      assert is_nil(org.slug)
      assert org.name =~ "alice@example.com"
      assert org.name =~ "organization"

      assert {:ok, [only]} = Accounts.list_organizations_for(user.id, actor: user)
      assert only.id == org.id
    end

    test "many personal organizations coexist — nil slugs never collide" do
      users = for _ <- 1..3, do: user_fixture()
      orgs = Enum.map(users, &organization_for/1)

      assert Enum.all?(orgs, &is_nil(&1.slug))
      assert orgs |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3
    end

    test "personal_organization_for only sees the given user's org" do
      alice = user_fixture()
      bob = user_fixture()
      bob_org = organization_for(bob)

      assert {:ok, org} = Accounts.personal_organization_for(alice.id, actor: alice)
      refute org.id == bob_org.id

      # Another user's personal organization is caught by the actor policy (filter check -> empty).
      assert {:ok, nil} = Accounts.personal_organization_for(bob.id, actor: alice)
    end

    test "a team organization is not returned as a personal organization" do
      user = user_fixture()
      team = team_org_fixture(%{user: user})

      assert {:ok, personal} = Accounts.personal_organization_for(user.id, actor: user)
      refute personal.id == team.id
      refute team.personal?

      assert {:ok, orgs} = Accounts.list_organizations_for(user.id, actor: user)
      assert orgs |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([personal.id, team.id])
      # The personal organization comes first (switcher ordering).
      assert hd(orgs).id == personal.id
    end
  end

  describe "team organization slugs" do
    test "a team organization requires a slug" do
      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.create_organization(%{name: "No Slug"}, actor: system_actor())
    end

    test "slug format: lowercase, digits and dashes, starting alphanumeric" do
      for bad <- ["Acme", "acme_co", "-acme", "acme co", "acme!", "a", String.duplicate("a", 41)] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Accounts.create_organization(%{name: "x", slug: bad}, actor: system_actor()),
               "expected #{inspect(bad)} to be rejected"
      end

      for good <- ["ac", "acme", "acme-co", "9lives", String.duplicate("a", 40)] do
        assert {:ok, org} =
                 Accounts.create_organization(%{name: "x", slug: good}, actor: system_actor())

        assert org.slug == good
      end
    end

    test "reserved slugs are rejected" do
      assert PromptOn.Accounts.ReservedSlugs.reserved?("personal")

      for reserved <- ~w(personal settings projects admin api sign-in assets) do
        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 Accounts.create_organization(%{name: "x", slug: reserved},
                   actor: system_actor()
                 ),
               "expected #{reserved} to be rejected"

        assert Enum.any?(errors, &(&1.field == :slug))
      end
    end

    test "slugs are globally unique" do
      assert {:ok, _} =
               Accounts.create_organization(%{name: "One", slug: "dupe-me"},
                 actor: system_actor()
               )

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.create_organization(%{name: "Two", slug: "dupe-me"},
                 actor: system_actor()
               )
    end

    test "get_organization_by_slug resolves team orgs only" do
      user = user_fixture()
      team = team_org_fixture(%{user: user, slug: "acme-inc"})

      assert {:ok, %{id: id}} = Accounts.get_organization_by_slug("acme-inc", actor: user)
      assert id == team.id

      assert {:ok, nil} = Accounts.get_organization_by_slug("nope-not-here", actor: user)

      # A non-member cannot see it even knowing the slug.
      stranger = user_fixture()
      assert {:ok, nil} = Accounts.get_organization_by_slug("acme-inc", actor: stranger)
    end
  end

  describe "claim_slug" do
    test "a personal organization becomes a team organization by claiming a slug" do
      user = user_fixture()
      personal = organization_for(user)

      assert {:ok, promoted} =
               Accounts.claim_organization_slug(
                 personal,
                 %{slug: "promoted-co", name: "Promoted Co"},
                 actor: user
               )

      assert promoted.slug == "promoted-co"
      assert promoted.name == "Promoted Co"
      refute promoted.personal?

      assert {:ok, %{id: id}} = Accounts.get_organization_by_slug("promoted-co", actor: user)
      assert id == promoted.id
    end

    test "renaming without a slug keeps a personal organization personal" do
      user = user_fixture()
      personal = organization_for(user)

      assert {:ok, renamed} =
               Accounts.claim_organization_slug(personal, %{name: "My Space"}, actor: user)

      assert renamed.name == "My Space"
      assert renamed.personal?
      assert is_nil(renamed.slug)
    end

    test "claim_slug enforces format, reserved words and uniqueness" do
      user = user_fixture()
      personal = organization_for(user)
      _taken = team_org_fixture(%{user: user, slug: "taken-slug"})

      for bad <- ["Nope", "settings", "taken-slug", "x"] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Accounts.claim_organization_slug(personal, %{slug: bad}, actor: user),
               "expected #{bad} to be rejected"
      end
    end

    test "team rename through claim_slug keeps the org a team org" do
      user = user_fixture()
      team = team_org_fixture(%{user: user, slug: "keep-me"})

      assert {:ok, renamed} =
               Accounts.claim_organization_slug(team, %{name: "Renamed"}, actor: user)

      assert renamed.slug == "keep-me"
      refute renamed.personal?
    end
  end

  describe "policies" do
    test "non-members cannot read, rename or claim a slug" do
      owner = user_fixture()
      stranger = user_fixture()
      org = team_org_fixture(%{user: owner, slug: "closed-doors"})

      assert {:ok, []} = Accounts.list_organizations_for(owner.id, actor: stranger)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.rename_organization(org, %{name: "Hijacked"}, actor: stranger)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.claim_organization_slug(org, %{slug: "hijacked"}, actor: stranger)
    end

    # Organization creation was opened up to the UI (2026-09-01). Unless the creator becomes the
    # first owner member, the read policy (member filter) hides the just-created organization.
    # Since ADR 0010 the creator's own plan has to allow team organizations (the refusal itself is
    # `PromptOn.EntitlementsEnforcementTest`).
    test "a signed-in user on a paid plan creates a team organization and becomes its first owner" do
      user = user_fixture()
      set_plan(organization_for(user), :team)

      assert {:ok, org} =
               Accounts.create_organization(%{name: "Mine", slug: "mine-now"}, actor: user)

      refute org.personal?
      assert org.slug == "mine-now"

      # The creator reads it right away = the membership was created in the same transaction.
      assert {:ok, %{id: id}} = Accounts.get_organization_by_slug("mine-now", actor: user)
      assert id == org.id

      assert {:ok, memberships} =
               Accounts.list_memberships(
                 actor: user,
                 query: [filter: [organization_id: org.id]]
               )

      user_id = user.id
      assert [%{user_id: ^user_id, role: :owner}] = memberships

      # For another user it still might as well not exist.
      stranger = user_fixture()
      assert {:ok, nil} = Accounts.get_organization_by_slug("mine-now", actor: stranger)
    end

    test "personal organizations are still system-only (one per user, made at signup)" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.create_personal_organization(%{name: "Second"}, actor: user)
    end

    test "members read and rename their own organization" do
      owner = user_fixture()
      org = team_org_fixture(%{user: owner, slug: "open-doors"})

      assert {:ok, renamed} = Accounts.rename_organization(org, %{name: "Open"}, actor: owner)
      assert renamed.name == "Open"
    end
  end
end
