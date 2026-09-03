defmodule PromptOnWeb.ManagementAPI do
  @moduledoc """
  HTTP helpers for management API tests: sends requests with a single Bearer token
  (a CLI session token from `PromptOn.Fixtures.cli_token_fixture/1`, or any string when a 401 is
  expected).

  This only saves controller tests from repeating
  `build_conn |> put_req_header(...) |> post(path, Jason.encode!(body))` every time. Authentication
  **always rides in the header**; that is this API's contract, so the tests must go through the
  same door.
  """

  import Phoenix.ConnTest

  @endpoint PromptOnWeb.Endpoint

  @doc "An empty conn carrying the Bearer token."
  def conn(raw) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer #{raw}")
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  def api_get(raw, path), do: raw |> conn() |> get(path)
  def api_post(raw, path, body \\ %{}), do: raw |> conn() |> post(path, Jason.encode!(body))
  def api_patch(raw, path, body \\ %{}), do: raw |> conn() |> patch(path, Jason.encode!(body))
end
