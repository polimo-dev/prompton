defmodule PromptOn.Secrets do
  @moduledoc """
  ash_authentication token signing secret (`config :prompton, :token_signing_secret`, filled from
  `PTN_TOKEN_SIGNING_SECRET` in runtime.exs).
  """

  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        PromptOn.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:prompton, :token_signing_secret)
  end
end
