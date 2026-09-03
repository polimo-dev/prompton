defmodule PromptOnWeb.SignInControllerTest do
  @moduledoc """
  Email code sign-in: the whole flow of the only sign-in method (ADR 0008, revised), all over HTTP.

  Entering an address at `/sign-in` sends one email (Swoosh Test adapter → `{:email, …}` to this
  process) with a 6-digit code, and entering it in the code field of the same screen signs you in.
  The first sign-in is registration (user + personal organization); a code works once, for 5
  minutes and 5 tries; a new request kills the previous code; a throttled request shows the same
  face with no email; and someone who started at `/device?code=…` returns there after getting the
  code right.
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Accounts
  alias PromptOn.Accounts.SignIn.Email
  alias PromptOn.Fixtures

  # Requests a code (`POST /sign-in`). Returns the response conn (the session carries the pending
  # address).
  defp request_code(conn, email), do: post(conn, ~p"/sign-in", %{"email" => email})

  # The one email that just went out; fails when there is none.
  defp receive_email do
    assert_receive {:email, %Swoosh.Email{} = email}, 500
    email
  end

  defp refute_email, do: refute_receive({:email, _}, 200)

  # The code in the email body (the six digits are contiguous; copy-pasting must work as is).
  defp code_in(%Swoosh.Email{text_body: text, html_body: html}) do
    assert [_, code] = Regex.run(~r/^(\d{6})$/m, text)
    {left, right} = String.split_at(code, 3)
    assert html =~ "<span>#{left}</span><span style=\"margin-left:18px;\">#{right}</span>"
    code
  end

  defp verify(conn, code), do: post(conn, ~p"/sign-in/verify", %{"code" => code})

  # Request → email → code verification in one go. Returns `{conn, code}`.
  defp sign_in(conn, email) do
    conn = request_code(conn, email)
    code = code_in(receive_email())
    {verify(conn, code), code}
  end

  defp wrong(code), do: if(code == "000000", do: "000001", else: "000000")

  defp user_by_email(email) do
    {:ok, user} = Accounts.get_user_by_email(email, actor: Fixtures.system_actor())
    user
  end

  describe "GET /sign-in" do
    test "shows the email form — no password, no register link", %{conn: conn} do
      html = conn |> get(~p"/sign-in") |> html_response(200)

      assert html =~ "Sign in to PromptOn"
      assert html =~ ~s(id="sign-in-form")
      assert html =~ ~s(id="sign-in-email")
      assert html =~ ~s(id="sign-in-send")
      assert html =~ "Send code"
      refute html =~ ~r/register/i
      refute html =~ ~s(type="password")
      refute html =~ ~s(id="sign-in-code")
    end

    test "a signed-in visitor is sent to /personal", %{conn: conn} do
      conn = log_in_user(conn, Fixtures.user_fixture())

      assert redirected_to(get(conn, ~p"/sign-in")) == "/personal"

      assert redirected_to(post(conn, ~p"/sign-in", %{"email" => Fixtures.unique_email()})) ==
               "/personal"

      assert redirected_to(post(conn, ~p"/sign-in/verify", %{"code" => "123456"})) == "/personal"
      refute_email()
    end
  end

  describe "POST /sign-in (requesting a code)" do
    test "emails one 6-digit code with the agreed sender and subject, then shows the code form",
         %{
           conn: conn
         } do
      email = Fixtures.unique_email()

      conn = request_code(conn, email)

      assert redirected_to(conn) == "/sign-in"
      assert get_session(conn, :sign_in_email) == email

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "We emailed a 6-digit code to #{email}. It expires in 5 minutes."

      mail = receive_email()
      assert mail.to == [{"", email}]
      assert mail.from == {"PromptOn", "noreply@prompton.ai"}
      code = code_in(mail)
      assert String.length(code) == 6

      # The subject is fixed and the code is the first line of the body, so it reads straight off a
      # notification preview (subject + first line).
      assert mail.subject == Email.subject()
      assert mail.subject == "Your PromptOn sign-in code"
      assert String.starts_with?(mail.text_body, code <> "\n")
      assert mail.text_body =~ "It expires in 5 minutes."
      assert mail.text_body =~ "If you didn't request it, ignore this email."
      refute_email()

      # The same page turns into the code field.
      html = conn |> get(~p"/sign-in") |> html_response(200)
      assert html =~ "Enter your code"

      # Typing all six digits auto-submits; the input's marker and the script are both present.
      assert html =~ ~s(data-autosubmit="6")
      assert html =~ "requestSubmit()"
      assert html =~ ~s(id="sign-in-pending-email")
      assert html =~ email
      assert html =~ ~s(id="sign-in-code")
      assert html =~ ~s(inputmode="numeric")
      assert html =~ ~s(pattern="[0-9]{6}")
      assert html =~ ~s(maxlength="6")
      assert html =~ ~s(autocomplete="one-time-code")
      assert html =~ ~s(id="sign-in-verify")
      assert html =~ ~s(id="sign-in-resend")
      assert html =~ ~s(id="sign-in-reset")
      assert html =~ "Resend code"
      assert html =~ "Use a different email"
      assert html =~ "auth-flash-info"
      refute html =~ ~s(id="sign-in-form")
    end

    test "a known and an unknown address get the very same response", %{conn: conn} do
      known = Fixtures.user_fixture().email |> to_string()
      unknown = Fixtures.unique_email()

      a = request_code(conn, known)
      receive_email()
      b = request_code(build_conn(), unknown)
      receive_email()

      assert redirected_to(a) == redirected_to(b)

      assert String.replace(Phoenix.Flash.get(a.assigns.flash, :info), known, "X") ==
               String.replace(Phoenix.Flash.get(b.assigns.flash, :info), unknown, "X")

      # No user exists until the code is right.
      assert {:ok, nil} = Accounts.get_user_by_email(unknown, actor: Fixtures.system_actor())
    end

    test "something that is not an email is the only visible failure — inline, nothing sent", %{
      conn: conn
    } do
      conn = request_code(conn, "not an email")

      html = html_response(conn, 200)
      assert html =~ "Enter a valid email address."
      assert html =~ ~s(id="sign-in-form")
      assert html =~ ~s(value="not an email")
      refute get_session(conn, :sign_in_email)
      refute_email()
    end

    test "the address is trimmed", %{conn: conn} do
      email = Fixtures.unique_email()
      conn = request_code(conn, "  #{email}  ")

      assert get_session(conn, :sign_in_email) == email
      assert %{to: [{"", ^email}]} = receive_email()
    end

    test "a non-string email parameter is the inline error, not a crash", %{conn: conn} do
      for shape <- [%{"a" => "b"}, ["a@b.c", "x@y.z"], nil] do
        conn = post(conn, ~p"/sign-in", %{"email" => shape})

        assert html_response(conn, 200) =~ "Enter a valid email address."
        refute get_session(conn, :sign_in_email)
      end

      refute_email()
    end
  end

  describe "POST /sign-in/verify" do
    test "the code signs in; the first sign-in creates the user and the personal organization", %{
      conn: conn
    } do
      email = Fixtures.unique_email()
      {conn, _code} = sign_in(conn, email)

      assert redirected_to(conn) == "/personal"
      assert get_session(conn, "user_token")
      refute get_session(conn, :sign_in_email)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "You are now signed in"

      user = user_by_email(email)
      assert to_string(user.email) == email
      org = Fixtures.organization_for(user)
      assert org.personal?
      {:ok, [membership]} = Accounts.list_memberships(actor: user)
      assert membership.role == :owner

      # That session opens the screens that require sign-in.
      assert html_response(get(conn, ~p"/personal"), 200) =~ "org-home-screen"
      assert {:ok, _view, account} = live(conn, ~p"/account")
      assert account =~ email
    end

    test "an existing user signs in again without a second personal organization", %{conn: conn} do
      user = Fixtures.user_fixture()
      email = to_string(user.email)

      {conn, _code} = sign_in(conn, email)
      assert redirected_to(conn) == "/personal"

      assert user_by_email(email).id == user.id
      {:ok, memberships} = Accounts.list_memberships(actor: user)
      assert length(memberships) == 1
    end

    test "email case does not matter", %{conn: conn} do
      email = Fixtures.unique_email()
      {conn, _code} = sign_in(conn, String.upcase(email))

      assert redirected_to(conn) == "/personal"
      assert %{} = user_by_email(email)
    end

    test "a wrong code re-renders the code form with one sentence and nothing else", %{
      conn: conn
    } do
      email = Fixtures.unique_email()
      conn = request_code(conn, email)
      code = code_in(receive_email())

      failed = verify(conn, wrong(code))
      html = html_response(failed, 200)

      assert html =~ "That code didn&#39;t work. Check it or request a new one."
      assert html =~ ~s(id="sign-in-code-error")
      assert html =~ ~s(id="sign-in-code")
      assert html =~ email
      refute get_session(failed, "user_token")
      assert get_session(failed, :sign_in_email) == email

      # 3 tries are still left; the right code works.
      assert redirected_to(verify(conn, code)) == "/personal"
    end

    test "five wrong tries kill the code — the sixth with the right code fails", %{conn: conn} do
      email = Fixtures.unique_email()
      conn = request_code(conn, email)
      code = code_in(receive_email())

      for _ <- 1..5 do
        assert html_response(verify(conn, wrong(code)), 200) =~ "That code didn&#39;t work"
      end

      right = verify(conn, code)
      assert html_response(right, 200) =~ "That code didn&#39;t work"
      refute get_session(right, "user_token")
      assert {:ok, nil} = Accounts.get_user_by_email(email, actor: Fixtures.system_actor())
    end

    test "an expired code fails", %{conn: conn} do
      email = Fixtures.unique_email()
      conn = request_code(conn, email)
      code = code_in(receive_email())

      expire!(email)

      assert html_response(verify(conn, code), 200) =~ "That code didn&#39;t work"
      assert {:ok, nil} = Accounts.get_user_by_email(email, actor: Fixtures.system_actor())
    end

    test "a consumed code cannot be used again from another browser", %{conn: conn} do
      email = Fixtures.unique_email()
      {first, code} = sign_in(conn, email)
      assert redirected_to(first) == "/personal"

      again = build_conn() |> init_test_session(%{sign_in_email: email}) |> verify(code)
      assert html_response(again, 200) =~ "That code didn&#39;t work"
      refute get_session(again, "user_token")
    end

    test "a new request invalidates the previous code", %{conn: conn} do
      email = Fixtures.unique_email()
      conn = request_code(conn, email)
      first = code_in(receive_email())
      conn = request_code(conn, email)
      second = code_in(receive_email())

      assert html_response(verify(conn, first), 200) =~ "That code didn&#39;t work"
      assert redirected_to(verify(conn, second)) == "/personal"
    end

    test "malformed codes fail without touching the stored code", %{conn: conn} do
      email = Fixtures.unique_email()
      conn = request_code(conn, email)
      code = code_in(receive_email())

      # Non-string parameters (a map, a list, nil) get the same sentence too (not a 500).
      for bad <- ["12345", "1234567", "abcdef", "", "12 34 5", %{"a" => "1"}, ["123", "456"], nil] do
        assert html_response(verify(conn, bad), 200) =~ "That code didn&#39;t work"
      end

      # Malformed attempts are not counted; after eight of them the code is still alive.
      assert redirected_to(verify(conn, code)) == "/personal"
    end

    test "signing in renews the session and drops the pending address", %{conn: conn} do
      email = Fixtures.unique_email()
      conn = init_test_session(conn, %{unrelated: "kept"})
      {conn, _code} = sign_in(conn, email)

      # Session fixation guard: `Plug.Session` sees `:renew` just before the response and issues a
      # new session id (`configure_session(renew: true)` in `PromptOnWeb.UserSession.sign_in/2`).
      assert conn.private[:plug_session_info] == :renew
      assert get_session(conn, "user_token")
      refute get_session(conn, :sign_in_email)
      assert get_session(conn, :unrelated) == "kept"
    end

    test "spaces and dashes in the typed code are tolerated", %{conn: conn} do
      email = Fixtures.unique_email()
      conn = request_code(conn, email)
      code = code_in(receive_email())
      {left, right} = String.split_at(code, 3)

      assert redirected_to(verify(conn, "#{left} #{right}")) == "/personal"
    end

    test "without a pending address it goes back to the email form", %{conn: conn} do
      conn = verify(conn, "123456")
      assert redirected_to(conn) == "/sign-in"
      refute get_session(conn, "user_token")
    end
  end

  describe "POST /sign-in/resend and /sign-in/reset" do
    test "resend emails a fresh code for the pending address and stays on the code form", %{
      conn: conn
    } do
      email = Fixtures.unique_email()
      conn = request_code(conn, email)
      first = code_in(receive_email())

      conn = post(conn, ~p"/sign-in/resend")
      assert redirected_to(conn) == "/sign-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "We emailed a 6-digit code to #{email}"

      assert %{to: [{"", ^email}]} = mail = receive_email()
      second = code_in(mail)
      refute first == second

      assert html_response(get(conn, ~p"/sign-in"), 200) =~ ~s(id="sign-in-code")
      assert redirected_to(verify(conn, second)) == "/personal"
    end

    test "reset drops the pending address — the email form is back", %{conn: conn} do
      email = Fixtures.unique_email()
      conn = request_code(conn, email)
      receive_email()

      conn = post(conn, ~p"/sign-in/reset")
      assert redirected_to(conn) == "/sign-in"
      refute get_session(conn, :sign_in_email)

      html = html_response(get(conn, ~p"/sign-in"), 200)
      assert html =~ ~s(id="sign-in-form")
      refute html =~ ~s(id="sign-in-code")
    end

    test "resend with nothing pending goes back to the email form without sending", %{conn: conn} do
      assert redirected_to(post(conn, ~p"/sign-in/resend")) == "/sign-in"
      refute_email()
    end
  end

  describe "CSRF" do
    # The pending address lives in the session. Another site must not be able to use the victim's
    # browser to plant an address (`POST /sign-in`), submit a code (`/verify`) or change it
    # (`/resend`, `/reset`). `Phoenix.ConnTest` skips the CSRF check by default, so it is turned on
    # only here.
    test "every sign-in POST without a token is refused with 403 and changes nothing" do
      for {path, params} <- [
            {~p"/sign-in", %{"email" => Fixtures.unique_email()}},
            {~p"/sign-in/verify", %{"code" => "123456"}},
            {~p"/sign-in/resend", %{}},
            {~p"/sign-in/reset", %{}}
          ] do
        conn =
          build_conn()
          |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
          |> init_test_session(%{sign_in_email: "pending@example.com"})

        assert_error_sent 403, fn -> post(conn, path, params) end
      end

      refute_email()
    end
  end

  describe "throttling" do
    test "after three requests for the same address the fourth sends nothing — same flash", %{
      conn: conn
    } do
      email = Fixtures.unique_email()

      flashes =
        for _ <- 1..4 do
          conn = request_code(conn, email)
          assert redirected_to(conn) == "/sign-in"
          Phoenix.Flash.get(conn.assigns.flash, :info)
        end

      # Only three emails.
      for _ <- 1..3, do: receive_email()
      refute_email()

      # The fourth notice is the same as the first; the throttle is invisible.
      assert List.last(flashes) == List.first(flashes)
    end

    test "is per address — another address still gets its code", %{conn: conn} do
      throttled = Fixtures.unique_email()
      for _ <- 1..4, do: request_code(conn, throttled)
      for _ <- 1..3, do: receive_email()
      refute_email()

      other = Fixtures.unique_email()
      request_code(conn, other)
      assert %{to: [{"", ^other}]} = receive_email()
    end

    test "resend counts against the same address bucket", %{conn: conn} do
      email = Fixtures.unique_email()
      conn = request_code(conn, email)
      receive_email()

      conn = post(conn, ~p"/sign-in/resend")
      receive_email()
      conn = post(conn, ~p"/sign-in/resend")
      receive_email()

      conn = post(conn, ~p"/sign-in/resend")
      assert redirected_to(conn) == "/sign-in"
      refute_email()
    end
  end

  describe "return_to" do
    test "a visitor who started at /device?code=… lands back there after the code" do
      email = Fixtures.unique_email()

      # Signed out, open the link the CLI handed out → sent to sign-in, and the place to return to
      # goes into the session cookie.
      conn = build_conn() |> init_test_session(%{}) |> get(~p"/device?code=ABCD-EFGH")
      assert redirected_to(conn) == "/sign-in"
      assert get_session(conn, :return_to) == "/device?code=ABCD-EFGH"

      # Get and enter the code from the same browser (cookie).
      {conn, _code} = sign_in(conn, email)
      assert redirected_to(conn) == "/device?code=ABCD-EFGH"
      assert get_session(conn, "user_token")
      refute get_session(conn, :return_to)

      # And that screen actually opens (passes `RequireUserWithReturnTo`).
      assert html_response(get(conn, ~p"/device?code=ABCD-EFGH"), 200) =~ "prompton cli"
    end

    test "an external return_to is ignored (open redirect guard)" do
      for evil <- ["https://evil.example/x", "//evil.example/x", "/\\evil.example", "evil"] do
        conn = build_conn() |> init_test_session(%{return_to: evil})
        {conn, _code} = sign_in(conn, Fixtures.unique_email())

        assert redirected_to(conn) == "/personal"
        refute get_session(conn, :return_to)
      end
    end
  end

  # Expiry is decided by the clock; only the test pushes the column into the past.
  defp expire!(email) do
    at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_naive()

    PromptOn.Repo.query!("UPDATE sign_in_codes SET expires_at = $1 WHERE email = $2", [
      at,
      email
    ])

    :ok
  end
end
