# PromptOn server development conventions (`app/`, app `:prompton`, `PromptOn`/`PromptOnWeb`)

The canonical spec is `../plan.md`. **Read the relevant section thoroughly before implementing**
(§2 terminology → §5 domain → §6 API → §7 SDK). The names in that document (resources, actions,
fields, endpoints) are the names in the code. General Phoenix/Elixir rules are in `AGENTS.md`.

Everything committed to this repository — code comments, docs, commit messages, test names — is
written in English.

## Directories
- Module `PromptOn` → `lib/prompt_on/`, `PromptOnWeb` → `lib/prompt_on_web/` (igniter convention —
  not `lib/prompton*`).
- Per domain: `lib/prompt_on/{accounts,projects,catalog,prompts,deployments,observability}/`. The
  domain module is `lib/prompt_on/<domain>.ex`.
- A resource's change/validation/preparation/calculation modules live in
  `lib/prompt_on/<domain>/<resource>/{changes,validations,preparations,calculations}/`.
- Public API controllers: `lib/prompt_on_web/controllers/api/v1/`; plugs:
  `lib/prompt_on_web/plugs/`.
- The SDK is a separate mix project, `../sdk/elixir` (hex `prompton_sdk`, module `PromptOnSDK`). The
  server reuses its pure modules (Resolver/Template/StopKind/SnapshotData) through
  `{:prompton_sdk, path: "../sdk/elixir"}`.
- **License**: the repo is FSL-1.1-ALv2 (`../LICENSE`, Licensor Polimo — Apache-2.0 after 2 years);
  only `../sdk/elixir` is Apache-2.0 (`../sdk/elixir/LICENSE`; the hex package metadata says the
  same). Do not put license headers in new files. The public repo/image are
  `github.com/polimo-dev/prompton` and `ghcr.io/polimo-dev/prompton` (`.github/workflows/`).

## Ash conventions (inherited from HeyDiary, plan.md §5.0)
- **The resource is the single home of domain knowledge**: relationships, calculations, aggregates,
  validations, policies and state transitions are declared on the resource. Service modules only do
  external calls, rendering and hashing.
- **Write actions use domain language** (`:define :commit :fork :rollback :archive :issue :revoke
  :ingest`). CRUD names like `:update`/`:create` are forbidden (`:create` is the exception for
  Project only).
- **ADR 0007 vocabulary**: there are no resources called Variant, Release or Option, and no verb
  "publish". A prompt version is immutable from the moment it is born via `:commit`, and deploying
  is `:commit`ting a `Deployment` revision, which is live right away (rollback = re-committing a
  past revision).
- **ADR 0007 amendment (2026-09-01, "deployments are pins")**: a Deployment revision is a **pin**,
  not a router — it is nothing but
  `{model_id, params, provider_options, prompt_pins: %{prompt name => version_id}}`, and
  **Rule, Target, Condition, weight, A/B and context-dimension routing were all deleted**. At
  request time the only selection axis is the prompt name (`prompt`, default `"default"` — this is
  what language branching is), and **the environment is a request parameter** (`environment`,
  default `"production"`). `Project.dimensions` and `ApiKey.environment_id` were deleted with them
  (an ApiKey is project-scoped). A prompt name that is not pinned is not a silent fallback but
  `{:error, :unknown_prompt}` → 404.
- **ADR 0007 amendment (2026-09-01)**: the use case hub editor has a **single verb, Deploy** — edits
  are **auto-saved** to `Prompt.draft` (a mutable map); there is no "unsaved" state, Save button or
  commit message field, and the immutable `PromptVersion` is minted **only at the moment of Deploy**
  (if the draft equals the latest version, that version is reused). `?v=` is a read-only preview
  plus "Restore this version to draft".
- **Name identities explicitly**; an upsert specifies `upsert_identity` + `upsert_fields` (empty
  list = DO NOTHING).
- Only resources that need a state machine get `AshStateMachine` + an explicit
  **`state_machine do state_attribute :status end`** (no P0 resource has one — immutable revisions
  stand in for state).
- **Tenant = `project_id`**: project-scoped resources use `use Ash.Resource, otp_app: :prompton,
  domain: ..., fragments: [PromptOn.ProjectScoped]` (the fragment supplies the multitenancy
  attribute, `belongs_to :project` and the repo; the resource itself has only
  `postgres do table "..." end`). Outside the tenant:
  User/Token/Organization/Membership/**ProviderKey**/**DeviceAuthorization**/Project/ApiKey.
  (**Amended 2026-09-01**: the BYOK `ProviderKey` is organization-owned —
  `PromptOn.Accounts.ProviderKey` holds `organization_id` directly; no tenant.)
- **Two actors plus the system**: `%PromptOn.Accounts.User{}` (UI **and the management API**),
  `%PromptOn.Projects.ApiKey{}` (public API, `scopes [:resolve, :logs]` — `:resolve` = config-fetch,
  `:logs` = monitoring logs, **project-scoped — no environment binding**). Mix tasks and jobs use
  `%PromptOn.SystemActor{}`.
- **Sign-in is a single 6-digit code sent by email** (user decision 2026-09-03, ADR 0008
  `../docs/adr/0008-email-only-sign-in.md` — it started as a magic link and was amended to a code
  the same day: no link scanners, crossing devices/browsers is fine, no token in the URL). **`User`
  has no ash_authentication strategy** — the extension stays only for session tokens (`tokens`,
  `PromptOn.Accounts.Token`) and `load_from_session`; there is no password or magic link strategy,
  no such action, and nothing uses `hashed_password` (only the column remains, nullable, to be
  dropped in the next release). **Sign-up = sign-in**: when the code is right,
  `PromptOn.Accounts.SignIn.verify/3` finds the user or creates one through the system-actor-only
  `User.:register` (the personal organization is created then as well). Codes are the resource
  `PromptOn.Accounts.SignInCode` (`sign_in_codes` — only the hash `sha256(id <> ":" <> code)` is
  stored, **5 minutes** (`SignInCode.ttl_seconds/0`), **5 attempts** per code, single-use, a new
  request deletes the previous code; `:attempt` locks the row with `FOR UPDATE` while counting and
  **commits** wrong attempts too — a direct `Repo.transaction`, not the generic action's
  `transaction?`; expired rows are swept by the AshOban `:sweep_expired` every 15 minutes on the
  `maintenance` queue). The screens are a **controller, not a LiveView**:
  `PromptOnWeb.SignInController` (`GET/POST /sign-in`, `POST /sign-in/verify|resend|reset`;
  templates `SignInHTML` + `AuthComponents`, `.auth-*` CSS; the pending address is the session's
  `:sign_in_email`) — the session is planted by `PromptOnWeb.UserSession.sign_in/2`
  (`configure_session(renew: true)` blocks session fixation, then `Jwt.token_for_user` +
  `store_in_session` — the same two token lines as the test helper `log_in_user/2`), and the return
  destination is `UserSession.pop_return_to/2` (same-site paths only). Throttling is
  `PromptOn.Accounts.SignInThrottle` — 3 per 10 minutes per requested email, 10 per 10 minutes per
  IP, and 20 per 10 minutes per IP for verification (the IP is `PromptOn.ClientIp.from_conn/1`) — a
  throttled request **is not an error and looks exactly like success**, and a failed verification
  is one sentence that does not distinguish the reason (no existence disclosure). **Never log the
  code** — `config :phoenix, :filter_parameters` contains `"code"` (`sign_in_logging_test`). Mail is
  `PromptOn.Accounts.SignIn.Email` → `PromptOn.Mailer` (prod/dev Resend via `PTN_RESEND_API_KEY`;
  dev without the key uses `/dev/mailbox`; test uses Swoosh Test). ash_authentication_phoenix is
  used only for `sign_out_route` (`AuthController.sign_out/2`). Unattended account creation is
  `Accounts.register_user/2` (seeds, fixtures, `mix prompton.seed_admin --email`). Do not add the
  password or magic link strategies back.
  **`ManagementKey` was deleted on 2026-09-02** (the resource, `Checks.ManagementKeyActor`, the
  plug, every bypass, and the organization settings tab). The management API credential is now a
  **CLI session token** (`PromptOn.Accounts.CliSession` — an ash_authentication user JWT,
  `purpose: "cli"`, no expiry, stored in the `tokens` table → revocable) and the actor is that
  **user**. So there is no provisioning-only permission layer — what a coding AI may do is decided
  entirely by that person's organization/project membership policies. Do not recreate a
  `ManagementKeyActor` bypass on any resource.
- **Policy pattern** (every resource):
  ```elixir
  policies do
    bypass PromptOn.Checks.SystemActor do authorize_if always() end
    # ApiKey reads must be a **bypass** — as a `policy` it would be ANDed with the ProjectMember
    # read policy below and ApiKey would always get an empty result (every policy must pass; only a
    # bypass short-circuits).
    bypass [PromptOn.Checks.ApiKeyActor, action_type(:read)] do
      # Only what an ApiKey may read — and **always pinned to the tenant**
      # (`project_id == ^actor(:project_id)`; for Project itself, `id == ^actor(:project_id)`).
      # Trusting the tenant option alone lets a call that passes another project's id as the
      # tenant straight through.
      authorize_if expr(... and project_id == ^actor(:project_id))
    end
    policy [PromptOn.Checks.ApiKeyActor, action_type([:create, :update, :destroy])] do forbid_if always() end
    # (an action an ApiKey writes with, such as ingest, is allowed for that action only via
    # `PromptOn.Checks.ApiKeyScope, scope: :logs`)
    # An internal-only action is locked with `forbid_if always()` for that action only, and the
    # change that invokes it calls with `PromptOn.SystemActor.new()` (the SystemActor bypass above
    # short-circuits).
    policy action(:internal_only) do forbid_if always() end
    policy action_type(:read) do authorize_if PromptOn.Checks.ProjectMember end
    policy action_type([:create, :update, :destroy]) do authorize_if PromptOn.Checks.ProjectMember end
  end
  ```
  `ProjectMember` is a filter check on `project.organization.memberships.user_id == actor.id`
  (default path `[:project]`). Policies are **AND** — to widen a specific action only, put a
  `bypass action(...)` in front of the catch-all forbid.
- Validation errors are `Ash.Error.Changes.InvalidAttribute.exception(field:, message:)` (returning
  a keyword list becomes Unknown).
- Inside an embedded resource module, do not use the module's own struct literal (`%__MODULE__{}`)
  (compile order) — use `struct(__MODULE__, ...)`.
- Every PK is `uuid_v7_primary_key :id` (only User uses the ash_authentication default uuid).
- `@raw_string [allow_empty?: true, trim?: false]` — put it on string attributes whose raw text is
  the contract, such as prompts and keys.
- code_interface `define`s are gathered in the domain module. Domains are
  `extensions: [AshAdmin.Domain]` + `admin do show? true end` — declarative metadata only, and
  **`ash_admin` is not mounted in the router** (2026-09-03: sign-up is open, so "signed-in user" =
  anyone. `/admin` survives only as a reserved word in `ReservedSlugs` — `admin_route_test`). Do not
  mount it again.
- **Supervision tree mode** `config :prompton, :mode` (`PTN_MODE`,
  `PromptOn.Application.children/1`): `:server` (default, everything) / `:library` (Repo, Vault and
  PubSub only — for when another OTP app pulls in `:prompton` as a dependency or a script uses only
  the domain. The config keys that side has to fill in are in the repo root `README.md`, "Embedding"
  section). New supervision tree children go in `children(:server)`, and a module that must work
  without that process (caches etc.) is written to tolerate the missing ETS table. The `:library`
  contract is locked by `application_test`.

## Tests
- `use PromptOn.DataCase, async: true`; fixtures: `PromptOn.Fixtures` (`test/support/fixtures.ex`):
  `user_fixture/1` (email only — `:register`; a signed-in state comes from
  `PromptOnWeb.ConnCase.log_in_user/2`, which mints the session token directly), `project_fixture/1`
  (includes the production/staging environments), `api_key_fixture/2` → `{key, raw}`
  (project-scoped), `scope(project, actor)` → `[tenant:, actor:]`, `deployment_fixture/4`
  (`%{model_id:, params:, provider_options:, prompt_pins:}`) and `simple_deployment_fixture/3`,
  `ingest_fixture/3` (`env:` picks the environment), `heydiary_project_fixture/1` (only
  `diary_generation` has two prompts — `default`/`ko`). Fixtures for a new domain are **added** to
  this module.
- Policy tests use three actors: member, non-member and ApiKey.
- Migrations are generated only with `mix ash.codegen <name>` (never written by hand).
  `mix ash.setup`, then `mix test`.
- `MIX_TEST_PARTITION=<name>` separates the test DB (`prompton_test<name>`).
- Management API tests go **entirely over HTTP** with `PromptOn.Fixtures.cli_token_fixture/1`
  (user → CLI session token) + `PromptOnWeb.ManagementAPI` (`api_get/api_post/api_patch`).

## Public API (plan.md §6)
- Pipeline `:api` = `PromptOnWeb.Plugs.ApiKeyAuth` (Bearer → ApiKey actor + tenant). **The plug does
  not decide the environment** — the controller picks it with
  `PromptOnWeb.API.V1.RequestEnvironment.fetch/2` (parameter `environment`, default `"production"`).
- **There are only three public API endpoints, and PromptOn does not sit on the app's request path**
  (amended 2026-09-01, ADR 0007 amendment "proxy mode removed"): config-fetch `GET /snapshot` and
  `POST /resolve` (scope `:resolve`), and monitoring logs `POST /generations` (scope `:logs`). The
  app receives the config and calls the provider **directly with its own provider key**. Proxy mode
  (`POST /generate`, `PromptOn.Proxy`) was deleted; the only places where the server calls an LLM
  itself are the arena and AI drafts (`PromptOn.LLM`). Only `GET /snapshot` goes through
  `PromptOn.Deployments.SnapshotCache` (per-environment ETS, 5-second TTL); `POST /resolve` is the
  smoke test right after a deploy and is not cached.
- The error envelope is `PromptOnWeb.API.V1.FallbackController` (`action_fallback`) —
  `{:error, {:invalid_request, msg}}` and the like.
- Response JSON keys are snake_case strings; ids are UUID strings without a prefix.
- **The prefix is `ptn`** (renamed 2026-09-03, formerly `pon`): a raw runtime key is
  `ptn_<project_slug>_<random32>` (`ApiKey.Changes.GenerateKey`), operational environment variables
  are `PTN_*` (`ptn_env` in `config/runtime.exs` — `PON_*` is a fallback to be dropped after one
  release). Authentication compares sha256 hashes, so already-issued `pon_…` keys keep working — do
  not write code that inspects the prefix string.

## Management API (agent-first-spec batches ② and ③, `../docs/management-api.md`)
- Pipeline `:user_token` = `PromptOnWeb.Plugs.UserTokenAuth` (Bearer CLI session token → **User**
  actor) + `PromptOnWeb.Plugs.ManagementOrgScope` (path `:org` → `conn.assigns.organization`).
  **Neither the tenant nor the organization is decided by the credential** — a user belongs to
  several organizations, so the organization is picked by `/api/v1/orgs/:org/…` (`:org` = a team
  organization's slug or the reserved segment `personal`) and the project by the path beneath it.
  `PromptOnWeb.API.V1.Management.Scope` produces `[tenant: project.id, actor: user]` per request.
  The two layers cannot open each other's doors (a runtime key on a management path → 401, and the
  reverse → 401). A browser session token (`purpose: "user"`) is 401 as well — the management API
  accepts only `"cli"` tokens.
- Controllers are in `lib/prompt_on_web/controllers/api/v1/management/` (`Session` (= `/me` and
  `/sessions/revoke`), `Org`, `Project`, `UseCase`, `Prompt`, `Model`, `Deployment`, `ApiKey`,
  `ProviderKey`). Shared modules next to them: `Scope` (resolves user/organization/project/use
  case/environment), `Params` (checks the body's **shape only**, ignores unknown keys), `JSON`
  (serialization; strips `?`, e.g. `personal?` → `"personal"`), `ModelSetup` (registration + pricing
  enrichment from the OpenRouter public list; failures are swallowed), `Halt` (the 401/404 renderer
  plugs use — a plug cannot go through `action_fallback`).
- **Device login** (batch ③) is the unauthenticated pipeline `:device`: `POST /api/v1/device/code`
  and `/device/token` (`PromptOnWeb.API.V1.DeviceController`; the four RFC 8628 codes are the
  `{:device, code, msg}` clause of FallbackController), with the approval screen at `/device`
  (`PromptOnWeb.DeviceLive`). The resource is `PromptOn.Accounts.DeviceAuthorization`. Being
  unauthenticated, it carries a **per-IP rate limit** (`PromptOnWeb.Plugs.RateLimit` + Hammer ETS —
  counted separately on each node; the client IP is resolved by the endpoint's `RemoteIp`, which
  reads **only `x-forwarded-for`** — RemoteIp never looks at the peer and trusts headers alone, so
  letting it read `x-client-ip`/`forwarded`, which Traefik does not overwrite, would let the client
  pick its bucket; over the limit is 429 `rate_limited` + `retry-after`) — the test suite lifts the
  limits in `config/test.exs` and only the 429 contract test tightens them briefly. Expired requests
  are deleted by the AshOban schedule `:sweep_expired` (15 minutes, `maintenance` queue), but the
  CLI token of a request that was approved and never collected is **revoked** before deletion.
- **Three ways to revoke sessions**: `prompton logout` = that one token (`CliSession.revoke/1`);
  "Logged-in devices" on the account screen `/account` = the chosen jti (`CliSession.revoke_jti/2`;
  the list is `CliSession.list/1` — device name and last-used time live in `tokens.extra_data`); and
  **"Sign out everywhere" on the same screen = all of them**
  (`PromptOn.Accounts.Sessions.revoke_all/2`, sparing only the `except:` jti of the browser that
  clicked — `#account-sign-out-everywhere`). Without passwords there is no "password change =
  revoke everything"; ash_authentication's `log_out_everywhere` add-on is not used either.
- **Addresses are names**: `:org` = organization slug or `personal`, `:project` = project slug,
  `:key` = use case key, `:name` = prompt name, `environment` = environment slug. UUIDs appear only
  for the model and prompt version a deployment pin points at.
- **Responses are bare objects** (as in the public API). A list is an object with one plural key
  (`{"projects": [...]}`).
- **Idempotency is a 409**: re-creating an existing project/use case/prompt/model/provider key is
  409, with that resource in `details` (`{:error, {:conflict, msg, details}}` →
  FallbackController). Anything in an organization the user is not a member of is **404**, not 403
  (existence is not disclosed).
- A deployment revision has no commit message field (ADR 0007) — the endpoints do not accept one
  either.
- When adding an endpoint, update the router's `endpoint → domain action` table and
  `docs/management-api.md` together.

## UI (LiveView)
- **URLs are `/{org_slug}/{project_slug}/...`** (amended 2026-09-01). `org_slug` is either a team
  organization's globally unique slug or the reserved segment `personal` (= the current user's
  personal organization, which has no slug). Project slugs are unique **per organization**. The root
  `/` goes to `/personal`, and the organization home `/{org}` is that organization's project list.
  The router declares **static paths first** and opens the organization scope last — the reserved
  words are kept in sync with the router by `PromptOn.Accounts.ReservedSlugs` (`device` is on that
  list too. The word shown to users is "organization"; "workspace" is never used).
- **The IA is use-case-centric** (plan.md §10.1, amended 2026-08-29). There are four project screens
  (amended 2026-09-01): `/{org}/{project}` (**overview** — generations/errors/tokens/cost per
  period, use case count and whether deployed, live deployments per environment),
  `/{org}/{project}/use-cases` (list) + `/{org}/{project}/use-cases/:key/prompt` (**use case
  hub** — model picker, prompt editor, arena, Deploy, `?tab=deployments`),
  `/{org}/{project}/api-keys` (issue/revoke PromptOn SDK keys + SDK setup),
  `/{org}/{project}/settings` (environments, deletion).
  The sidebar project nav is the four entries **Overview, Use cases, API keys, Settings**, and
  project Settings has **no tabs**. Playground, Models and Deployments are neither screens nor menu
  entries (the hub absorbed them) — a model is registered the moment the hub's searchable picker
  selects it. `/use-cases/:key` is a redirect to the hub.
- **The sidebar is the hierarchy itself** (amended 2026-09-01, `PromptOnWeb.Layouts`): top = the
  current organization (`#org-menu` popup — Projects, Members, Usage, Organization settings + the
  organization switch list + New organization), middle = the project (switcher + the four screens
  above), bottom = the account (`#user-menu` popup — Account settings, Sign out). The collapse
  toggle (`#sidebar-toggle`) is a small icon at the right of the organization row, and its state is
  `localStorage["pon:sidebar"]` + `<html>.sidebar-collapsed` (not URL state). A new sidebar entry
  attaches to **its own layer** among the three popups.
- **Organization screens** (amended 2026-09-02): `/{org}` (project list), `/{org}/settings`
  (General + **Provider Keys** only — the "Management keys" tab was deleted along with the keys.
  Coding AIs/CLIs get a person's CLI session token via `prompton login` (→ `/device`)),
  `/{org}/members` (read-only), `/{org}/usage` (generations/errors/tokens/cost per project,
  `?period=`). The top-level `/account` is outside any organization (email, logged-in devices, sign
  out, Sign out everywhere — no password field). **The one place to enter BYOK provider keys is
  `/{org}/settings?tab=providers`** — project Settings has no providers tab, and the use case hub's
  model picker and AI drafts only give a link to that screen when there is no key (the inline key
  input inside the picker was removed). What stays in project Settings is only the project's own
  (environments, deletion), and PromptOn SDK keys have their own screen at
  `/{org}/{project}/api-keys`. The organization scope's static second segments (`settings`
  `members` `usage`) are declared **above** `/:org_slug/:project_slug` and added to
  `PromptOn.Accounts.ReservedSlugs.project_reserved?/1`. The project scope's static third segments
  (`api-keys` `use-cases` `settings`) are guarded by the same list — the `/{org}/{project}` root is
  the overview screen.
- `design/mockup/` is a **visual reference**, not a pixel contract — follow its colors and spacing,
  but do not build a screen just because the mockup has it.
- **Do not build UI for features the backend does not support (dead buttons, session-only state,
  columns that are always `—`)** — attach the UI when the feature arrives.

## Zero-downtime deployment discipline (ADR 0005 — hard rules)
- **expand/contract is still the rule.** A destructive migration was allowed exactly once, for the
  ADR 0007 cutover (2026-08-28) (no production + agreement to discard the dev DB); **it applies
  again from the next schema change on**.
- **Migrations are expand/contract**: during a rolling deploy, old code runs on the new schema.
  Column additions are nullable/default; deletions, renames and type changes are deferred to "the
  release after nothing uses it anymore". Adding NOT NULL is (1) add nullable + backfill → (2)
  constrain in the next release. Consider `concurrently` for indexes (ash_postgres
  `concurrently: true`).
- **LiveView state goes in the URL**: meaningful UI state — tabs, the selected item, the target of
  an open drawer/modal, filters, the version the editor targets — rides in the URL as `push_patch`
  query parameters. When a deploy drops the socket and the view remounts, the user must come back to
  the same screen. Forms being typed into are left to Phoenix form recovery (stable DOM ids +
  phx-change).
- `/health/ready` includes the migration gate — do not weaken the readiness logic.

## Before finishing
`mix format`, `mix compile --warnings-as-errors`, `mix test`, `mix credo --strict` (when possible).
Do not leave placeholders/TODOs behind.
