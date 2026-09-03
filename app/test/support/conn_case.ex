defmodule PromptOnWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use PromptOnWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint PromptOnWeb.Endpoint

      use PromptOnWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PromptOnWeb.ConnCase
    end
  end

  setup tags do
    PromptOn.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Plants the user in the session so the conn is signed in.

  User has `store_all_tokens? true` + `require_token_presence_for_authentication? true`, so the
  **raw token** goes into the session and `load_from_session` checks it against the Token table.
  Since email codes are the only sign-in (ADR 0008), this mints the same session token a finished
  sign-in would, without the code round trip (`AshAuthentication.Jwt.token_for_user/2`,
  `purpose: "user"`, stored in the tokens table), and puts it under the same key (`user_token`)
  that the `store_in_session` in `PromptOnWeb.UserSession.sign_in/2` uses.
  """
  def log_in_user(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user, %{})
    signed_in = Ash.Resource.put_metadata(user, :token, token)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(signed_in)
  end

  @doc """
  For `setup :register_and_log_in_user`. Provides `%{conn:, user:}`.
  """
  def register_and_log_in_user(%{conn: conn}) do
    user = PromptOn.Fixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end
end
