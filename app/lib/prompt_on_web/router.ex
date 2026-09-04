defmodule PromptOnWeb.Router do
  use PromptOnWeb, :router
  use AshAuthentication.Phoenix.Router

  import Oban.Web.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PromptOnWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  # Public API (plan.md §6): Bearer `ptn_<project_slug>_<32 chars>` → ApiKey actor + tenant.
  pipeline :api do
    plug :accepts, ["json"]
    plug PromptOnWeb.Plugs.ApiKeyAuth
  end

  # Management API (agent-first-spec batch ③): Bearer CLI session token → **User** actor.
  # **Neither the tenant nor the organization is decided by the key** — a user belongs to several
  # organizations, so the path (`/orgs/:org/…`) picks the organization and `ManagementOrgScope`
  # resolves it. The project is picked by the path beneath it.
  pipeline :user_token do
    plug :accepts, ["json"]
    plug PromptOnWeb.Plugs.UserTokenAuth
    plug PromptOnWeb.Plugs.ManagementOrgScope
  end

  # Device login (RFC 8628 style) — **unauthenticated**. All the CLI presents is the `device_code`
  # it was just handed; the person authenticates on the browser `/device` screen.
  pipeline :device do
    plug :accepts, ["json"]
  end

  # Per-IP limits on the unauthenticated paths (`PromptOnWeb.Plugs.RateLimit`). Code issuance is a
  # write that creates a row, so it is tight (a person signs in a few times per 10 minutes); polling
  # already has a per-code `slow_down`, so it is loose (one login knocking every 5 seconds for 15
  # minutes is 180 requests — room for three or four concurrent logins).
  pipeline :device_code_limit do
    plug PromptOnWeb.Plugs.RateLimit, bucket: :device_code, limit: 20, scale: :timer.minutes(10)
  end

  pipeline :device_token_limit do
    plug PromptOnWeb.Plugs.RateLimit, bucket: :device_token, limit: 600, scale: :timer.minutes(10)
  end

  # ===========================================================================
  # Route order contract — **static paths first, the organization scope (`/:org_slug/…`) last.**
  #
  # With URLs of the form `/{org_slug}/{project_slug}/...`, organization slugs share the router's
  # top-level namespace with the static paths (`/health` `/api` `/sign-in` `/sign-out` `/account`
  # `/oban` `/dev` …). Phoenix matches in **definition order**, so if `live "/:org_slug"` came
  # first, every single-segment static path (`/account` `/health` `/sign-in` …) would be swallowed
  # by the organization home. That is why this file opens the organization scope only **after**
  # declaring every static path. A new static top-level path must go **above** the organization
  # scope.
  #
  # The other direction (an organization stealing a static path's name) is blocked by
  # `PromptOn.Accounts.ReservedSlugs` — adding a static top-level path or a
  # `PromptOnWeb.static_paths/0` entry means adding it to that list too, and
  # `test/prompt_on/accounts/reserved_slugs_test.exs` enforces that the two stay in sync.
  # `personal` is not a route but a reserved segment — `/personal` is the current user's personal
  # organization.
  # ===========================================================================

  # Unauthenticated health checks (for the LB). Smoke-test an API key with GET /api/v1/use-cases.
  scope "/", PromptOnWeb do
    get "/health", HealthController, :index
    get "/health/ready", HealthController, :ready
  end

  # Integration doc for coding agents — **unauthenticated**, the raw markdown as-is
  # (`priv/docs/agent.md`). The prompt on the landing page (`/`) embeds this absolute URL, and an
  # agent finishes a migration from this one page. A static top-level path **above** the
  # organization scope; `docs` is also in `PromptOn.Accounts.ReservedSlugs`.
  scope "/docs", PromptOnWeb do
    get "/agent", DocsController, :agent
  end

  scope "/api/v1", PromptOnWeb.API.V1 do
    pipe_through :api

    # config-fetch (scope `:read`) — the app receives its config and calls the provider directly
    # with its own provider key.
    get "/use-cases", SnapshotController, :show
    post "/use-cases/:key/prompt", UseCasePromptController, :create

    # monitoring logs (scope `:logs`) — the app sends call results in batches.
    post "/logs", LogController, :create
  end

  # Device login (agent-first-spec batch ③, docs/management-api.md §2). Two unauthenticated
  # endpoints: get a code (`/device/code`), then poll until the person approves in the browser
  # (`/device/token`).
  scope "/api/v1/device", PromptOnWeb.API.V1 do
    pipe_through [:device, :device_code_limit]

    post "/code", DeviceController, :code
  end

  scope "/api/v1/device", PromptOnWeb.API.V1 do
    pipe_through [:device, :device_token_limit]

    post "/token", DeviceController, :token
  end

  # ===========================================================================
  # Management API — provisioning for coding AIs/CLIs (agent-first-spec batch ③,
  # docs/management-api.md).
  #
  # Lives **under the same `/api/v1` as the public API above, on different paths**: a runtime key
  # (`ptn_<project_slug>_…`) opens none of the paths here (the plug accepts only CLI session
  # tokens), and conversely a CLI token opens none of `/use-cases`, `/use-cases/:key/prompt`,
  # `/logs`. Two
  # layers, two pipelines.
  #
  # **The credential is a person** (2026-09-02, management keys deleted). That is why the path has
  # an organization segment — `:org` is a team organization slug or the reserved segment `personal`
  # (= that user's personal organization).
  #
  # Endpoint → domain action (request/response details are in docs/management-api.md):
  #
  # | Endpoint | Domain action |
  # |---|---|
  # | `GET    /me`                                      | the token's user + all organizations |
  # | `POST   /sessions/revoke`                         | revoke this token (`prompton logout`) |
  # | `GET    /orgs`                                    | `Accounts.Organization.:for_user` |
  # | `GET    /orgs/:org`                               | the one organization the path points at |
  # | `GET    /orgs/:org/projects`                      | `Projects.Project.:active` |
  # | `POST   /orgs/:org/projects`                      | `Projects.Project.:create` |
  # | `GET    /…/projects/:project/use-cases`           | `Prompts.UseCase.:active` |
  # | `POST   /…/projects/:project/use-cases`           | `Prompts.UseCase.:define` |
  # | `GET    /…/use-cases/:key`                        | `:by_key` + prompts/versions/live deploy |
  # | `PATCH  /…/use-cases/:key`                        | `:describe`·`:set_input_schema`·`:set_default_params` |
  # | `POST   /…/use-cases/:key/prompts`                | `Prompts.Prompt.:open` |
  # | `POST   /…/use-cases/:key/prompts/:name/versions` | `Prompts.PromptVersion.:commit` |
  # | `GET    /…/projects/:project/models`              | `Catalog.Model.:read` |
  # | `POST   /…/projects/:project/models`              | `Catalog.Model.:register` |
  # | `GET    /…/use-cases/:key/deployments`            | `Deployments.Deployment.:current` / `:history` |
  # | `POST   /…/use-cases/:key/deployments`            | `Deployments.Deployment.:commit` |
  # | `POST   /…/use-cases/:key/deployments/rollback`   | `Deployments.Deployment.:rollback` |
  # | `GET    /…/projects/:project/api-keys`            | `Projects.ApiKey.:for_project` |
  # | `POST   /…/projects/:project/api-keys`            | `Projects.ApiKey.:issue` |
  # | `GET    /orgs/:org/provider-key`                  | `Accounts.ProviderKey.:for_provider` |
  # | `POST   /orgs/:org/provider-key`                  | `Accounts.ProviderKey.:register` |
  #
  # `Project.:create` also creates the 2 default environments, `UseCase.:define` also creates the
  # `default` prompt, and `ApiKey.:issue` returns the raw key exactly once.
  #
  # Not open: organizations this user is not a member of (**404**), and whatever each resource's
  # policies keep closed to people as well (archive, delete, and so on). There is no separate
  # "key-only" layer — permission is exactly that person's membership.
  # ===========================================================================
  scope "/api/v1", PromptOnWeb.API.V1.Management do
    pipe_through :user_token

    get "/me", SessionController, :me
    post "/sessions/revoke", SessionController, :revoke

    get "/orgs", OrgController, :index

    scope "/orgs/:org" do
      get "/", OrgController, :show

      get "/projects", ProjectController, :index
      post "/projects", ProjectController, :create

      # Organization-owned, so outside the project path (one set of BYOK keys per organization).
      get "/provider-key", ProviderKeyController, :show
      post "/provider-key", ProviderKeyController, :create

      scope "/projects/:project" do
        get "/use-cases", UseCaseController, :index
        post "/use-cases", UseCaseController, :create
        get "/use-cases/:key", UseCaseController, :show
        patch "/use-cases/:key", UseCaseController, :update

        post "/use-cases/:key/prompts", PromptController, :create
        post "/use-cases/:key/prompts/:name/versions", PromptController, :commit

        # `/rollback` is an action, not a revision-number slot, so its path does not collide with
        # list/commit.
        get "/use-cases/:key/deployments", DeploymentController, :index
        post "/use-cases/:key/deployments", DeploymentController, :create
        post "/use-cases/:key/deployments/rollback", DeploymentController, :rollback

        get "/models", ModelController, :index
        post "/models", ModelController, :create

        get "/api-keys", ApiKeyController, :index
        post "/api-keys", ApiKeyController, :create
      end
    end
  end

  # Sign-in is **a single 6-digit code sent by email** (ADR 0008, revised 2026-09-03). It is a
  # **controller flow** (`PromptOnWeb.SignInController`), not a LiveView — the code verification
  # request is the very HTTP request that plants the session. ash_authentication's `auth_routes` and
  # `sign_in_route` are not used (`User` has no strategy); only `sign_out_route` (`GET /sign-out`
  # confirmation page + `DELETE /sign-out` → `AuthController.sign_out/2`) remains.
  # There is no sign-up route — signing up is signing in.
  scope "/", PromptOnWeb do
    pipe_through :browser

    # Root: `/personal` when signed in, otherwise `/sign-in` (the public landing page is a separate
    # repo).
    get "/", PageController, :home

    get "/sign-in", SignInController, :show
    post "/sign-in", SignInController, :send_code
    post "/sign-in/verify", SignInController, :verify
    post "/sign-in/resend", SignInController, :resend
    post "/sign-in/reset", SignInController, :reset

    sign_out_route AuthController
  end

  # CLI device approval (`prompton login`). A static top-level path **above** the organization
  # scope; `device` is also in the reserved-word list (`PromptOn.Accounts.ReservedSlugs`).
  #
  # Sign-in is required by a **plug** — a LiveView hook cannot write to the session and so cannot
  # leave a return-to address carrying `?code=` (`PromptOnWeb.Plugs.RequireUserWithReturnTo`). The
  # return-to address lives in the session cookie, and `SignInController.verify/2` reads it once the
  # email code is verified (`PromptOnWeb.UserSession.pop_return_to/2`).
  scope "/", PromptOnWeb do
    pipe_through [:browser, PromptOnWeb.Plugs.RequireUserWithReturnTo]

    ash_authentication_live_session :device_routes,
      on_mount: [{PromptOnWeb.LiveUserAuth, :live_user_required}] do
      live "/device", DeviceLive
    end
  end

  # Account screen — not bound to an organization (it belongs to one user). A static top-level path
  # **above** the organization scope.
  scope "/", PromptOnWeb do
    pipe_through :browser

    ash_authentication_live_session :account_routes,
      on_mount: [{PromptOnWeb.LiveUserAuth, :live_user_required}] do
      live "/account", AccountLive
    end
  end

  # Operations dashboards — **development only** (plan.md §11.5).
  #
  # **This app has no built-in admin UI.** Sign-up is open (sign-up = sign-in, ADR 0008), so
  # "signed-in user" means "anyone" — nothing that reveals application internals goes behind that
  # door. LiveDashboard shows the application environment (vault key, token signing secret) and
  # Oban Web shows every job's arguments, so both are compiled in only when `:dev_routes` is set
  # (`config/dev.exs`). The domains' `AshAdmin.Domain` extension is declarative metadata only, and
  # `ash_admin` is not mounted here (`/admin` survives only as a reserved organization slug, guarded
  # by `PromptOn.Accounts.ReservedSlugs`). `oban` and `dev` stay reserved so an organization can
  # never shadow the development routes.
  if Application.compile_env(:prompton, :dev_routes) do
    scope "/" do
      pipe_through [:browser, :require_authenticated_user]

      oban_dashboard("/oban")
      live_dashboard "/dev/dashboard", metrics: PromptOnWeb.Telemetry
    end

    scope "/dev" do
      pipe_through :browser
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # ---------------------------------------------------------------------------
  # Organization scope — **must come last** (see the order contract above).
  #
  # `:org_slug` is a team organization's globally unique slug or the reserved segment `personal`
  # (= the current user's personal organization). `:project_slug` is unique **only within that
  # organization** — `PromptOnWeb.LiveProjectScope` resolves the pair into
  # `@organization @org_slug @project @projects @envs`.
  scope "/", PromptOnWeb do
    pipe_through :browser

    ash_authentication_live_session :org_routes,
      on_mount: [
        {PromptOnWeb.LiveUserAuth, :live_user_required},
        {PromptOnWeb.LiveProjectScope, :default}
      ] do
      # Organization home = that organization's project list.
      live "/:org_slug", OrgHomeLive

      # Organization-level screens — **must come above `/:org_slug/:project_slug`**. Placed below,
      # `settings`, `members`, and `usage` would be eaten as project slugs. For the same reason
      # these names are also in `PromptOn.Accounts.ReservedSlugs.project_reserved?/1`, and
      # `test/prompt_on/accounts/reserved_slugs_test.exs` enforces that sync.
      live "/:org_slug/settings", OrgSettingsLive
      live "/:org_slug/members", OrgMembersLive
      live "/:org_slug/usage", OrgUsageLive

      # The center of the product is the **use case** — model, prompt, arena, and deployment all
      # live on the single hub screen. (`/playground` `/models` `/deployments` stopped being menu
      # items and screens and folded into the hub.)
      scope "/:org_slug/:project_slug" do
        # Project root = overview. The first item of the sidebar project nav —
        # `/{org}/{project}` was no screen at all until this route existed.
        live "/", ProjectOverviewLive

        live "/use-cases", UseCasesLive

        # The old detail path — only a redirect to the hub remains (for bookmarks and external
        # links).
        live "/use-cases/:key", UseCaseLive
        live "/use-cases/:key/prompt", PromptEditorLive

        # PromptOn SDK keys are **project**-owned (only BYOK provider keys moved up to the
        # organization).
        live "/api-keys", ApiKeysLive
        live "/settings", SettingsLive
      end
    end
  end

  # Redirects to sign-in when there is no current_user after ash_authentication's
  # `load_from_session`.
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Phoenix.Controller.redirect(to: "/sign-in")
      |> Plug.Conn.halt()
    end
  end
end
