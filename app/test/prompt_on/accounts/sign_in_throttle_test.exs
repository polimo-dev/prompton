defmodule PromptOn.Accounts.SignInThrottleTest do
  @moduledoc """
  `PromptOn.Accounts.SignInThrottle`: the email and IP axes for requests and the IP axis for
  verification, fixed-window counters. Hammer's ETS is VM-global, so each key uses a unique
  address/IP (`config/test.exs` lifts the IP-axis limits, so the IP axis is tightened via options).
  """
  use ExUnit.Case, async: true

  alias PromptOn.Accounts.SignInThrottle

  defp email, do: "throttle-#{System.unique_integer([:positive])}@example.com"
  defp ip, do: "203.0.113.#{:rand.uniform(254)}-#{System.unique_integer([:positive])}"

  test "allows three requests per address in the window, then denies" do
    address = email()

    assert SignInThrottle.allow_request?(address, nil)
    assert SignInThrottle.allow_request?(address, nil)
    assert SignInThrottle.allow_request?(address, nil)
    refute SignInThrottle.allow_request?(address, nil)
  end

  test "the address is normalized — case and whitespace do not open a new bucket" do
    address = email()

    assert SignInThrottle.allow_request?(address, nil)
    assert SignInThrottle.allow_request?(String.upcase(address), nil)
    assert SignInThrottle.allow_request?("  #{address} ", nil)
    refute SignInThrottle.allow_request?(address, nil)
  end

  test "the request IP axis denies across different addresses" do
    client = ip()
    opts = [ip: [limit: 2]]

    assert SignInThrottle.allow_request?(email(), client, opts)
    assert SignInThrottle.allow_request?(email(), client, opts)
    refute SignInThrottle.allow_request?(email(), client, opts)

    # A different IP is unaffected.
    assert SignInThrottle.allow_request?(email(), ip(), opts)
  end

  test "a nil IP skips the IP axes" do
    assert SignInThrottle.allow_request?(email(), nil, ip: [limit: 1])
    assert SignInThrottle.allow_request?(email(), nil, ip: [limit: 1])
    assert SignInThrottle.allow_verify?(nil, verify_ip: [limit: 1])
    assert SignInThrottle.allow_verify?(nil, verify_ip: [limit: 1])
  end

  test "both request counters are hit on every attempt" do
    client = ip()
    address = email()
    opts = [email: [limit: 1], ip: [limit: 5]]

    assert SignInThrottle.allow_request?(address, client, opts)

    # Even when blocked on the email axis, the IP axis counted: after four other addresses from the
    # same IP, the IP axis blocks from the fifth on.
    refute SignInThrottle.allow_request?(address, client, opts)
    assert SignInThrottle.allow_request?(email(), client, opts)
    assert SignInThrottle.allow_request?(email(), client, opts)
    assert SignInThrottle.allow_request?(email(), client, opts)
    refute SignInThrottle.allow_request?(email(), client, opts)
  end

  test "verification has its own per-IP bucket, separate from requests" do
    client = ip()
    opts = [ip: [limit: 1], verify_ip: [limit: 2]]

    assert SignInThrottle.allow_request?(email(), client, opts)
    refute SignInThrottle.allow_request?(email(), client, opts)

    # Even with the request axis closed, the verify axis counts against its own limit.
    assert SignInThrottle.allow_verify?(client, opts)
    assert SignInThrottle.allow_verify?(client, opts)
    refute SignInThrottle.allow_verify?(client, opts)

    assert SignInThrottle.allow_verify?(ip(), opts)
  end
end
