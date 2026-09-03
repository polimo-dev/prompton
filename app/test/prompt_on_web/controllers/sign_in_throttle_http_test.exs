defmodule PromptOnWeb.SignInThrottleHttpTest do
  @moduledoc """
  The **per-IP** throttle on `/sign-in`: requests (10 per 10 minutes) and verifications (20 per 10
  minutes). `config/test.exs` leaves both IP axes open, so they are tightened briefly only here,
  hence `async: false`. The IP is resolved from `x-forwarded-for` by the endpoint's `RemoteIp`
  (`PromptOn.ClientIp.from_conn/1`).
  """
  use PromptOnWeb.ConnCase, async: false

  alias PromptOn.Accounts.SignInThrottle
  alias PromptOn.Fixtures

  setup do
    previous = Application.get_env(:prompton, SignInThrottle)

    Application.put_env(:prompton, SignInThrottle,
      ip: [limit: 2, scale: :timer.minutes(10)],
      verify_ip: [limit: 2, scale: :timer.minutes(10)]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:prompton, SignInThrottle, previous),
        else: Application.delete_env(:prompton, SignInThrottle)
    end)

    :ok
  end

  defp from_ip(conn, ip), do: put_req_header(conn, "x-forwarded-for", ip)

  defp request_code(conn, email), do: post(conn, ~p"/sign-in", %{"email" => email})
  defp verify(conn, code), do: post(conn, ~p"/sign-in/verify", %{"code" => code})

  defp code_in(%Swoosh.Email{text_body: text}) do
    assert [_, code] = Regex.run(~r/^(\d{6})$/m, text)
    code
  end

  defp wrong(code), do: if(code == "000000", do: "000001", else: "000000")

  test "requests from one IP are limited across addresses — same face, no third email" do
    ip = "198.51.100.#{Enum.random(1..250)}"

    for _ <- 1..3 do
      conn = build_conn() |> from_ip(ip) |> request_code(Fixtures.unique_email())
      assert redirected_to(conn) == "/sign-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "We emailed a 6-digit code"
    end

    for _ <- 1..2, do: assert_receive({:email, _}, 500)
    refute_receive {:email, _}, 200

    # The neighbouring IP is still open.
    build_conn() |> from_ip("198.51.100.251") |> request_code(Fixtures.unique_email())
    assert_receive {:email, _}, 500
  end

  test "client-controlled x-client-ip / forwarded headers cannot pick the bucket" do
    ip = "203.0.113.#{Enum.random(1..250)}"

    build_conn()
    |> from_ip(ip)
    |> put_req_header("x-client-ip", "8.8.8.8")
    |> request_code(Fixtures.unique_email())

    build_conn()
    |> from_ip(ip)
    |> put_req_header("forwarded", "for=9.9.9.9")
    |> request_code(Fixtures.unique_email())

    for _ <- 1..2, do: assert_receive({:email, _}, 500)

    build_conn()
    |> from_ip(ip)
    |> put_req_header("x-client-ip", "1.1.1.1")
    |> request_code(Fixtures.unique_email())

    refute_receive {:email, _}, 200
  end

  test "verification attempts from one IP are limited — the throttled try does not count against the code" do
    email = Fixtures.unique_email()
    ip = "192.0.2.#{Enum.random(1..250)}"

    conn = build_conn() |> from_ip(ip) |> request_code(email)
    assert_receive {:email, mail}, 500
    code = code_in(mail)

    # Two wrong tries close this IP; the third fails even with the right code.
    assert html_response(verify(conn, wrong(code)), 200) =~ "That code didn&#39;t work"
    assert html_response(verify(conn, wrong(code)), 200) =~ "That code didn&#39;t work"
    throttled = verify(conn, code)
    assert html_response(throttled, 200) =~ "That code didn&#39;t work"
    refute get_session(throttled, "user_token")

    # From another IP the same code works; the throttled try did not count against the code's 5
    # (only 2 were used).
    other = build_conn() |> init_test_session(%{sign_in_email: email}) |> from_ip("192.0.2.251")
    assert redirected_to(verify(other, code)) == "/personal"
  end
end
