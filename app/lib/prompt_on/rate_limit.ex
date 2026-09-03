defmodule PromptOn.RateLimit do
  @moduledoc """
  Process-local (ETS) rate limiter, the store behind `PromptOnWeb.Plugs.RateLimit` (Hammer).

  Each node counts separately: with two replicas the effective limit is up to twice as high. What
  this guards right now is abuse of the unauthenticated device sign-in routes
  (`POST /api/v1/device/code|token`), not a precise billing quota, so that much slack is fine.
  When a shared counter (Redis) becomes necessary, only `backend:` changes.
  """
  use Hammer, backend: :ets
end
