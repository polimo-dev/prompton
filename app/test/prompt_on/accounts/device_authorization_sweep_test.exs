defmodule PromptOn.Accounts.DeviceAuthorizationSweepTest do
  @moduledoc """
  `DeviceAuthorization.:sweep_expired`: expired requests disappear regardless of state, live
  requests stay, and the CLI token of a request that was **approved but never collected** is
  revoked before deletion.
  """
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  require Ash.Query

  alias PromptOn.Accounts
  alias PromptOn.Accounts.CliSession
  alias PromptOn.Accounts.DeviceAuthorization

  @client "prompton-cli/0.1.0 (darwin/arm64)"

  defp start!(name \\ "CLI on lain") do
    {:ok, request} =
      Accounts.start_device_authorization(%{client: @client, key_name: name},
        actor: system_actor()
      )

    request
  end

  # Expiry is decided by the clock; only the test pushes the column into the past.
  defp expire!(request) do
    at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_naive()

    PromptOn.Repo.query!("UPDATE device_authorizations SET expires_at = $1 WHERE id = $2", [
      at,
      Ecto.UUID.dump!(request.id)
    ])

    :ok
  end

  defp approve!(request, user) do
    {:ok, token, _claims} = CliSession.issue(user, client: @client, name: request.key_name)

    {:ok, approved} =
      Accounts.approve_device_authorization(request, %{user_id: user.id, token: token},
        actor: user
      )

    {approved, token}
  end

  defp exists?(request) do
    DeviceAuthorization
    |> Ash.Query.filter(id == ^request.id)
    |> Ash.exists?(actor: system_actor())
  end

  defp sweep! do
    {:ok, result} = Accounts.sweep_expired_device_authorizations(actor: system_actor())
    result
  end

  test "expired requests go away in every state; live ones stay" do
    user = user_fixture()

    pending = start!()
    {:ok, denied} = Accounts.deny_device_authorization(start!(), %{}, actor: user)
    {approved, _token} = approve!(start!(), user)
    {:ok, consumed} = Accounts.consume_device_authorization(approved, actor: system_actor())
    live = start!()
    {live_approved, live_token} = approve!(start!(), user)

    Enum.each([pending, denied, consumed], &expire!/1)

    assert %{deleted: 3, revoked: 0} = sweep!()

    refute exists?(pending)
    refute exists?(denied)
    refute exists?(consumed)
    assert exists?(live)
    assert exists?(live_approved)
    assert {:ok, _user} = CliSession.verify(live_token)

    # The second round has nothing to do.
    assert %{deleted: 0, revoked: 0} = sweep!()
  end

  test "an approved request nobody collected has its CLI token revoked before deletion" do
    user = user_fixture()
    {approved, token} = approve!(start!("CLI on lost-laptop"), user)
    assert {:ok, _user} = CliSession.verify(token)
    assert [%CliSession{name: "CLI on lost-laptop"}] = CliSession.list(user)

    expire!(approved)

    assert %{deleted: 1, revoked: 1} = sweep!()

    refute exists?(approved)
    assert :error = CliSession.verify(token)
    assert CliSession.list(user) == []
  end

  # An approved row that cannot be decrypted (e.g. after a vault key rotation) = a token that
  # cannot be revoked. The row is kept (once deleted it can never be touched again), but **the
  # expired rows behind it must keep being swept**; batch size 1 creates the "blocked head" case.
  test "a row whose token cannot be revoked is kept without blocking the rows behind it" do
    user = user_fixture()
    {stuck, token} = approve!(start!("CLI on stuck"), user)
    expire!(stuck)
    # A slightly less old expiry so that it comes behind.
    behind = start!()
    expire!(behind)

    PromptOn.Repo.query!("UPDATE device_authorizations SET encrypted_token = $1 WHERE id = $2", [
      "not-a-ciphertext",
      Ecto.UUID.dump!(stuck.id)
    ])

    assert {:ok, %{deleted: 1, revoked: 0, kept: 1}} =
             Accounts.sweep_expired_device_authorizations(%{batch_size: 1, max_batches: 10},
               actor: system_actor()
             )

    assert exists?(stuck)
    refute exists?(behind)

    # The token that could not be revoked is still alive; a person can revoke it from the account
    # screen.
    assert {:ok, _user} = CliSession.verify(token)
  end

  test "the sweeper is scheduled every 15 minutes on the maintenance queue" do
    [schedule] = AshOban.Info.oban_scheduled_actions(DeviceAuthorization)

    assert schedule.action == :sweep_expired
    assert schedule.cron == "*/15 * * * *"
    assert schedule.queue == :maintenance
    assert schedule.worker == PromptOn.Accounts.DeviceAuthorization.Workers.SweepExpired
  end

  test "only the system actor may sweep" do
    user = user_fixture()

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.sweep_expired_device_authorizations(actor: user)
  end
end
