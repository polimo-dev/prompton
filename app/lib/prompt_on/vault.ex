defmodule PromptOn.Vault do
  @moduledoc """
  The Cloak vault used by AshCloak. Encrypts `GenerationPayload` (raw payloads) and
  `ProviderKey.secret` (P1) with AES-256-GCM. The key comes from
  `config :prompton, PromptOn.Vault, ciphers: [...]` (runtime.exs fills it from `PTN_VAULT_KEY`).
  Key rotation uses Cloak's multiple ciphers (replace `default`, keep the old key under `retired:`).
  """

  use Cloak.Vault, otp_app: :prompton
end
