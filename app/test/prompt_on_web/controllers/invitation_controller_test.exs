defmodule PromptOnWeb.InvitationControllerTest do
  @moduledoc "HTTP coverage for invitation links and explicit Join."

  use PromptOnWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PromptOn.Accounts
  alias PromptOn.Fixtures

  require Ash.Query

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "an invited email signs in through return_to, previews, then joins explicitly", %{
    conn: conn
  } do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)
    invited_email = Fixtures.unique_email()
    {_invitation, path, _token} = invite(owner, org, invited_email, [project.id])

    conn = conn |> init_test_session(%{}) |> get(path)
    assert redirected_to(conn) == "/sign-in"
    assert get_session(conn, :return_to) == path

    conn = sign_in(conn, invited_email)
    assert redirected_to(conn) == path

    invited = user_by_email(invited_email)
    assert [] = memberships(org, invited)

    conn = get(conn, path)
    html = html_response(conn, 200)
    assert html =~ "Join #{org.name}"
    assert html =~ "Join"
    assert html =~ project.name
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert [] = memberships(org, invited)

    conn = post(conn, path <> "/join")
    assert redirected_to(conn) == "/#{org.slug}"
    assert [_membership] = memberships(org, invited)
  end

  test "opening the join POST while signed out returns to the preview GET path", %{conn: conn} do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)
    {_invitation, path, _token} = invite(owner, org, Fixtures.unique_email(), [project.id])

    conn = conn |> init_test_session(%{}) |> post(path <> "/join")

    assert redirected_to(conn) == "/sign-in"
    assert get_session(conn, :return_to) == path
  end

  test "invalid and wrong-account links show a controlled error without leaking token logs", %{
    conn: conn
  } do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)
    {_invitation, path, token} = invite(owner, org, "invited@example.com", [project.id])
    wrong_user = Fixtures.user_fixture(%{email: "wrong@example.com"})

    log =
      capture_log(fn ->
        conn = conn |> log_in_user(wrong_user) |> get(path)
        html = html_response(conn, 404)

        assert html =~ "Invitation unavailable"
        assert html =~ "Sign out and use another account"
      end)

    refute log =~ token
    refute log =~ path

    conn = build_conn() |> log_in_user(wrong_user) |> get(~p"/invitations/not-a-real-token")
    html = html_response(conn, 404)
    assert html =~ "Invitation unavailable"
    assert html =~ "Sign out and use another account"
  end

  defp invite(owner, org, email, project_ids) do
    {:ok, invitation} =
      Accounts.invite_member(
        %{organization_id: org.id, email: email, role: :member, project_ids: project_ids},
        actor: owner
      )

    token = Ash.Resource.get_metadata(invitation, :token)
    assert_receive {:email, %Swoosh.Email{text_body: text}}, 500
    [_, url] = Regex.run(~r{(http://[^\s]+/invitations/[^\s]+)}, text)
    assert URI.parse(url).path == "/invitations/#{token}"
    {invitation, URI.parse(url).path, token}
  end

  defp sign_in(conn, email) do
    conn = post(conn, ~p"/sign-in", %{"email" => email})
    assert_receive {:email, %Swoosh.Email{text_body: text}}, 500
    [_, code] = Regex.run(~r/^(\d{6})$/m, text)
    post(conn, ~p"/sign-in/verify", %{"code" => code})
  end

  defp team_with_project(owner) do
    Fixtures.set_plan(Fixtures.organization_for(owner), :team)

    org =
      Fixtures.team_org_fixture(%{
        user: owner,
        slug: "team-#{System.unique_integer([:positive])}"
      })

    Fixtures.set_plan(org, :team)

    project = Fixtures.project_fixture(%{user: owner, organization: org})
    {org, project}
  end

  defp user_by_email(email) do
    {:ok, user} = Accounts.get_user_by_email(email, actor: Fixtures.system_actor())
    user
  end

  defp memberships(org, user) do
    PromptOn.Accounts.Membership
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
    |> Ash.read!(actor: Fixtures.system_actor())
  end
end
