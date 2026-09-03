defmodule PromptOnWeb.API.V1.ErrorJSON do
  @moduledoc """
  Public API error envelope (plan.md §6.1):
  `{"error": {"code": "unauthorized|forbidden|not_found|invalid_request|conflict", "message": "...", "details": {}}}`
  """

  def render("error.json", %{code: code} = assigns) do
    %{
      error: %{
        code: code,
        message: Map.get(assigns, :message, code),
        details: Map.get(assigns, :details, %{})
      }
    }
  end
end
