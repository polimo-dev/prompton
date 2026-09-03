defmodule PromptOn.Accounts.SignInCodeTest do
  @moduledoc """
  `PromptOn.Accounts.SignInCode`: issuance (only the hash is stored), attempt counting (5), single
  use, 5 minutes, a new request deletes the previous code, the sweeper, and only the system actor
  touches it.
  """
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  require Ash.Query

  alias PromptOn.Accounts
  alias PromptOn.Accounts.SignInCode

  defp request!(email, attrs \\ %{}) do
    {:ok, record} =
      Accounts.request_sign_in_code(Map.merge(%{email: email}, attrs), actor: system_actor())

    {record, Ash.Resource.get_metadata(record, :code)}
  end

  defp attempt(email, code),
    do: Accounts.attempt_sign_in_code(%{email: email, code: code}, actor: system_actor())

  defp wrong(code), do: if(code == "000000", do: "000001", else: "000000")

  defp rows(email) do
    SignInCode
    |> Ash.Query.filter(email == ^email)
    |> Ash.read!(actor: system_actor())
  end

  # Expiry is decided by the clock; only the test pushes the column into the past.
  defp expire!(record) do
    at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_naive()

    PromptOn.Repo.query!("UPDATE sign_in_codes SET expires_at = $1 WHERE id = $2", [
      at,
      Ecto.UUID.dump!(record.id)
    ])

    :ok
  end

  describe ":request" do
    test "returns the code only as metadata and stores a salted hash, 5 minutes, 0 attempts" do
      email = unique_email()
      {record, code} = request!(email, %{requested_ip: "203.0.113.7"})

      assert String.match?(code, ~r/^[0-9]{6}$/)
      refute Map.has_key?(record, :code)
      refute record.code_hash =~ code
      assert record.code_hash == SignInCode.hash(record.id, code)
      assert record.attempts == 0
      assert is_nil(record.consumed_at)
      assert record.requested_ip == "203.0.113.7"
      refute SignInCode.expired?(record)

      assert_in_delta DateTime.diff(record.expires_at, DateTime.utc_now(), :second),
                      SignInCode.ttl_seconds(),
                      5
    end

    test "trims the address and stores it case-insensitively" do
      email = unique_email()
      {record, code} = request!("  #{String.upcase(email)}  ")

      assert Ash.CiString.value(record.email) == String.upcase(email)
      assert {:ok, consumed} = attempt(email, code)
      assert consumed.id == record.id
    end

    test "a new request removes the previous codes for that address" do
      email = unique_email()
      {first, first_code} = request!(email)
      {second, second_code} = request!(email)

      assert [%{id: only}] = rows(email)
      assert only == second.id
      refute first.id == second.id

      assert {:error, _} = attempt(email, first_code)
      assert {:ok, _} = attempt(email, second_code)
    end

    test "codes are different every time" do
      codes = for _ <- 1..20, do: SignInCode.generate_code()
      assert Enum.all?(codes, &String.match?(&1, ~r/^[0-9]{6}$/))
      assert length(Enum.uniq(codes)) > 1
    end
  end

  describe ":attempt" do
    test "the right code consumes the row; it cannot be used twice" do
      email = unique_email()
      {record, code} = request!(email)

      assert {:ok, consumed} = attempt(email, code)
      assert consumed.id == record.id
      assert consumed.attempts == 1
      assert %DateTime{} = consumed.consumed_at

      assert {:error, %Ash.Error.Invalid{}} = attempt(email, code)
    end

    test "wrong tries are counted and persisted; the fifth wrong try kills the code" do
      email = unique_email()
      {record, code} = request!(email)

      for n <- 1..5 do
        assert {:error, %Ash.Error.Invalid{}} = attempt(email, wrong(code))
        assert [%{attempts: ^n, consumed_at: nil}] = rows(email)
      end

      # Even a correct sixth attempt hits a dead code.
      assert {:error, %Ash.Error.Invalid{}} = attempt(email, code)
      assert [%{id: id, attempts: 5, consumed_at: nil}] = rows(email)
      assert id == record.id
    end

    test "four wrong tries then the right code still works" do
      email = unique_email()
      {_record, code} = request!(email)

      for _ <- 1..4, do: assert({:error, _} = attempt(email, wrong(code)))
      assert {:ok, %{attempts: 5}} = attempt(email, code)
    end

    test "an expired code fails even when right" do
      email = unique_email()
      {record, code} = request!(email)
      expire!(record)

      assert {:error, %Ash.Error.Invalid{}} = attempt(email, code)
    end

    test "an address without a code fails the same way" do
      assert {:error, %Ash.Error.Invalid{}} = attempt(unique_email(), "123456")
    end

    test "the address is matched case-insensitively" do
      email = unique_email()
      {_record, code} = request!(email)

      assert {:ok, _} = attempt(String.upcase(email), code)
    end
  end

  describe "normalize_code/1" do
    test "strips spaces and dashes and insists on exactly six digits" do
      assert {:ok, "123456"} = SignInCode.normalize_code("123456")
      assert {:ok, "123456"} = SignInCode.normalize_code(" 123 456 ")
      assert {:ok, "123456"} = SignInCode.normalize_code("123-456")
      assert :error = SignInCode.normalize_code("12345")
      assert :error = SignInCode.normalize_code("1234567")
      assert :error = SignInCode.normalize_code("12345a")
      assert :error = SignInCode.normalize_code("")
      assert :error = SignInCode.normalize_code(nil)
    end
  end

  describe ":sweep_expired" do
    test "deletes expired rows (consumed or not) and keeps live ones" do
      live_email = unique_email()
      {_live, _} = request!(live_email)

      expired_email = unique_email()
      {expired, _} = request!(expired_email)
      expire!(expired)

      consumed_email = unique_email()
      {consumed, code} = request!(consumed_email)
      assert {:ok, _} = attempt(consumed_email, code)
      expire!(consumed)

      assert {:ok, %{deleted: 2}} =
               Accounts.sweep_expired_sign_in_codes(actor: system_actor())

      assert [_] = rows(live_email)
      assert [] = rows(expired_email)
      assert [] = rows(consumed_email)

      # The second round has nothing to do.
      assert {:ok, %{deleted: 0}} = Accounts.sweep_expired_sign_in_codes(actor: system_actor())
    end

    test "sweeps in batches" do
      emails = for _ <- 1..3, do: unique_email()

      for email <- emails do
        {record, _} = request!(email)
        expire!(record)
      end

      assert {:ok, %{deleted: 3}} =
               Accounts.sweep_expired_sign_in_codes(%{batch_size: 1, max_batches: 10},
                 actor: system_actor()
               )

      for email <- emails, do: assert([] = rows(email))
    end

    test "is scheduled every 15 minutes on the maintenance queue" do
      [schedule] = AshOban.Info.oban_scheduled_actions(SignInCode)

      assert schedule.action == :sweep_expired
      assert schedule.cron == "*/15 * * * *"
      assert schedule.queue == :maintenance
      assert schedule.worker == PromptOn.Accounts.SignInCode.Workers.SweepExpired
    end
  end

  describe "policies" do
    test "only the system actor may issue, attempt, read or sweep" do
      user = user_fixture()
      email = unique_email()
      {_record, code} = request!(email)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.request_sign_in_code(%{email: unique_email()}, actor: user)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.attempt_sign_in_code(%{email: email, code: code}, actor: user)

      # Reads are quietly empty (`no_filter_static_forbidden_reads?: false`); the row does exist.
      assert [_] = rows(email)
      assert {:ok, []} = Ash.read(SignInCode, actor: user)
      assert {:ok, []} = Ash.read(SignInCode)
      assert {:error, %Ash.Error.Forbidden{}} = Accounts.sweep_expired_sign_in_codes(actor: user)
    end
  end
end
