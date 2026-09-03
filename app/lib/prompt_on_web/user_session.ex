defmodule PromptOnWeb.UserSession do
  @moduledoc """
  The two jobs of the browser session - **seeding** and **the return-to path**. Used by
  `PromptOnWeb.SignInController` (after code verification) and
  `PromptOnWeb.AuthController.sign_out/2`.

  ## Seeding (`sign_in/2`)

  `User` has `store_all_tokens?` + `require_token_presence_for_authentication?`, so the session
  holds the **raw token** and `load_from_session` checks it against the `tokens` table. Signing in
  therefore means minting a session token (`AshAuthentication.Jwt.token_for_user/2`, purpose
  `"user"`, stored in the table) and putting it in with `store_in_session` - the test helper
  `PromptOnWeb.ConnCase.log_in_user/2` is the same two lines. On top of that the session is
  **renewed** (`configure_session(renew: true)` - session fixation prevention: the pre-sign-in
  session id is discarded. With the current cookie store this is merely a re-serialization, but the
  contract stays the same after moving to a server-side store).

  ## The return-to path (`pop_return_to/2`)

  Right after sign-in, sends the user back to the path `PromptOnWeb.Plugs.RequireUserWithReturnTo`
  stored in the session's `:return_to` (for example `/device?code=…`). **Only same-site paths** are
  accepted - values like `https://…`, `//evil` (protocol-relative), and `/\\evil` (which browsers
  read as `//`) are discarded in favor of the default path (open redirect prevention).
  """

  import Plug.Conn

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers
  alias PromptOn.Accounts.User

  @doc "Renews the session, mints and seeds a session token, then assigns `current_user`."
  @spec sign_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def sign_in(conn, %User{} = user) do
    {:ok, token, _claims} = Jwt.token_for_user(user, %{})
    signed_in = Ash.Resource.put_metadata(user, :token, token)

    conn
    |> configure_session(renew: true)
    |> Helpers.store_in_session(signed_in)
    |> assign(:current_user, signed_in)
  end

  @doc "Pops (deletes) the session's `:return_to`; returns it if same-site, otherwise `default`."
  @spec pop_return_to(Plug.Conn.t(), String.t()) :: {Plug.Conn.t(), String.t()}
  def pop_return_to(conn, default) when is_binary(default) do
    path = conn |> get_session(:return_to) |> same_site_path(default)
    {delete_session(conn, :return_to), path}
  end

  @doc """
  Is this a same-site absolute path - starts with `/`, is not `//`, has no backslash, and has no
  scheme or host.

      iex> PromptOnWeb.UserSession.same_site_path("/device?code=ABCD-EFGH", "/")
      "/device?code=ABCD-EFGH"

      iex> PromptOnWeb.UserSession.same_site_path("https://evil.example/x", "/personal")
      "/personal"

      iex> PromptOnWeb.UserSession.same_site_path("//evil.example", "/personal")
      "/personal"
  """
  @spec same_site_path(term(), String.t()) :: String.t()
  def same_site_path("/" <> rest = path, default) do
    uri = URI.parse(path)

    if String.starts_with?(rest, "/") or String.contains?(path, "\\") or
         not is_nil(uri.scheme) or not is_nil(uri.host),
       do: default,
       else: path
  end

  def same_site_path(_other, default), do: default
end
