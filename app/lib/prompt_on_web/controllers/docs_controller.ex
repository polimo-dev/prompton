defmodule PromptOnWeb.DocsController do
  @moduledoc """
  The consolidated documentation for coding agents (`GET /docs/agent`).

  The canonical documentation lives in a separate repo, **prompton-docs** (docs.prompton.ai - HTML
  for browsers, markdown for programs) (user decision 2026-09-03). When `PTN_DOCS_URL`
  (`config :prompton, :docs_url`) is set, this **302**s there - the landing prompt and old links
  carry this path, so the path stays. Without it (local, or a deployment without a docs site),
  `priv/docs/agent.md` is read at request time and served as raw markdown (`text/markdown`).
  Unauthenticated, and a static top-level path outside the organization scope.
  """
  use PromptOnWeb, :controller

  @doc_path "priv/docs/agent.md"

  def agent(conn, _params) do
    case docs_url() do
      nil ->
        body = :prompton |> Application.app_dir(@doc_path) |> File.read!()

        conn
        |> put_resp_content_type("text/markdown")
        |> send_resp(200, body)

      docs_url ->
        redirect(conn, external: docs_url <> "/agent")
    end
  end

  defp docs_url do
    case Application.get_env(:prompton, :docs_url) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _other -> nil
    end
  end
end
