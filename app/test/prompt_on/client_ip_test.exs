defmodule PromptOn.ClientIpTest do
  @moduledoc """
  `PromptOn.ClientIp` follows the same rule as the endpoint's `RemoteIp`: the last public IP in the
  `x-forwarded-for` chain after skipping private and loopback hops, or the peer when there is none.
  """
  use ExUnit.Case, async: true

  alias PromptOn.ClientIp

  test "takes the client from x-forwarded-for behind a private-range gateway" do
    headers = [{"x-forwarded-for", "203.0.113.9, 10.0.0.5"}]
    assert ClientIp.resolve(headers, {10, 0, 0, 1}) == "203.0.113.9"
  end

  test "falls back to the peer when there is no usable forwarded chain" do
    assert ClientIp.resolve([], {198, 51, 100, 7}) == "198.51.100.7"
    assert ClientIp.resolve([{"x-forwarded-for", "10.1.1.1"}], "198.51.100.8") == "198.51.100.8"
  end

  test "ignores headers other than x-forwarded-for" do
    headers = [{"x-client-ip", "8.8.8.8"}, {"forwarded", "for=9.9.9.9"}]
    assert ClientIp.resolve(headers, {127, 0, 0, 1}) == "127.0.0.1"
  end

  test "nil when nothing is known" do
    assert ClientIp.resolve([], nil) == nil
    assert ClientIp.resolve([], "not an ip") == nil
  end

  test "from_conn/1 reads the request headers and the peer the same way" do
    conn =
      Plug.Test.conn(:post, "/sign-in")
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.9, 10.0.0.5")

    assert ClientIp.from_conn(%{conn | remote_ip: {10, 0, 0, 1}}) == "203.0.113.9"
    assert ClientIp.from_conn(Plug.Test.conn(:post, "/sign-in")) == "127.0.0.1"
  end
end
