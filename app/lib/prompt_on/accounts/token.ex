defmodule PromptOn.Accounts.Token do
  @moduledoc """
  The ash_authentication token store (`tokens` table). Browser sessions (`purpose: "user"`) and
  CLI sessions (`purpose: "cli"`, `PromptOn.Accounts.CliSession`) live in the same table.
  Revoking means changing that row's purpose to `"revocation"`, so a "live CLI session" = a row
  with `purpose == "cli"`.

  ## What we added

  On top of the actions ash_authentication generates there are two more:

  - `:cli_sessions`: the list of one user's (`subject`) live CLI sessions. The account screen's
    "Logged-in devices".
  - `:annotate`: updates `extra_data`. A CLI session's device name (`client`, `name`) and
    last-used time go in here. Token storage (`store_token`) is done by ash_authentication, so
    the metadata is attached separately right after issuance.

  Both actions are **`PromptOn.SystemActor` only**; no policy opens them to a user actor. That
  the rows belong to the user is guaranteed by the caller (`CliSession`), which computes the
  subject from a `%User{}` and pins it into the filter (the same trust boundary as internal
  modules such as `ProviderKeyCache`).
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table "tokens"
    repo PromptOn.Repo
  end

  actions do
    defaults [:read]

    read :expired do
      description "Look up all expired tokens."
      filter expr(expires_at < now())
    end

    read :cli_sessions do
      description """
      One user's live CLI sessions (`purpose == "cli"`; a revoked one drops out because its
      purpose changes). Most recently issued first.
      """

      argument :subject, :string, allow_nil?: false
      filter expr(purpose == "cli" and subject == ^arg(:subject) and expires_at > now())
      prepare build(sort: [created_at: :desc])
    end

    read :get_token do
      description "Look up a token by JTI or token, and an optional purpose."
      get? true
      argument :token, :string, sensitive?: true
      argument :jti, :string, sensitive?: true
      argument :purpose, :string, sensitive?: false

      prepare AshAuthentication.TokenResource.GetTokenPreparation
    end

    action :revoked?, :boolean do
      description "Returns true if a revocation token is found for the provided token"
      argument :token, :string, sensitive?: true
      argument :jti, :string, sensitive?: true

      run AshAuthentication.TokenResource.IsRevoked
    end

    create :revoke_token do
      description "Revoke a token. Creates a revocation token corresponding to the provided token."
      accept [:extra_data]
      argument :token, :string, allow_nil?: false, sensitive?: true

      change AshAuthentication.TokenResource.RevokeTokenChange
    end

    create :revoke_jti do
      description "Revoke a token by JTI. Creates a revocation token corresponding to the provided jti."
      accept [:extra_data]
      argument :subject, :string, allow_nil?: false, sensitive?: true
      argument :jti, :string, allow_nil?: false, sensitive?: true

      change AshAuthentication.TokenResource.RevokeJtiChange
    end

    create :store_token do
      description "Stores a token used for the provided purpose."
      accept [:extra_data, :purpose]
      argument :token, :string, allow_nil?: false, sensitive?: true
      change AshAuthentication.TokenResource.StoreTokenChange
    end

    destroy :expunge_expired do
      description "Deletes expired tokens."
      change filter(expr(expires_at < now()))
    end

    update :revoke_all_stored_for_subject do
      description "Revokes all stored tokens for a specific subject."
      accept [:extra_data]
      argument :subject, :string, allow_nil?: false, sensitive?: true
      change AshAuthentication.TokenResource.RevokeAllStoredForSubjectChange
    end

    update :annotate do
      description """
      Replaces `extra_data` wholesale: a CLI session's device name and last-used time (internal
      only).
      """

      accept [:extra_data]
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      description "AshAuthentication can interact with the token resource"
      authorize_if always()
    end

    bypass PromptOn.Checks.SystemActor do
      description """
      `:cli_sessions`, `:annotate`, and bulk session revocation are called by internal modules as
      SystemActor.
      """

      authorize_if always()
    end
  end

  attributes do
    attribute :jti, :string do
      primary_key? true
      public? true
      allow_nil? false
      sensitive? true
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :purpose, :string do
      allow_nil? false
      public? true
    end

    attribute :extra_data, :map do
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end
end
