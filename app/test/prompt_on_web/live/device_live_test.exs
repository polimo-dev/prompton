defmodule PromptOnWeb.DeviceLiveTest do
  @moduledoc """
  `/device`: the CLI device approval screen. A person does exactly one thing here, so the tests
  cover that one thing: check the code and Approve or Deny. And **an anonymous visitor does not
  lose their way back**.
  """
  use PromptOnWeb.ConnCase, async: true

  import PromptOn.Fixtures
  import Phoenix.LiveViewTest

  alias PromptOn.Accounts
  alias PromptOn.Accounts.CliSession

  doctest PromptOnWeb.DeviceLive, import: true

  setup :register_and_log_in_user

  defp start_request(attrs \\ %{}) do
    {:ok, request} =
      Accounts.start_device_authorization(
        Map.merge(%{client: "prompton-cli/0.1.0 (darwin/arm64)", key_name: "CLI on lain"}, attrs),
        actor: system_actor()
      )

    {request, Ash.Resource.get_metadata(request, :device_code)}
  end

  defp reload(request) do
    {:ok, found} =
      Accounts.device_authorization_by_device_code(
        Ash.Resource.get_metadata(request, :device_code),
        actor: system_actor()
      )

    found
  end

  describe "sign-in" do
    test "an anonymous visitor is sent to sign-in and comes back to the same code" do
      conn =
        build_conn() |> Phoenix.ConnTest.init_test_session(%{}) |> get(~p"/device?code=ABCD-EFGH")

      assert redirected_to(conn) == "/sign-in"
      assert get_session(conn, :return_to) == "/device?code=ABCD-EFGH"
    end
  end

  describe "the code" do
    test "with no code the screen asks for one", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/device")

      assert html =~ "Enter the code"
      assert html =~ "device-code-form"
    end

    test "a typed code navigates to it, dash and case insensitive", %{conn: conn} do
      {request, _device_code} = start_request()
      {:ok, live, _html} = live(conn, ~p"/device")

      typed = request.user_code |> String.downcase() |> String.replace("-", "")

      live |> form("#device-code-form", device: %{code: typed}) |> render_submit()

      assert_patch(live, ~p"/device?code=#{request.user_code}")
      assert render(live) =~ "Connect this device?"
    end

    test "a code we do not know says so without confirming anything", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/device?code=ABCD-EFGH")

      assert html =~ "We don&#39;t know that code"
    end

    test "an expired request says it expired", %{conn: conn} do
      {request, _device_code} = start_request()

      {:ok, _expired} =
        request
        |> Ash.Changeset.for_update(:touch_poll, %{}, actor: system_actor())
        |> Ash.Changeset.force_change_attribute(
          :expires_at,
          DateTime.add(DateTime.utc_now(), -1, :second)
        )
        |> Ash.update()

      {:ok, _live, html} = live(conn, ~p"/device?code=#{request.user_code}")

      assert html =~ "That code has expired"
      refute html =~ "device-approve"
    end
  end

  describe "approve / deny" do
    test "approving mints this user's CLI token and hands it to the request", %{
      conn: conn,
      user: user
    } do
      {request, _device_code} = start_request()

      {:ok, live, html} = live(conn, ~p"/device?code=#{request.user_code}")

      assert html =~ "Connect this device?"
      assert html =~ "prompton-cli/0.1.0 (darwin/arm64)"
      assert html =~ "CLI on lain"
      assert html =~ request.user_code

      # There is no organization picker: what gets issued is this person's token, not an
      # organization credential.
      refute html =~ "organization-picker"

      html = live |> element("#device-approve") |> render_click()
      assert html =~ "Device connected"

      approved = reload(request)
      assert approved.status == :approved
      assert approved.user_id == user.id

      token = Ash.load!(approved, [:token], actor: system_actor()).token
      assert {:ok, holder} = CliSession.verify(token)

      # The approved session shows up in the device list under the name the CLI announced.
      assert [%CliSession{name: name, client: client}] = CliSession.list(user)
      assert name == approved.key_name
      assert client == approved.client
      assert holder.id == user.id
    end

    test "denying leaves no token behind", %{conn: conn} do
      {request, _device_code} = start_request()

      {:ok, live, _html} = live(conn, ~p"/device?code=#{request.user_code}")

      html = live |> element("#device-deny") |> render_click()
      assert html =~ "Access denied"

      denied = reload(request)
      assert denied.status == :denied
      assert Ash.load!(denied, [:token], actor: system_actor()).token == nil
    end

    test "an already-approved request just says it is connected", %{conn: conn, user: user} do
      {request, _device_code} = start_request()
      {:ok, token, _claims} = CliSession.issue(user)

      {:ok, _approved} =
        Accounts.approve_device_authorization(request, %{user_id: user.id, token: token},
          actor: user
        )

      {:ok, _live, html} = live(conn, ~p"/device?code=#{request.user_code}")

      assert html =~ "Device connected"
      refute html =~ "device-approve"
    end
  end
end
