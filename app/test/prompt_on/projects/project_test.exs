defmodule PromptOn.Projects.ProjectTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Projects

  test "creating a project creates production (protected) and staging environments" do
    project = project_fixture()
    slugs = project.environments |> Enum.map(& &1.slug) |> Enum.sort()
    assert slugs == ["production", "staging"]
    assert environment(project, "production").protected?
    refute environment(project, "staging").protected?
    assert project.payload_policy.mode == :full
    assert project.payload_policy.max_bytes == 262_144
  end

  test "members read their projects, strangers do not" do
    owner = user_fixture()
    project = project_fixture(%{user: owner})
    stranger = user_fixture()

    assert {:ok, [p]} = Projects.list_projects(actor: owner)
    assert p.id == project.id
    assert {:ok, []} = Projects.list_projects(actor: stranger)

    # Tenant-scoped resources require a tenant + the member policy
    assert {:ok, envs} = Projects.list_environments(tenant: project.id, actor: owner)
    assert length(envs) == 2
    assert {:ok, []} = Projects.list_environments(tenant: project.id, actor: stranger)
  end

  test "project slugs are unique per organization, not globally" do
    owner = user_fixture()
    personal = organization_for(owner)
    team = team_org_fixture(%{user: owner, slug: "slug-owner-team"})

    assert {:ok, a} = create_named(personal.id, "shared-slug", owner)
    assert a.organization_id == personal.id

    # The same slug is allowed in another organization: URLs are `/{org}/{project}`, no collision.
    assert {:ok, b} = create_named(team.id, "shared-slug", owner)
    assert b.organization_id == team.id
    refute a.id == b.id

    # Within the same organization it is refused.
    assert {:error, %Ash.Error.Invalid{}} = create_named(personal.id, "shared-slug", owner)
  end

  test "project slugs may not collide with organization-scoped static routes" do
    owner = user_fixture()
    personal = organization_for(owner)

    for reserved <- PromptOn.Accounts.ReservedSlugs.all_project() do
      assert {:error, %Ash.Error.Invalid{} = error} = create_named(personal.id, reserved, owner)

      assert Enum.any?(error.errors, &(Map.get(&1, :field) == :slug)),
             "#{reserved} was accepted as a project slug"
    end

    # Names merely prefixed with a reserved word are not blocked (only `/{org}/settings` collides).
    assert {:ok, _} = create_named(personal.id, "settings-app", owner)
  end

  test "get_project_by_slug is scoped to an organization" do
    owner = user_fixture()
    personal = organization_for(owner)
    team = team_org_fixture(%{user: owner, slug: "lookup-team"})

    {:ok, a} = create_named(personal.id, "lookup-me", owner)
    {:ok, b} = create_named(team.id, "lookup-me", owner)

    assert {:ok, %{id: id_a}} =
             Projects.get_project_by_slug(personal.id, "lookup-me", actor: owner)

    assert id_a == a.id

    assert {:ok, %{id: id_b}} = Projects.get_project_by_slug(team.id, "lookup-me", actor: owner)
    assert id_b == b.id

    stranger = user_fixture()

    assert {:ok, nil} =
             Projects.get_project_by_slug(personal.id, "lookup-me", actor: stranger)
  end

  defp create_named(organization_id, slug, actor) do
    Projects.create_project(
      %{organization_id: organization_id, name: slug, slug: slug},
      actor: actor
    )
  end

  test "api keys: issue returns raw key once, lookup by raw key, revoke invalidates" do
    project = project_fixture()
    {key, raw} = api_key_fixture(project)

    # The prefix is the **project** slug (2026-09-01: keys are not bound to an environment).
    prefix = "ptn_#{project.slug}_"
    assert String.starts_with?(raw, prefix)
    assert String.length(raw) == String.length(prefix) + 32
    assert key.key_prefix == String.slice(raw, 0, 16)
    assert key.key_hash == PromptOn.Projects.ApiKey.hash(raw)
    assert key.scopes == [:resolve, :logs]

    assert {:ok, %{id: id}} = Projects.api_key_by_raw_key(raw)
    assert id == key.id
    assert {:ok, nil} = Projects.api_key_by_raw_key("ptn_#{project.slug}_nope")

    {:ok, _} = Projects.revoke_api_key(key, actor: system_actor())
    assert {:ok, nil} = Projects.api_key_by_raw_key(raw)
  end

  test "api keys are project-scoped — no environment binding (2026-09-01)" do
    project = project_fixture()
    {key, _raw} = api_key_fixture(project)

    refute Map.has_key?(key, :environment_id)

    # One key calls both environments; the environment is chosen by the request parameter.
    assert Enum.map(project.environments, & &1.slug) |> Enum.sort() == ["production", "staging"]
  end
end
