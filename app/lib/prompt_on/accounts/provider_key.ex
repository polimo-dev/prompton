defmodule PromptOn.Accounts.ProviderKey do
  @moduledoc """
  **Provider credentials (BYOK)**: the LLM provider key used by the arena and AI drafts
  (plan.md §5.4, §11.2). Kept separate from the app's operational key (`PTN_OPENROUTER_API_KEY`)
  to split costs and shrink the blast radius of a leak; registering the same key is fine.

  **The owning unit is the organization** (2026-09-01 revision). There is no reason to make every
  project register the same OpenRouter key again, and billing and members live at the
  organization, so the key lives there too. That is why this resource is **outside the tenant**:
  it does not use `fragments: [PromptOn.ProjectScoped]` and has `belongs_to :organization`
  directly. All that remains at the project is PromptOn's own SDK key
  (`PromptOn.Projects.ApiKey`).

  - **Encryption**: `AshCloak` encrypts `secret` with `PromptOn.Vault` (AES-256-GCM,
    `PTN_VAULT_KEY`) into `encrypted_secret` (bytea, `term_to_binary` → ciphertext → base64) and
    decrypts it through a **calculation** of the same name. Because of `decrypt_by_default []`,
    the raw value is unwrapped only where `load: [:secret]` is explicit
    (= `PromptOn.Accounts.ProviderKeyCache` and the key resolution in `PromptOn.LLM.OpenRouter`).
  - **`secret_hint` is a plaintext (unencrypted) display value.** The settings screen has to show
    the list of registered keys, and waking the vault (= decrypting) every time would spread the
    raw value into process memory, logs, and socket state. So a masked string is built once at
    write time and stored separately, and list/detail screens read only `secret_hint` (zero
    decryptions). See `hint/1` for the format: a readable prefix + `••••` + the last 4 characters
    (e.g. `"sk-or-v1-••••4Xa2"`). The prefix identifies the provider; the last 4 characters let
    you confirm "is this the key I registered".
  - **The only registrable provider is OpenRouter** (2026-09-01 decision); see the comment above
    `@providers`. The `provider` attribute/column remains, so the day providers multiply only the
    list needs reopening.
  - `:revoke` is soft; it leaves an audit trail. `:for_provider` returns **the single most recent
    non-revoked key**.
  - The write actions (`:register`/`:rotate`/`:revoke`) clear the matching entry in
    `PromptOn.Accounts.ProviderKeyCache` via `Changes.BustCache`, so the server's LLM calls do not
    keep using the old key for a whole TTL.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  alias PromptOn.Accounts.ProviderKey.Changes

  # **BYOK is OpenRouter only** (2026-09-01 decision). OpenRouter is itself a router, so an app
  # has no reason to register five provider keys for the sake of one model, and the only adapter
  # the server actually calls is `PromptOn.LLM.OpenRouter`; accepting another provider's key gave
  # that key nowhere to go.
  # **The `provider` attribute and column stay as atoms**: if we later call providers directly,
  # we just add them back to this list, and since the atom `one_of` is an app-level constraint
  # there is no migration then either. The meaning of already stored values does not change.
  @providers [:openrouter]

  postgres do
    table "provider_keys"
    repo PromptOn.Repo

    references do
      reference :organization, on_delete: :delete
    end
  end

  cloak do
    vault(PromptOn.Vault)
    attributes([:secret])
    decrypt_by_default([])
  end

  actions do
    defaults [:read, :destroy]

    create :register do
      description """
      Registers a provider key. `secret` is encrypted and `secret_hint` (plaintext mask) is
      stored alongside.
      """

      accept [:organization_id, :provider, :label, :secret]
      change Changes.SetSecretHint
      change Changes.BustCache
    end

    update :rotate do
      description "Replaces the key. Recomputes `secret_hint` from the new `secret`."
      accept [:secret]
      require_atomic? false
      change Changes.SetSecretHint
      change Changes.BustCache
    end

    update :revoke do
      description "Soft revocation. Drops out of `:active`/`:for_provider`."
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
      change Changes.BustCache
    end

    update :touch_last_used do
      description "Called best-effort by the adapter when the key was used in an actual call."
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end

    read :active do
      description """
      The organization's non-revoked keys (settings screen list). Most recently registered first.
      """

      argument :organization_id, :uuid, allow_nil?: false
      filter expr(organization_id == ^arg(:organization_id) and is_nil(revoked_at))
      prepare build(sort: [inserted_at: :desc])
    end

    read :for_provider do
      description """
      The **single most recent non-revoked key** for organization × provider. `nil` if none.
      """

      argument :organization_id, :uuid, allow_nil?: false
      argument :provider, :atom, allow_nil?: false, constraints: [one_of: @providers]
      get? true

      filter expr(
               organization_id == ^arg(:organization_id) and provider == ^arg(:provider) and
                 is_nil(revoked_at)
             )

      prepare build(sort: [inserted_at: :desc], limit: 1)
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    # The server's key resolution is done by `PromptOn.Accounts.ProviderKeyCache` as
    # **SystemActor** (the bypass above short-circuits); there is no path where an ApiKey actor
    # reads this resource directly. So it is a blanket forbid.
    policy PromptOn.Checks.ApiKeyActor do
      description "The ApiKey actor (public API) can neither read nor write provider keys."
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if {PromptOn.Checks.OrganizationMember, path: [:organization]}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {PromptOn.Checks.OrganizationMember, path: [:organization]}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
      constraints one_of: @providers
    end

    attribute :label, :string do
      description "Distinguishes multiple keys under the same provider."
      allow_nil? false
      public? true
      default "default"
    end

    attribute :secret, :string do
      description "The raw provider API key, encrypted (`encrypted_secret`). Not loaded by default."
      allow_nil? false
      public? true
      sensitive? true
    end

    attribute :secret_hint, :string do
      description """
      Masked display value (plaintext). Used by list/detail screens without decryption. Built by
      `hint/1`.
      """

      public? true
    end

    attribute :last_used_at, :utc_datetime_usec, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :organization, PromptOn.Accounts.Organization do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_provider_label, [:organization_id, :provider, :label]
  end

  # Keeps only the **fixed prefix** a provider attaches, like `sk-or-v1-`, `sk-ant-api03-`,
  # `sk-proj-`, `gsk_`: 1-6 letters + (separator + 1-6 alphanumerics) 0-2 times + separator. The
  # random body never matches (`AIzaSy…` has no prefix).
  @prefix_regex ~r/^[A-Za-z]{1,6}(?:[-_][A-Za-z0-9]{1,6}){0,2}[-_]/

  @doc "The providers that can be registered as BYOK (currently just `[:openrouter]`)."
  @spec providers() :: [atom()]
  def providers, do: @providers

  @doc """
  Raw key → masked display value: a readable prefix (if any) + `••••` + the last 4 characters.

      iex> PromptOn.Accounts.ProviderKey.hint("sk-or-v1-0123456789abcdef4Xa2")
      "sk-or-v1-••••4Xa2"

      iex> PromptOn.Accounts.ProviderKey.hint("AIzaSyA0123456789abcdef")
      "••••cdef"

      iex> PromptOn.Accounts.ProviderKey.hint("short")
      "••••"

      iex> PromptOn.Accounts.ProviderKey.hint(nil)
      nil

  If what remains after the prefix is shorter than 8 characters, the last 4 are hidden too (in a
  short key the raw portion would be too large).
  """
  @spec hint(String.t() | nil) :: String.t() | nil
  def hint(nil), do: nil

  def hint(secret) when is_binary(secret) do
    case String.trim(secret) do
      "" -> nil
      trimmed -> build_hint(trimmed)
    end
  end

  defp build_hint(secret) do
    prefix =
      case Regex.run(@prefix_regex, secret) do
        [match] -> match
        _ -> ""
      end

    rest = String.replace_prefix(secret, prefix, "")

    if String.length(rest) >= 8 do
      prefix <> "••••" <> String.slice(rest, -4..-1//1)
    else
      prefix <> "••••"
    end
  end
end
