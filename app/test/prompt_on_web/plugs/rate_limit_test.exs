defmodule PromptOnWeb.Plugs.RateLimitTest do
  @moduledoc """
  `PromptOnWeb.Plugs.RateLimit` — a fixed window per IP; over the limit it is 429 + `retry-after`.

  The plug unit tests use a different bucket name per test so they never mix. The router wiring
  tests briefly tighten `config`, hence `async: false`.
  """
  use PromptOnWeb.ConnCase, async: false

  alias PromptOnWeb.Plugs.RateLimit

  defp from(ip, bucket, limit) do
    opts = RateLimit.init(bucket: bucket, limit: limit, scale: :timer.minutes(10))

    build_conn(:post, "/api/v1/device/code")
    |> Map.put(:remote_ip, ip)
    |> RateLimit.call(opts)
  end

  test "allows up to the limit per IP, then answers 429 with retry-after" do
    bucket = :"t_#{System.unique_integer([:positive])}"

    for _ <- 1..3 do
      conn = from({203, 0, 113, 1}, bucket, 3)
      refute conn.halted
    end

    denied = from({203, 0, 113, 1}, bucket, 3)
    assert denied.halted
    assert denied.status == 429
    assert [retry_after] = Plug.Conn.get_resp_header(denied, "retry-after")
    assert String.to_integer(retry_after) >= 1

    body = Jason.decode!(denied.resp_body)
    assert body["error"]["code"] == "rate_limited"
    assert is_integer(body["error"]["details"]["retry_after"])

    # A different IP uses its own counter.
    refute from({203, 0, 113, 2}, bucket, 3).halted
  end

  test "buckets are independent" do
    a = :"a_#{System.unique_integer([:positive])}"
    b = :"b_#{System.unique_integer([:positive])}"

    assert from({203, 0, 113, 9}, a, 1).halted == false
    assert from({203, 0, 113, 9}, a, 1).halted == true
    assert from({203, 0, 113, 9}, b, 1).halted == false
  end

  describe "wired into the device login routes" do
    setup do
      previous = Application.get_env(:prompton, RateLimit)

      Application.put_env(:prompton, RateLimit,
        device_code: [limit: 2, scale: :timer.minutes(10)]
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:prompton, RateLimit, previous),
          else: Application.delete_env(:prompton, RateLimit)
      end)

      :ok
    end

    # Behind the gateway the real client IP comes from `x-forwarded-for` (`RemoteIp`, in the
    # endpoint). Using a different IP per test keeps the counter apart from the suite's other
    # requests.
    defp request_code(ip, extra_headers \\ []) do
      Enum.reduce(extra_headers, build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-forwarded-for", ip)
      |> post(~p"/api/v1/device/code", Jason.encode!(%{client: "prompton-cli/test"}))
    end

    test "POST /api/v1/device/code is limited per client IP" do
      ip = "198.51.100.#{Enum.random(1..250)}"

      assert request_code(ip).status == 201
      assert request_code(ip).status == 201

      denied = request_code(ip)
      assert denied.status == 429
      assert json_response(denied, 429)["error"]["code"] == "rate_limited"
      assert [_] = Plug.Conn.get_resp_header(denied, "retry-after")

      # The neighboring IP is still open.
      assert request_code("198.51.100.251").status == 201
    end

    # RemoteIp trusts headers, not the peer. Traefik overwrites `x-forwarded-for` but leaves
    # `x-client-ip` and `forwarded` alone, so reading those two would let a client pick a fresh
    # bucket per request or exhaust someone else's — the endpoint reads only `x-forwarded-for`.
    test "client-controlled x-client-ip / forwarded headers cannot pick the bucket" do
      ip = "203.0.113.#{Enum.random(1..250)}"

      assert request_code(ip, [{"x-client-ip", "8.8.8.8"}]).status == 201
      assert request_code(ip, [{"forwarded", "for=9.9.9.9"}]).status == 201

      assert request_code(ip, [{"x-client-ip", "1.1.1.1"}, {"x-real-ip", "2.2.2.2"}]).status ==
               429
    end
  end
end
