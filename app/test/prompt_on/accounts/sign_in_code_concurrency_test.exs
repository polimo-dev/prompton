defmodule PromptOn.Accounts.SignInCodeConcurrencyTest do
  @moduledoc """
  **Concurrency** of sign-in codes: the race of submitting the same code twice at once (double
  click, two tabs). `SignInCode.:attempt` locks the row `FOR UPDATE` and counts the attempt, so
  there must be **exactly one** sign-in.

  Inside a sandbox transaction the commit order (the moment a row lock is released) cannot be
  reproduced, so `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` is used to **actually commit**. That is
  why this is `async: false` and the rows it creates are deleted explicitly when each test ends.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PromptOn.Accounts
  alias PromptOn.Accounts.SignInCode
  alias PromptOn.Repo

  setup do
    email = "race-#{System.unique_integer([:positive])}@example.com"
    on_exit(fn -> cleanup(email) end)
    %{email: email}
  end

  test "the same code submitted twice at once is consumed exactly once", %{email: email} do
    code =
      unboxed(fn ->
        {:ok, record} = Accounts.request_sign_in_code(%{email: email}, actor: actor())
        Ash.Resource.get_metadata(record, :code)
      end)

    results = concurrently([fn -> attempt(email, code) end, fn -> attempt(email, code) end])

    assert [{:error, %Ash.Error.Invalid{}}, {:ok, %SignInCode{}}] =
             Enum.sort_by(results, &elem(&1, 0))

    # One row, consumed, and the attempt was counted once (the second saw the consumed row and
    # ended as "not found").
    assert [%{attempts: 1, consumed?: true}] = rows(email)
  end

  test "a wrong and a right try at once leave one consumed row with both tries counted", %{
    email: email
  } do
    code =
      unboxed(fn ->
        {:ok, record} = Accounts.request_sign_in_code(%{email: email}, actor: actor())
        Ash.Resource.get_metadata(record, :code)
      end)

    wrong = if code == "000000", do: "000001", else: "000000"

    results = concurrently([fn -> attempt(email, wrong) end, fn -> attempt(email, code) end])

    # Depending on the order: (wrong -> right) counts both, attempts 2; (right -> wrong) the wrong
    # one does not see the consumed row, so 1.
    assert [{:error, %Ash.Error.Invalid{}}, {:ok, %SignInCode{}}] =
             Enum.sort_by(results, &elem(&1, 0))

    assert [%{attempts: attempts, consumed?: true}] = rows(email)
    assert attempts in [1, 2]
  end

  test "concurrent wrong guesses are serialized by the row lock — the budget is exactly five", %{
    email: email
  } do
    code =
      unboxed(fn ->
        {:ok, record} = Accounts.request_sign_in_code(%{email: email}, actor: actor())
        Ash.Resource.get_metadata(record, :code)
      end)

    # Eight at once. Without the lock, several would read the same `attempts` and write the same
    # value (lost update), letting more than five attempts through. Under the lock each one counts
    # after seeing the previous commit, so it stops at exactly five.
    guesses = for _ <- 1..8, do: fn -> attempt(email, wrong_code(code)) end
    results = concurrently(guesses)

    assert Enum.all?(results, &match?({:error, %Ash.Error.Invalid{}}, &1))
    assert [%{attempts: 5, consumed?: false}] = rows(email)

    # The code is dead: even the right one fails, and nothing is counted any more.
    assert {:error, %Ash.Error.Invalid{}} = unboxed(fn -> attempt(email, code) end)
    assert [%{attempts: 5, consumed?: false}] = rows(email)
  end

  # ---------------------------------------------------------------------------

  defp actor, do: PromptOn.SystemActor.new()

  # Six digits different from the code, random each time (exposes a lock-free implementation
  # better than always submitting the same wrong value).
  defp wrong_code(code) do
    Stream.repeatedly(&SignInCode.generate_code/0) |> Enum.find(&(&1 != code))
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp attempt(email, code),
    do: Accounts.attempt_sign_in_code(%{email: email, code: code}, actor: actor())

  # Each function runs in its own process + its own DB connection (outside the sandbox).
  defp concurrently(funs) do
    funs
    |> Enum.map(&Task.async(fn -> unboxed(&1) end))
    |> Task.await_many(30_000)
  end

  defp rows(email) do
    unboxed(fn ->
      Repo.all(
        from(c in "sign_in_codes",
          where: c.email == ^email,
          select: %{attempts: c.attempts, consumed?: not is_nil(c.consumed_at)}
        )
      )
    end)
  end

  defp cleanup(email) do
    unboxed(fn -> Repo.delete_all(from(c in "sign_in_codes", where: c.email == ^email)) end)
  end
end
