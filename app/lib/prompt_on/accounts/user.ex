defmodule PromptOn.Accounts.User do
  @moduledoc """
  A signed-in user (LiveView actor, management API actor).

  **The one and only sign-in method is a 6-digit code sent by email** (user decision 2026-09-03,
  ADR 0008 `docs/adr/0008-email-only-sign-in.md`; it started as a magic link and changed to a
  code the same day). The password strategy and its actions (`register_with_password`,
  `sign_in_with_password`, `sign_in_with_token`, `change_password`, `set_password`) and the magic
  link strategy and its actions (`request_magic_link`, `sign_in_with_magic_link`) were all
  deleted. **This resource has no ash_authentication strategy**; the extension remains only for
  session tokens (the `tokens` config, `PromptOn.Accounts.Token`) and `load_from_session`.

  **Sign-up = sign-in**: an unknown email requesting a code still gets one, and the moment the
  code is entered correctly the user is created (`PromptOn.Accounts.SignIn.verify/3` →
  `:register`). When a user is created, a personal `Organization` + `Membership(role: :owner)`
  are created in the same transaction (`Changes.CreatePersonalOrganization`).

  ## Flow

  1. Email on `/sign-in` (`PromptOnWeb.SignInController`) → `PromptOn.Accounts.SignIn.request/2`
     (per-email and per-IP throttle → `SignInCode.:request`, a 5-minute 6-digit code with only
     the hash stored → sent via Resend by `SignIn.Email`). The result is always `:ok`; neither
     account existence nor throttling shows on screen.
  2. The code field on the same screen → `SignIn.verify/3` (`SignInCode.:attempt`: attempt
     counting under a lock, 5 tries, single use) → find the user or create one via `:register`.
  3. The controller mints a session token and plants it in the session
     (`PromptOnWeb.UserSession.sign_in/2`: `AshAuthentication.Jwt.token_for_user/2` +
     `store_in_session`).

  seeds, fixtures, and `mix prompton.seed_admin` create users via `:register` (system actor only)
  without mail.

  ## Schema expand/contract

  The `hashed_password` column **stays, nullable, in this release** (expand: old code reads it
  during the rolling deploy) and is dropped in the next release (contract, ADR 0005). New code
  uses it nowhere.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  # No strategies; only the session token config. Sign-in is `PromptOn.Accounts.SignIn` (email
  # code).
  authentication do
    tokens do
      enabled? true
      token_resource PromptOn.Accounts.Token
      signing_secret PromptOn.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end
  end

  postgres do
    table "users"
    repo PromptOn.Repo
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    create :register do
      description """
      Creates a user from an email alone: the first success of code sign-in
      (`PromptOn.Accounts.SignIn.verify/3`), seeds, test fixtures, and `mix prompton.seed_admin`
      (system actor only). Creates the personal Organization/Membership (owner) along with it.

      Two concurrent sign-ins with the same **new** address: the second INSERT is blocked by the
      `users.email` unique index, and `SignIn` looks up again and signs in as the user the first
      one created. There is one user and one personal organization.
      """

      accept [:email]
      change PromptOn.Accounts.User.Changes.CreatePersonalOrganization
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      description """
      Session token → user (`load_from_session`'s `get_by_subject`) is called by
      ash_authentication in its own context.
      """

      authorize_if always()
    end

    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      description """
      Oneself, and **members of the same organization**. For the organization members screen
      (`/{org}/members`) to show emails it has to load the membership's `user`, and that load goes
      through this action's policy; allowing only oneself would render other rows with a blank
      email. Users outside the organization remain invisible.
      """

      authorize_if expr(id == ^actor(:id))
      authorize_if expr(exists(organizations.memberships, user_id == ^actor(:id)))
    end

    policy action_type([:create, :update, :destroy, :action]) do
      description "`:register` is system actor only; there are no other writes."
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    # A remnant of password sign-in: nullable this release (expand), column dropped next release
    # (contract).
    attribute :hashed_password, :string do
      allow_nil? true
      sensitive? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :memberships, PromptOn.Accounts.Membership do
      public? true
    end

    many_to_many :organizations, PromptOn.Accounts.Organization do
      through PromptOn.Accounts.Membership
      source_attribute_on_join_resource :user_id
      destination_attribute_on_join_resource :organization_id
      public? true
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
