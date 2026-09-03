defmodule PromptOn.Accounts do
  @moduledoc """
  Sign-in and organization domain (outside the tenant). plan.md §5.1.
  Provider keys (BYOK) live here too, since the owning unit is the organization.
  CLI device sign-in (`DeviceAuthorization`) is here as well, because what gets issued is a
  **user token**, so its owner is the user (management keys were deleted on 2026-09-02).
  """

  use Ash.Domain,
    otp_app: :prompton,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource PromptOn.Accounts.Token

    resource PromptOn.Accounts.User do
      define :get_user_by_email, action: :get_by_email, args: [:email], not_found_error?: false

      # By email only (system actor only): the first success of code sign-in (`SignIn.verify/3`),
      # seeds, fixtures, and `mix prompton.seed_admin`. A person's sign-up/sign-in is a single
      # email code (`User` moduledoc, ADR 0008).
      define :register_user, action: :register
    end

    # Sign-in codes (ADR 0008 revision: 6-digit email code). All three are called by
    # `PromptOn.Accounts.SignIn` as the system actor.
    resource PromptOn.Accounts.SignInCode do
      define :request_sign_in_code, action: :request
      define :attempt_sign_in_code, action: :attempt
      define :sweep_expired_sign_in_codes, action: :sweep_expired
    end

    resource PromptOn.Accounts.Organization do
      define :create_organization, action: :create
      define :create_personal_organization, action: :create_personal
      define :rename_organization, action: :rename
      define :claim_organization_slug, action: :claim_slug

      # Resolves `/{org_slug}`: team organizations only. Personal organizations have no slug and
      # resolve via `/personal`.
      define :get_organization_by_slug, action: :by_slug, args: [:slug], not_found_error?: false

      # Resolves `/personal`: the user's personal organization.
      define :personal_organization_for,
        action: :personal_for_user,
        args: [:user_id],
        not_found_error?: false

      # Organization switcher.
      define :list_organizations_for, action: :for_user, args: [:user_id]
      define :list_organizations, action: :read
    end

    resource PromptOn.Accounts.Membership do
      define :add_member, action: :add
      define :list_memberships, action: :read
    end

    # BYOK provider keys are **organization-owned** (2026-09-01 revision: moved up from the
    # project).
    resource PromptOn.Accounts.ProviderKey do
      define :register_provider_key, action: :register
      define :rotate_provider_key, action: :rotate
      define :revoke_provider_key, action: :revoke
      define :touch_provider_key, action: :touch_last_used
      define :list_provider_keys, action: :active, args: [:organization_id]

      define :active_provider_key,
        action: :for_provider,
        args: [:organization_id, :provider],
        not_found_error?: false
    end

    # Device authorization (CLI sign-in, agent-first-spec batch ③). Code issuance and polling are
    # called by the unauthenticated path as SystemActor; approve and deny are done by the **user**
    # on the `/device` screen.
    resource PromptOn.Accounts.DeviceAuthorization do
      define :start_device_authorization, action: :start
      define :approve_device_authorization, action: :approve
      define :deny_device_authorization, action: :deny
      define :consume_device_authorization, action: :consume
      define :touch_device_poll, action: :touch_poll
      define :sweep_expired_device_authorizations, action: :sweep_expired

      define :device_authorization_by_user_code,
        action: :by_user_code,
        args: [:user_code],
        not_found_error?: false

      define :device_authorization_by_device_code,
        action: :by_device_code,
        args: [:device_code],
        not_found_error?: false
    end
  end
end
