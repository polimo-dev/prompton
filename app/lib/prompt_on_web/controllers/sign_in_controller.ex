defmodule PromptOnWeb.SignInController do
  @moduledoc """
  The sign-in screen (`/sign-in`) - a single **6-digit code sent by email** (user decision
  2026-09-03, ADR 0008 revision). Not a LiveView but an **ordinary controller flow**: seeding the
  session with a token can only be done in an HTTP request, and verifying the code is that very
  request, so there is no intermediate step for handing the token around.

  | Request | What it does |
  |---|---|
  | `GET  /sign-in` | Email field; with a **pending address** in the session (`:sign_in_email`), its code field |
  | `POST /sign-in` | `SignIn.request/2` -> address into the session, then `/sign-in` (code field + "We emailed a 6-digit code…") |
  | `POST /sign-in/verify` | `SignIn.verify/3` -> seed the session (`PromptOnWeb.UserSession.sign_in/2`) -> return-to path or `/personal` |
  | `POST /sign-in/resend` | `request/2` again for the pending address (same throttle) |
  | `POST /sign-in/reset` | "Use a different email" - drops the pending address |

  **The screen never says whether an address exists** - the message is the same whether it exists,
  does not, or hit the throttle. A code failure is also a single sentence ("That code didn't
  work…"). Only the inline error for a value not shaped like an email looks different.

  A signed-in user goes to `/personal` on any request. CSRF is `protect_from_forgery` in the
  `:browser` pipeline. The client IP (the throttle key) is `PromptOn.ClientIp.from_conn/1`.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Accounts.SignIn
  alias PromptOn.ClientIp
  alias PromptOnWeb.UserSession

  plug :redirect_signed_in

  # Session key - the address waiting for a code.
  @pending :sign_in_email

  @invalid_email "Enter a valid email address."
  @code_failed "That code didn't work. Check it or request a new one."
  @unavailable "Something went wrong on our side. Please try again."

  def show(conn, _params) do
    case get_session(conn, @pending) do
      nil -> email_form(conn, "", nil)
      email -> code_form(conn, email, nil)
    end
  end

  def send_code(conn, params) do
    email = params |> string_param("email") |> String.trim()

    case SignIn.request(email, ClientIp.from_conn(conn)) do
      :ok -> conn |> put_session(@pending, email) |> sent(email)
      {:error, :invalid_email} -> email_form(conn, email, @invalid_email)
      {:error, :unavailable} -> email_form(conn, email, @unavailable)
    end
  end

  def verify(conn, params) do
    case get_session(conn, @pending) do
      nil ->
        redirect(conn, to: ~p"/sign-in")

      email ->
        code = string_param(params, "code")

        case SignIn.verify(email, code, ClientIp.from_conn(conn)) do
          {:ok, user} -> signed_in(conn, user)
          {:error, :invalid} -> code_form(conn, email, @code_failed)
        end
    end
  end

  def resend(conn, _params) do
    case get_session(conn, @pending) do
      nil ->
        redirect(conn, to: ~p"/sign-in")

      email ->
        case SignIn.request(email, ClientIp.from_conn(conn)) do
          :ok -> sent(conn, email)
          {:error, _reason} -> conn |> delete_session(@pending) |> email_form(email, @unavailable)
        end
    end
  end

  def reset(conn, _params) do
    conn
    |> delete_session(@pending)
    |> redirect(to: ~p"/sign-in")
  end

  # ---------------------------------------------------------------------------

  defp signed_in(conn, user) do
    {conn, return_to} =
      conn
      |> delete_session(@pending)
      |> UserSession.pop_return_to(~p"/personal")

    conn
    |> UserSession.sign_in(user)
    |> put_flash(:info, "You are now signed in")
    |> redirect(to: return_to)
  end

  defp sent(conn, email) do
    conn
    |> put_flash(:info, "We emailed a 6-digit code to #{email}. It expires in 5 minutes.")
    |> redirect(to: ~p"/sign-in")
  end

  defp email_form(conn, email, error) do
    render(conn, :email, page_title: "Sign in", email: email, error: error)
  end

  defp code_form(conn, email, error) do
    render(conn, :code, page_title: "Enter your code", email: email, error: error)
  end

  # Form parameters must be strings - a value sent in a different shape (a map or list, like
  # `email[a]=b` or `code[]=1`) is treated as the empty string: that gives "Enter a valid email
  # address." / "That code didn't work" respectively, not a 500.
  defp string_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _not_a_string -> ""
    end
  end

  defp redirect_signed_in(conn, _opts) do
    if conn.assigns[:current_user] do
      conn |> redirect(to: ~p"/personal") |> halt()
    else
      conn
    end
  end
end
