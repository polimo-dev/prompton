defmodule PromptOn.Accounts.CliSessionTest do
  @moduledoc """
  CLI session tokens: issue, verify, revoke. Since this credential stands in for a management key,
  all that matters here is "who is it" (the actor) and "when does it die" (expiry, revocation,
  purpose).
  """
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  require Ash.Query

  alias PromptOn.Accounts.CliSession
  alias PromptOn.Accounts.Token
  alias PromptOn.Accounts.User

  test "issues a non-expiring (100-year) token stored with purpose \"cli\"" do
    user = user_fixture()

    assert {:ok, _token, claims} = CliSession.issue(user)
    assert claims["purpose"] == "cli"

    lifetime = claims["exp"] - claims["iat"]
    assert lifetime == CliSession.lifetime_days() * 24 * 60 * 60

    jti = claims["jti"]

    assert {:ok, [stored]} =
             Token
             |> Ash.Query.filter(jti == ^jti)
             |> Ash.read(authorize?: false)

    assert stored.purpose == "cli"
    assert stored.subject == AshAuthentication.user_to_subject(user)

    # Only the jti and the expiry are stored; the raw token is nowhere.
    refute Map.has_key?(stored, :token)
  end

  test "verify resolves the token back to the user" do
    user = user_fixture()
    {:ok, token, _claims} = CliSession.issue(user)

    assert {:ok, %User{id: id}} = CliSession.verify(token)
    assert id == user.id
  end

  test "verify rejects garbage, revoked, expired and non-cli tokens" do
    user = user_fixture()

    assert :error = CliSession.verify("nope")
    assert :error = CliSession.verify("")

    {:ok, revoked, _claims} = CliSession.issue(user)
    assert {:ok, _user} = CliSession.verify(revoked)
    assert :ok = CliSession.revoke(revoked)
    assert :error = CliSession.verify(revoked)

    {:ok, expired, _claims} =
      AshAuthentication.Jwt.token_for_user(user, %{"purpose" => "cli"},
        purpose: "cli",
        token_lifetime: {-1, :hours}
      )

    assert :error = CliSession.verify(expired)

    # A browser session token (purpose "user") is not a management API credential.
    {:ok, session_token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{})
    assert :error = CliSession.verify(session_token)
  end

  test "each issue is a separate credential" do
    user = user_fixture()
    {:ok, laptop, _} = CliSession.issue(user)
    {:ok, desktop, _} = CliSession.issue(user)

    refute laptop == desktop

    assert :ok = CliSession.revoke(laptop)
    assert :error = CliSession.verify(laptop)
    assert {:ok, _user} = CliSession.verify(desktop)
  end

  describe "logged-in devices" do
    test "issue records the device name and client; list shows live sessions newest first" do
      user = user_fixture()

      {:ok, _old, %{"jti" => old_jti}} =
        CliSession.issue(user, client: "prompton-cli/0.1.0 (linux/amd64)", name: "CLI on box")

      {:ok, _new, %{"jti" => new_jti}} =
        CliSession.issue(user, client: "prompton-cli/0.1.0 (darwin/arm64)", name: "CLI on lain")

      {:ok, _anon, %{"jti" => anon_jti}} = CliSession.issue(user)

      assert [anon, new, old] = CliSession.list(user)

      assert %CliSession{jti: ^anon_jti, client: nil, name: nil, last_used_at: nil} = anon
      assert %CliSession{jti: ^new_jti, name: "CLI on lain"} = new
      assert new.client == "prompton-cli/0.1.0 (darwin/arm64)"
      assert %DateTime{} = new.created_at
      assert %CliSession{jti: ^old_jti, name: "CLI on box"} = old
    end

    test "list is per user and excludes revoked sessions" do
      user = user_fixture()
      other = user_fixture()
      {:ok, mine, %{"jti" => my_jti}} = CliSession.issue(user, name: "mine")
      {:ok, _theirs, _} = CliSession.issue(other, name: "theirs")

      assert [%CliSession{jti: ^my_jti}] = CliSession.list(user)

      assert :ok = CliSession.revoke(mine)
      assert CliSession.list(user) == []
    end

    test "authenticate returns the session; touch records last use at most every 5 minutes" do
      user = user_fixture()
      {:ok, token, %{"jti" => jti}} = CliSession.issue(user, name: "CLI on lain")

      assert {:ok, %User{}, %CliSession{jti: ^jti, name: "CLI on lain", last_used_at: nil} = s} =
               CliSession.authenticate(token)

      assert :ok = CliSession.touch(s)
      assert [%CliSession{last_used_at: %DateTime{} = first}] = CliSession.list(user)
      assert DateTime.diff(DateTime.utc_now(), first, :second) < 5

      # Just touched, so it is not touched again; the timestamp stays the same.
      {:ok, _user, fresh} = CliSession.authenticate(token)
      assert :ok = CliSession.touch(fresh)
      assert [%CliSession{last_used_at: ^first, name: "CLI on lain"}] = CliSession.list(user)

      # Once stale, it is touched again.
      stale = %{
        fresh
        | last_used_at: DateTime.add(first, -CliSession.touch_after_seconds(), :second)
      }

      assert :ok = CliSession.touch(stale)
      assert [%CliSession{last_used_at: later, name: "CLI on lain"}] = CliSession.list(user)
      assert DateTime.compare(later, first) in [:gt, :eq]
    end

    test "revoke_jti signs out one device of this user only" do
      user = user_fixture()
      other = user_fixture()
      {:ok, laptop, %{"jti" => laptop_jti}} = CliSession.issue(user, name: "laptop")
      {:ok, desktop, _} = CliSession.issue(user, name: "desktop")
      {:ok, theirs, %{"jti" => their_jti}} = CliSession.issue(other, name: "theirs")

      assert :ok = CliSession.revoke_jti(user, laptop_jti)
      assert :error = CliSession.verify(laptop)
      assert {:ok, _} = CliSession.verify(desktop)

      # Someone else's session is neither visible nor revocable.
      assert {:error, :not_found} = CliSession.revoke_jti(user, their_jti)
      assert {:ok, _} = CliSession.verify(theirs)

      # An already revoked one is also not_found.
      assert {:error, :not_found} = CliSession.revoke_jti(user, laptop_jti)
      assert {:error, :not_found} = CliSession.revoke_jti(user, "no-such-jti")
    end
  end
end
