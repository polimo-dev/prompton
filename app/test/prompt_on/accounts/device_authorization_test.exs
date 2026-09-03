defmodule PromptOn.Accounts.DeviceAuthorizationTest do
  @moduledoc """
  Device authorization resource: the code pair, approve/deny, **the token exactly once**, and
  policies.
  """
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Accounts
  alias PromptOn.Accounts.CliSession
  alias PromptOn.Accounts.DeviceAuthorization

  doctest PromptOn.Accounts.DeviceAuthorization

  defp start(attrs \\ %{}) do
    {:ok, request} =
      Accounts.start_device_authorization(
        Map.merge(%{client: "prompton-cli/0.1.0 (darwin/arm64)", key_name: "CLI on lain"}, attrs),
        actor: system_actor()
      )

    {request, Ash.Resource.get_metadata(request, :device_code)}
  end

  describe ":start" do
    test "mints a hashed device code, a readable user code and a 15 minute deadline" do
      {request, device_code} = start()

      assert byte_size(device_code) >= 43
      assert request.device_code_hash == DeviceAuthorization.hash(device_code)
      refute request.device_code_hash == device_code

      assert String.match?(request.user_code, ~r/^[A-Z0-9]{4}-[A-Z0-9]{4}$/)
      assert request.status == :pending
      assert request.client == "prompton-cli/0.1.0 (darwin/arm64)"

      seconds = DateTime.diff(request.expires_at, DateTime.utc_now())
      assert_in_delta seconds, DeviceAuthorization.ttl_seconds(), 5
    end

    test "the user code alphabet has no look-alike characters" do
      refute String.contains?(DeviceAuthorization.alphabet(), "O")
      refute String.contains?(DeviceAuthorization.alphabet(), "0")
      refute String.contains?(DeviceAuthorization.alphabet(), "I")
      refute String.contains?(DeviceAuthorization.alphabet(), "1")
    end

    test "codes are unique per request" do
      {a, a_code} = start()
      {b, b_code} = start()

      refute a.user_code == b.user_code
      refute a_code == b_code
    end
  end

  describe "lookups" do
    test ":by_device_code takes the raw code, not the hash" do
      {request, device_code} = start()

      assert {:ok, found} =
               Accounts.device_authorization_by_device_code(device_code, actor: system_actor())

      assert found.id == request.id

      assert {:ok, nil} =
               Accounts.device_authorization_by_device_code(request.device_code_hash,
                 actor: system_actor()
               )
    end

    test ":by_user_code is how the browser screen finds it" do
      {request, _device_code} = start()
      user = user_fixture()

      assert {:ok, found} =
               Accounts.device_authorization_by_user_code(request.user_code, actor: user)

      assert found.id == request.id
    end
  end

  describe ":approve / :consume" do
    test "the token is stashed encrypted and handed over exactly once" do
      {request, device_code} = start()
      user = user_fixture()
      {:ok, token, _claims} = CliSession.issue(user)

      {:ok, approved} =
        Accounts.approve_device_authorization(request, %{user_id: user.id, token: token},
          actor: user
        )

      assert approved.status == :approved
      assert approved.user_id == user.id
      assert approved.decided_at

      # Only the ciphertext is stored; there is no plaintext column.
      assert %{rows: [[encrypted]]} =
               PromptOn.Repo.query!(
                 "SELECT encrypted_token FROM device_authorizations WHERE id = $1",
                 [
                   Ecto.UUID.dump!(approved.id)
                 ]
               )

      assert is_binary(encrypted)
      refute String.contains?(encrypted, token)

      loaded = Ash.load!(approved, [:token], actor: system_actor())
      assert loaded.token == token

      {:ok, consumed} = Accounts.consume_device_authorization(loaded, actor: system_actor())
      assert consumed.status == :consumed

      {:ok, again} =
        Accounts.device_authorization_by_device_code(device_code, actor: system_actor())

      assert Ash.load!(again, [:token], actor: system_actor()).token == nil
    end

    test ":deny records the refusal" do
      {request, _device_code} = start()
      user = user_fixture()

      {:ok, denied} = Accounts.deny_device_authorization(request, %{}, actor: user)

      assert denied.status == :denied
      assert denied.decided_at
      assert is_nil(denied.user_id)
    end
  end

  describe "policies" do
    # Read policies fold into a **filter**: rows you cannot see are an empty result, not an
    # exception (Ash default). Writes cannot do that, so the refusal comes back as an error.
    test "an anonymous caller finds nothing and cannot decide it" do
      {request, _device_code} = start()

      assert {:ok, nil} = Accounts.device_authorization_by_user_code(request.user_code, [])
      assert {:error, _error} = Accounts.deny_device_authorization(request, %{}, [])
    end

    test "a runtime API key cannot touch device authorizations" do
      {request, _device_code} = start()
      project = project_fixture()
      {api_key, _raw} = api_key_fixture(project)

      assert {:ok, nil} =
               Accounts.device_authorization_by_user_code(request.user_code, actor: api_key)

      assert {:error, _error} = Accounts.deny_device_authorization(request, %{}, actor: api_key)
    end

    test "there is no listing — a signed-in user only reaches a code they hold" do
      {request, _device_code} = start()

      assert {:ok, []} = Ash.read(DeviceAuthorization, actor: user_fixture())

      assert {:ok, %{id: id}} =
               Accounts.device_authorization_by_user_code(request.user_code,
                 actor: user_fixture()
               )

      assert id == request.id
    end
  end

  test "expired?/1 looks only at the clock" do
    {request, _device_code} = start()

    refute DeviceAuthorization.expired?(request)

    past = %{request | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}
    assert DeviceAuthorization.expired?(past)
  end
end
