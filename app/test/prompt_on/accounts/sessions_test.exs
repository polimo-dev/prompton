defmodule PromptOn.Accounts.SessionsTest do
  @moduledoc """
  `PromptOn.Accounts.Sessions.revoke_all/2`: collects every stored token of one person (browser
  sessions and CLI sessions). Called by "Sign out everywhere" on the account screen
  (`PromptOnWeb.AccountLiveTest`).
  """
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Accounts.CliSession
  alias PromptOn.Accounts.Sessions
  alias PromptOn.Accounts.Token

  defp browser_token(user) do
    {:ok, token, %{"jti" => jti}} = AshAuthentication.Jwt.token_for_user(user, %{})
    {token, jti}
  end

  defp browser_alive?(token) do
    match?(
      {:ok, [_]},
      AshAuthentication.TokenResource.Actions.get_token(Token, %{
        "token" => token,
        "purpose" => "user"
      })
    )
  end

  test "revokes every stored token — browser and CLI" do
    user = user_fixture()
    {:ok, cli, _} = CliSession.issue(user)
    {browser, _jti} = browser_token(user)

    assert {:ok, _} = CliSession.verify(cli)
    assert browser_alive?(browser)

    assert :ok = Sessions.revoke_all(user)

    assert :error = CliSession.verify(cli)
    refute browser_alive?(browser)
    assert CliSession.list(user) == []
  end

  test "except: keeps exactly that session" do
    user = user_fixture()
    {mine, my_jti} = browser_token(user)
    {other, _} = browser_token(user)
    {:ok, cli, _} = CliSession.issue(user)

    assert :ok = Sessions.revoke_all(user, except: my_jti)

    assert browser_alive?(mine)
    refute browser_alive?(other)
    assert :error = CliSession.verify(cli)
  end

  test "another user's tokens are untouched" do
    user = user_fixture()
    bystander = user_fixture()
    {:ok, theirs, _} = CliSession.issue(bystander)
    {their_browser, _} = browser_token(bystander)

    assert :ok = Sessions.revoke_all(user)

    assert {:ok, _} = CliSession.verify(theirs)
    assert browser_alive?(their_browser)
  end

  test "is a no-op when there is nothing to revoke" do
    user = user_fixture()
    assert :ok = Sessions.revoke_all(user)
  end
end
