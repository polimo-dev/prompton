defmodule PromptOn.Accounts.UserTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Accounts

  test "registering a user creates a personal organization with an owner membership" do
    user = user_fixture(%{email: "alice@example.com"})
    org = organization_for(user)

    # A personal organization has no slug; URLs resolve it via the reserved segment `/personal`.
    assert is_nil(org.slug)
    assert org.personal?
    assert org.name =~ "alice@example.com"

    {:ok, [membership]} = Accounts.list_memberships(actor: user)
    assert membership.role == :owner
    assert membership.organization_id == org.id
  end

  test "a user has no password — the column is nullable until it is dropped" do
    user = user_fixture()
    assert is_nil(user.hashed_password)
  end

  test "personal organizations never collide — no slug to collide on" do
    user1 = user_fixture(%{email: "bob@example.com"})
    user2 = user_fixture(%{email: "bob@other.com"})

    org1 = organization_for(user1)
    org2 = organization_for(user2)

    assert is_nil(org1.slug)
    assert is_nil(org2.slug)
    refute org1.id == org2.id
  end

  test "users can only read themselves; :register is not open to user actors" do
    alice = user_fixture()
    bob = user_fixture()

    assert {:ok, [only]} = Ash.read(Accounts.User, actor: alice)
    assert only.id == alice.id
    refute only.id == bob.id

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.register_user(%{email: unique_email()}, actor: alice)

    assert {:error, %Ash.Error.Forbidden{}} = Accounts.register_user(%{email: unique_email()})
  end

  test "the email is unique" do
    user_fixture(%{email: "dup@example.com"})

    assert {:error, %Ash.Error.Invalid{}} =
             Accounts.register_user(%{email: "DUP@example.com"}, actor: system_actor())
  end

  test "there is no ash_authentication strategy — sign-in is the emailed code, tokens stay on" do
    assert [] = AshAuthentication.Info.authentication_strategies(Accounts.User)
    assert AshAuthentication.Info.authentication_tokens_enabled?(Accounts.User)

    assert AshAuthentication.Info.authentication_tokens_require_token_presence_for_authentication?(
             Accounts.User
           )

    # `:register` is the only creation path and involves no person; there are no password or
    # magic-link actions.
    assert Ash.Resource.Info.action(Accounts.User, :register)
    refute Ash.Resource.Info.action(Accounts.User, :sign_in_with_password)
    refute Ash.Resource.Info.action(Accounts.User, :register_with_password)
    refute Ash.Resource.Info.action(Accounts.User, :change_password)
    refute Ash.Resource.Info.action(Accounts.User, :set_password)
    refute Ash.Resource.Info.action(Accounts.User, :request_magic_link)
    refute Ash.Resource.Info.action(Accounts.User, :sign_in_with_magic_link)
  end
end
