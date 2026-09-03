defmodule PromptOnWeb.ErrorJSON do
  @moduledoc """
  Used by Phoenix `render_errors` to render the exceptions of JSON requests (404 for no route, 413
  for an exceeded body cap, 400 for a parse failure, and so on). Returns the same envelope as the
  public API (plan.md §6.1, contract decision #8):

      {"error": {"code": "not_found" | "payload_too_large" | "bad_request" | …, "message": "Not Found", "details": {}}}

  `code` is the reason atom of the status code (`Plug.Conn.Status.reason_atom/1`) - only 413 is
  fixed to `payload_too_large`. The exception contents never go into the response.
  """

  @doc "A template name like `\"404.json\"` -> error envelope."
  def render(template, _assigns) do
    status = status_of(template)

    %{
      error: %{
        code: code_of(status),
        message: Phoenix.Controller.status_message_from_template(template),
        details: %{}
      }
    }
  end

  @doc "Status code -> the envelope's `code` string."
  @spec code_of(pos_integer()) :: String.t()
  def code_of(413), do: "payload_too_large"

  def code_of(status) when is_integer(status) do
    status |> Plug.Conn.Status.reason_atom() |> Atom.to_string()
  rescue
    ArgumentError -> "error"
  end

  defp status_of(template) do
    template
    |> String.split(".", parts: 2)
    |> hd()
    |> Integer.parse()
    |> case do
      {status, ""} -> status
      _ -> 500
    end
  end
end
