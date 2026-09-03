defmodule PromptOnWeb.Plugs.UserTokenAuthTest do
  @moduledoc """
  Management API authentication plug. Covers **what differs** from the runtime key plug
  (`ApiKeyAuthTest`): the actor is a person, and neither tenant nor organization is set (the path
  picks both).
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Accounts.CliSession
  alias PromptOn.Accounts.User
  alias PromptOnWeb.Plugs.UserTokenAuth

  setup do
    user = user_fixture()
    %{user: user, token: cli_token_fixture(user)}
  end

  # Calling the plug directly requires params to be fetched (the error render looks at `_format`).
  defp call(conn, token \\ nil) do
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    conn
    |> fetch_query_params()
    |> Phoenix.Controller.put_format("json")
    |> UserTokenAuth.call([])
  end

  test "sets the user as actor and no tenant", %{conn: conn, user: user, token: token} do
    conn = call(conn, token)

    refute conn.halted
    assert %User{id: id} = Ash.PlugHelpers.get_actor(conn)
    assert id == user.id
    assert conn.assigns.current_user.id == user.id
    assert conn.assigns.bearer_token == token

    # Both tenant and organization are decided by the request path — not by the plug.
    assert is_nil(Ash.PlugHelpers.get_tenant(conn))
    refute Map.has_key?(conn.assigns, :organization)
  end

  test "401 for a missing or garbage token", %{conn: conn} do
    assert %{halted: true, status: 401} = call(conn)
    assert %{halted: true, status: 401} = call(conn, "not-a-jwt")

    assert %{halted: true, status: 401} =
             failed = call(conn, "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.nope")

    assert %{"error" => %{"code" => "unauthorized"}} = Jason.decode!(failed.resp_body)
  end

  test "401 once the token is revoked", %{conn: conn, token: token} do
    refute call(conn, token).halted

    :ok = CliSession.revoke(token)

    assert %{halted: true, status: 401} = call(conn, token)
  end

  test "401 for an expired token", %{conn: conn, user: user} do
    {:ok, expired, _claims} =
      AshAuthentication.Jwt.token_for_user(
        user,
        %{"purpose" => CliSession.purpose()},
        purpose: CliSession.purpose(),
        token_lifetime: {-1, :hours}
      )

    assert %{halted: true, status: 401} = call(conn, expired)
  end

  test "a browser session token is not a CLI session", %{conn: conn, user: user} do
    # The same token the code sign-in plants in the session (`PromptOnWeb.UserSession.sign_in/2`) —
    # its purpose is "user".
    {:ok, session_token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{})

    assert %{halted: true, status: 401} = call(conn, session_token)
  end

  test "a runtime project key is not a CLI session (and vice versa)", %{conn: conn, user: user} do
    project = project_fixture(%{user: user})
    {_runtime, runtime_raw} = api_key_fixture(project)

    assert %{halted: true, status: 401} = call(conn, runtime_raw)
  end
end
