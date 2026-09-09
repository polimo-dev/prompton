defmodule PromptOnWeb.InvitationControllerTest do
  @moduledoc "HTTP coverage for invitation links and explicit Join."

  use PromptOnWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PromptOn.Accounts
  alias PromptOn.Fixtures
  alias PromptOn.Repo

  require Ash.Query

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "anonymous GET previews without creating the invited user, session, or membership", %{
    conn: conn
  } do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)
    invited_email = Fixtures.unique_email()
    {_invitation, path, _token} = invite(owner, org, invited_email, [project.id])

    conn = conn |> init_test_session(%{}) |> get(path)
    html = html_response(conn, 200)

    assert html =~ ~s(id="invitation-card")
    assert html =~ ~s(id="join-invitation-form")
    assert html =~ "Join #{org.name}"
    assert html =~ invited_email
    assert html =~ project.slug
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute get_session(conn, :user_token)
    assert {:ok, nil} = Accounts.get_user_by_email(invited_email, actor: Fixtures.system_actor())
    assert [] = memberships(org, invited_email)
  end

  test "Join creates and signs in the invited email without a verification code" do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)
    invited_email = Fixtures.unique_email()
    {_invitation, path, _token} = invite(owner, org, invited_email, [project.id])

    conn =
      build_conn()
      |> init_test_session(%{
        return_to: "https://evil.example/keep-me",
        sign_in_email: "stale@example.com"
      })
      |> post(path <> "/join", %{
        "email" => "attacker@example.com",
        "user_id" => owner.id
      })

    assert redirected_to(conn) == "/#{org.slug}"
    assert get_session(conn, :user_token)
    refute get_session(conn, :return_to)
    refute get_session(conn, :sign_in_email)

    invited = user_by_email(invited_email)
    assert conn.assigns.current_user.id == invited.id
    assert [_membership] = memberships(org, invited)
    assert project_granted?(project.id, invited.id)

    assert {:ok, nil} =
             Accounts.get_user_by_email("attacker@example.com", actor: Fixtures.system_actor())

    refute_email()
  end

  test "Join reuses an existing invited user and does not duplicate accounts" do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)
    invited = Fixtures.user_fixture(%{email: "Invited.Existing@example.com"})
    {_invitation, path, _token} = invite(owner, org, "invited.existing@example.com", [project.id])

    conn = build_conn() |> init_test_session(%{}) |> post(path <> "/join")

    assert redirected_to(conn) == "/#{org.slug}"
    assert conn.assigns.current_user.id == invited.id
    assert [_membership] = memberships(org, invited)
    assert user_count("INVITED.EXISTING@example.com") == 1
    refute_email()
  end

  test "wrong-account preview warns and explicit Join switches to the invited identity" do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)
    invited_email = Fixtures.unique_email()
    {_invitation, path, _token} = invite(owner, org, invited_email, [project.id])
    wrong_user = Fixtures.user_fixture()

    conn = build_conn() |> log_in_user(wrong_user) |> get(path)
    html = html_response(conn, 200)

    assert html =~ ~s(id="invitation-wrong-account-card")
    assert html =~ "This invitation was sent to"
    assert html =~ "Join as #{invited_email}"
    assert [] = memberships(org, wrong_user)

    conn = post(conn, path <> "/join", %{"email" => wrong_user.email, "user_id" => wrong_user.id})
    assert redirected_to(conn) == "/#{org.slug}"

    invited = user_by_email(invited_email)
    assert conn.assigns.current_user.id == invited.id
    assert [] = memberships(org, wrong_user)
    assert [_membership] = memberships(org, invited)
    refute_email()
  end

  test "invalid, expired, and revoked invitations reject without signup or signin" do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)

    conn = build_conn() |> init_test_session(%{}) |> post("/invitations/not-a-real-token/join")
    assert html_response(conn, 404) =~ "Invitation unavailable"
    refute get_session(conn, :user_token)

    expired_email = Fixtures.unique_email()
    {expired, expired_path, _token} = invite(owner, org, expired_email, [project.id])
    expire!(expired)

    conn = build_conn() |> init_test_session(%{}) |> post(expired_path <> "/join")
    assert html_response(conn, 404) =~ "Invitation unavailable"
    refute get_session(conn, :user_token)
    assert {:ok, nil} = Accounts.get_user_by_email(expired_email, actor: Fixtures.system_actor())
    assert [] = memberships(org, expired_email)

    revoked_email = Fixtures.unique_email()
    {revoked, revoked_path, _token} = invite(owner, org, revoked_email, [project.id])
    {:ok, _revoked} = Accounts.revoke_invitation(revoked, actor: owner)

    conn = build_conn() |> init_test_session(%{}) |> post(revoked_path <> "/join")
    assert html_response(conn, 404) =~ "Invitation unavailable"
    refute get_session(conn, :user_token)
    assert {:ok, nil} = Accounts.get_user_by_email(revoked_email, actor: Fixtures.system_actor())
    assert [] = memberships(org, revoked_email)
  end

  test "replaying an already consumed invitation cannot mint another session" do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)
    invited_email = Fixtures.unique_email()
    {_invitation, path, _token} = invite(owner, org, invited_email, [project.id])

    first = build_conn() |> init_test_session(%{}) |> post(path <> "/join")
    assert redirected_to(first) == "/#{org.slug}"

    replay = build_conn() |> init_test_session(%{}) |> post(path <> "/join")
    assert html_response(replay, 404) =~ "Invitation unavailable"
    refute get_session(replay, :user_token)
    assert [_membership] = memberships(org, user_by_email(invited_email))
    refute_email()
  end

  test "invalid links show a controlled error without leaking token logs", %{conn: conn} do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)
    {_invitation, path, token} = invite(owner, org, "invited@example.com", [project.id])

    log =
      capture_log(fn ->
        conn = conn |> init_test_session(%{}) |> get(path <> "-tampered")
        html = html_response(conn, 404)

        assert html =~ ~s(id="invitation-unavailable-card")
        assert html =~ "Invitation unavailable"
      end)

    refute log =~ token
    refute log =~ path
  end

  test "Join POST remains protected by browser CSRF" do
    owner = Fixtures.user_fixture()
    {org, project} = team_with_project(owner)
    invited_email = Fixtures.unique_email()
    {_invitation, path, _token} = invite(owner, org, invited_email, [project.id])

    conn =
      build_conn()
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> init_test_session(%{})

    assert_error_sent 403, fn -> post(conn, path <> "/join") end
    assert {:ok, nil} = Accounts.get_user_by_email(invited_email, actor: Fixtures.system_actor())
    assert [] = memberships(org, invited_email)
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

  defp user_count(email) do
    normalized = String.downcase(email)

    Repo.one!(
      from(u in "users",
        where: fragment("lower(?)", u.email) == ^normalized,
        select: count()
      )
    )
  end

  defp memberships(org, email) when is_binary(email) do
    case Accounts.get_user_by_email(email, actor: Fixtures.system_actor()) do
      {:ok, nil} -> []
      {:ok, user} -> memberships(org, user)
    end
  end

  defp memberships(org, user) do
    PromptOn.Accounts.Membership
    |> Ash.Query.filter(organization_id == ^org.id and user_id == ^user.id)
    |> Ash.read!(actor: Fixtures.system_actor())
  end

  defp project_granted?(project_id, user_id) do
    PromptOn.Projects.ProjectMembership
    |> Ash.Query.filter(project_id == ^project_id and user_id == ^user_id)
    |> Ash.exists?(actor: Fixtures.system_actor())
  end

  defp expire!(invitation) do
    Repo.update_all(
      from(i in "invitations", where: i.id == type(^invitation.id, :binary_id)),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end

  defp refute_email do
    refute_receive {:email, %Swoosh.Email{}}, 100
  end
end
