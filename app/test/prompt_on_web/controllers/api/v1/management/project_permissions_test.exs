defmodule PromptOnWeb.API.V1.Management.ProjectPermissionsTest do
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures
  import PromptOnWeb.ManagementAPI

  alias PromptOn.Accounts
  alias PromptOn.Projects

  setup do
    owner = user_fixture()
    member = user_fixture()
    admin = user_fixture()
    organization = team_org_fixture(%{user: owner}) |> set_plan(:pro)

    for {user, role} <- [{member, :member}, {admin, :admin}] do
      Accounts.add_member!(
        %{organization_id: organization.id, user_id: user.id, role: role},
        actor: system_actor()
      )
    end

    assigned = project_fixture(%{user: owner, organization: organization})
    hidden = project_fixture(%{user: owner, organization: organization})

    grant =
      Projects.grant_project_membership!(%{project_id: assigned.id, user_id: member.id},
        actor: owner
      )

    %{
      organization: organization,
      assigned: assigned,
      hidden: hidden,
      grant: grant,
      owner: owner,
      member: member,
      member_token: cli_token_fixture(member),
      admin_token: cli_token_fixture(admin)
    }
  end

  test "a member can list and write assigned projects only", context do
    %{organization: org, member_token: token, assigned: assigned, hidden: hidden} = context
    body = json_response(api_get(token, ~p"/api/v1/orgs/#{org.slug}/projects"), 200)
    assert Enum.map(body["projects"], & &1["id"]) == [assigned.id]

    assert json_response(
             api_post(token, ~p"/api/v1/orgs/#{org.slug}/projects/#{assigned.slug}/use-cases", %{
               key: "allowed"
             }),
             201
           )["key"] == "allowed"

    for result <- [
          api_get(token, ~p"/api/v1/orgs/#{org.slug}/projects/#{hidden.slug}/use-cases"),
          api_post(token, ~p"/api/v1/orgs/#{org.slug}/projects/#{hidden.slug}/use-cases", %{
            key: "denied"
          })
        ] do
      assert json_response(result, 404)["error"]["code"] == "not_found"
    end
  end

  test "admin lists every project without individual grants", context do
    body =
      json_response(
        api_get(context.admin_token, ~p"/api/v1/orgs/#{context.organization.slug}/projects"),
        200
      )

    assert MapSet.new(Enum.map(body["projects"], & &1["id"])) ==
             MapSet.new([context.assigned.id, context.hidden.id])
  end

  test "member-created projects are immediately accessible and permissions refresh after revocation",
       context do
    %{organization: org, member_token: token, member: member} = context

    created =
      json_response(
        api_post(token, ~p"/api/v1/orgs/#{org.slug}/projects", %{key: "created-by-member"}),
        201
      )

    assert Projects.get_project!(created["id"], actor: member).creator_id == member.id

    assert json_response(
             api_get(token, ~p"/api/v1/orgs/#{org.slug}/projects/created-by-member/use-cases"),
             200
           )

    Projects.revoke_project_membership!(context.grant, actor: context.owner)

    assert json_response(
             api_get(
               token,
               ~p"/api/v1/orgs/#{org.slug}/projects/#{context.assigned.slug}/use-cases"
             ),
             404
           )
  end
end
