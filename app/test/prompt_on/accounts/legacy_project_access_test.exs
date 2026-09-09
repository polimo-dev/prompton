defmodule PromptOn.Accounts.LegacyProjectAccessTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Accounts
  alias PromptOn.Projects
  alias PromptOn.Projects.ProjectMembership

  test "legacy role migration preserves existing projects without inventing creators or granting new members access" do
    owner = user_fixture()
    organization = team_org_fixture(%{user: owner}) |> set_plan(:pro)
    existing = project_fixture(%{user: owner, organization: organization})
    unrelated = project_fixture()
    legacy = user_fixture()
    member = user_fixture()

    for user <- [legacy, member] do
      Accounts.add_member!(
        %{organization_id: organization.id, user_id: user.id, role: :member},
        actor: system_actor()
      )
    end

    PromptOn.Repo.query!(
      "UPDATE memberships SET role = 'editor' WHERE user_id = $1 AND organization_id = $2",
      [Ecto.UUID.dump!(legacy.id), Ecto.UUID.dump!(organization.id)]
    )

    statement =
      ProjectMembership
      |> AshPostgres.DataLayer.Info.custom_statements()
      |> Enum.find(&(&1.name == :backfill_legacy_project_access))

    assert is_nil(Projects.get_project!(existing.id, actor: legacy))
    PromptOn.Repo.query!(statement.up)
    PromptOn.Repo.query!(statement.up)

    assert Projects.get_project!(existing.id, actor: legacy).id == existing.id
    assert is_nil(Projects.get_project!(unrelated.id, actor: legacy))
    assert is_nil(Projects.get_project!(existing.id, actor: member))
    assert Projects.get_project!(existing.id, actor: owner).creator_id == owner.id
  end
end
