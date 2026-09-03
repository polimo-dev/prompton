defmodule PromptOnWeb.SignInLoggingTest do
  @moduledoc """
  The sign-in code **never lands in the logs**: the request parameter `code` is masked by
  `config :phoenix, :filter_parameters` (the `Phoenix.Logger` debug parameter dump), and our own
  code prints the code nowhere.

  The suite's logger level is `:warning`, so the parameter dump (debug) never appears in the first
  place; only here the level is lowered to `:debug` to capture the whole flow. Logger configuration
  is VM-global, hence `async: false`.
  """
  use PromptOnWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PromptOn.Fixtures

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  test "the whole request → verify round trip never logs the code", %{conn: conn} do
    email = Fixtures.unique_email()
    parent = self()

    log =
      capture_log(fn ->
        conn = post(conn, ~p"/sign-in", %{"email" => email})
        assert_receive {:email, %Swoosh.Email{text_body: text}}, 500
        [_, code] = Regex.run(~r/^(\d{6})$/m, text)

        # One wrong try + one right try; both are paths where the debug log dumps the parameters.
        # (The wrong code is random six digits too; a value like `000000` could collide by chance
        # with other digits in the log.)
        wrong = Stream.repeatedly(&random_code/0) |> Enum.find(&(&1 != code))
        assert html_response(post(conn, ~p"/sign-in/verify", %{"code" => wrong}), 200)
        assert redirected_to(post(conn, ~p"/sign-in/verify", %{"code" => code})) == "/personal"

        send(parent, {:code, code, wrong})
      end)

    assert_receive {:code, code, wrong}

    # The parameter dump happened (`[FILTERED]` is where `code` was masked), and the raw code is
    # nowhere.
    assert log =~ ~s("code" => "[FILTERED]")
    refute log =~ code
    refute log =~ wrong
  end

  defp random_code, do: 100_000..999_999 |> Enum.random() |> Integer.to_string()
end
