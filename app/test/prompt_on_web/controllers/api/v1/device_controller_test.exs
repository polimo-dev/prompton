defmodule PromptOnWeb.API.V1.DeviceControllerTest do
  @moduledoc """
  `POST /api/v1/device/code` and `POST /api/v1/device/token`: the two steps of the CLI sign-in.

  The contract this file guards: codes are handed out without authentication, polling before
  approval is `authorization_pending`, after approval the token is handed out **exactly once**, and
  from then on it is `expired_token`.
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Accounts
  alias PromptOn.Accounts.CliSession

  @client "prompton-cli/0.1.0 (darwin/arm64)"

  defp json_conn do
    build_conn() |> put_req_header("content-type", "application/json")
  end

  defp post_json(path, body), do: post(json_conn(), path, Jason.encode!(body))

  defp request_code(attrs \\ %{}) do
    body =
      json_response(
        post_json(
          ~p"/api/v1/device/code",
          Map.merge(%{client: @client, name: "CLI on lain"}, attrs)
        ),
        201
      )

    body
  end

  defp poll(device_code, status),
    do: json_response(post_json(~p"/api/v1/device/token", %{device_code: device_code}), status)

  # The polling throttle (5 seconds) and the 15-minute expiry are decided by the **clock**. Domain
  # actions cannot move them into the past (that is the point), so only the test nudges the columns
  # directly.
  defp rewind_poll(user_code), do: shift(user_code, "last_polled_at", -60)
  defp expire(user_code), do: shift(user_code, "expires_at", -1)

  defp shift(user_code, column, seconds) do
    at = DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_naive()

    PromptOn.Repo.query!(
      "UPDATE device_authorizations SET #{column} = $1 WHERE user_code = $2",
      [at, user_code]
    )

    :ok
  end

  defp approve(user_code, user) do
    {:ok, request} = Accounts.device_authorization_by_user_code(user_code, actor: user)
    {:ok, token, _claims} = CliSession.issue(user)

    {:ok, _approved} =
      Accounts.approve_device_authorization(request, %{user_id: user.id, token: token},
        actor: user
      )

    token
  end

  describe "POST /device/code" do
    test "hands out both codes, the verification URL and the polling contract" do
      body = request_code()

      assert String.match?(body["user_code"], ~r/^[A-Z0-9]{4}-[A-Z0-9]{4}$/)
      assert byte_size(body["device_code"]) >= 43
      assert String.ends_with?(body["verification_uri"], "/device")

      assert body["verification_uri_complete"] ==
               body["verification_uri"] <> "?code=" <> body["user_code"]

      assert body["expires_in"] == 900
      assert body["interval"] == 5
    end

    test "client is required" do
      conn = post_json(~p"/api/v1/device/code", %{name: "no client"})

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
    end

    test "no authentication is needed — that is the point" do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer garbage")
        |> post(~p"/api/v1/device/code", Jason.encode!(%{client: @client}))

      assert json_response(conn, 201)["user_code"]
    end
  end

  describe "POST /device/token" do
    test "pending → approved → the token exactly once" do
      user = user_fixture()
      org = organization_for(user)
      code = request_code()

      assert %{"error" => %{"code" => "authorization_pending"}} =
               poll(code["device_code"], 400)

      token = approve(code["user_code"], user)
      :ok = rewind_poll(code["user_code"])

      body = poll(code["device_code"], 200)

      assert body["token"] == token
      assert body["user"] == %{"id" => user.id, "email" => to_string(user.email)}
      assert Enum.map(body["organizations"], & &1["id"]) == [org.id]

      # That token opens the management API right away.
      assert {:ok, _user} = CliSession.verify(body["token"])

      # A second poll hands out nothing.
      :ok = rewind_poll(code["user_code"])
      assert %{"error" => %{"code" => "expired_token"}} = poll(code["device_code"], 400)
    end

    test "denial is its own answer" do
      user = user_fixture()
      code = request_code()

      {:ok, request} = Accounts.device_authorization_by_user_code(code["user_code"], actor: user)
      {:ok, _denied} = Accounts.deny_device_authorization(request, %{}, actor: user)

      :ok = rewind_poll(code["user_code"])

      assert %{"error" => %{"code" => "access_denied"}} = poll(code["device_code"], 400)
    end

    test "polling faster than the interval gets slow_down" do
      code = request_code()

      assert %{"error" => %{"code" => "authorization_pending"}} = poll(code["device_code"], 400)
      assert %{"error" => %{"code" => "slow_down"}} = poll(code["device_code"], 400)

      # A client that waited gets a normal answer again.
      :ok = rewind_poll(code["user_code"])
      assert %{"error" => %{"code" => "authorization_pending"}} = poll(code["device_code"], 400)
    end

    test "an expired request is expired_token even when it was approved" do
      user = user_fixture()
      code = request_code()
      _token = approve(code["user_code"], user)

      :ok = expire(code["user_code"])
      :ok = rewind_poll(code["user_code"])

      assert %{"error" => %{"code" => "expired_token"}} = poll(code["device_code"], 400)
    end

    test "an unknown device code is expired_token, not a 404 that confirms it existed" do
      assert %{"error" => %{"code" => "expired_token"}} = poll("made-up-device-code", 400)
    end

    test "device_code is required" do
      conn = post_json(~p"/api/v1/device/token", %{})

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  test "POST /device/code rejects a name longer than 200 characters (unauthenticated write)" do
    body =
      json_response(
        post_json(~p"/api/v1/device/code", %{client: @client, name: String.duplicate("n", 201)}),
        400
      )

    assert body["error"]["code"] == "invalid_request"

    assert %{"user_code" => _} =
             json_response(
               post_json(~p"/api/v1/device/code", %{
                 client: @client,
                 name: String.duplicate("n", 200)
               }),
               201
             )
  end
end
