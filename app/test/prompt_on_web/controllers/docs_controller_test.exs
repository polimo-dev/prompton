defmodule PromptOnWeb.DocsControllerTest do
  @moduledoc """
  `GET /docs/agent`: the integration guide for coding agents. No authentication, raw markdown.
  """
  use PromptOnWeb.ConnCase, async: false

  alias PromptOn.Fixtures

  test "redirects to the docs site when PTN_DOCS_URL is configured", %{conn: conn} do
    previous = Application.get_env(:prompton, :docs_url)
    Application.put_env(:prompton, :docs_url, "https://docs.example.test/")
    on_exit(fn -> Application.put_env(:prompton, :docs_url, previous) end)

    conn = get(conn, ~p"/docs/agent")

    assert redirected_to(conn, 302) == "https://docs.example.test/agent"
  end

  test "serves the agent guide as markdown", %{conn: conn} do
    conn = get(conn, ~p"/docs/agent")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]
    assert conn.resp_body =~ "prompton login"
  end

  test "is the same file that ships in priv/docs", %{conn: conn} do
    conn = get(conn, ~p"/docs/agent")

    assert conn.resp_body == File.read!(Application.app_dir(:prompton, "priv/docs/agent.md"))
    assert String.starts_with?(conn.resp_body, "# PromptOn")
  end

  test "needs no login and is unchanged for a logged-in user", %{conn: conn} do
    user = Fixtures.user_fixture()

    anonymous = get(conn, ~p"/docs/agent")
    logged_in = conn |> log_in_user(user) |> get(~p"/docs/agent")

    assert anonymous.status == 200
    assert logged_in.status == 200
    assert anonymous.resp_body == logged_in.resp_body
  end
end
