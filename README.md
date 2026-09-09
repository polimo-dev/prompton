# PromptOn

PromptOn is a **control plane for an app's LLM prompts**. For every use case (one per LLM call site)
and every environment it holds one **pin** — prompt version(s) + one model + params — and the app
fetches that pin and calls the provider itself.

- **Config-fetch, not a proxy.** The app reads its pin (`GET /api/v1/use-cases`, cached and polled
  with ETags, or `POST /api/v1/use-cases/:key/prompt`) and then calls the LLM provider with its
  **own** key and its **own** HTTP client. PromptOn is never in the request path and never sees the
  provider key; an outage costs the app nothing but fresher config.
- **Monitoring logs.** After each provider call the app sends a batched `POST /api/v1/logs`
  (successes and failures) — model, prompt version, tokens, cost, latency, input/output.
- **Change without deploying.** Prompt versions are immutable, a deployment revision is a pin, and
  rollback is re-pinning a previous revision. Compare candidates side by side in the arena first.
- **Agent-first.** The whole integration contract is one page a coding agent can read —
  [`/docs/agent`](https://docs.prompton.ai/agent) — and the landing page is a single prompt to paste
  into Claude Code, Codex, or whatever you use: the agent installs the
  [CLI](https://github.com/polimo-dev/prompton-cli), logs in via device flow (a human approves), provisions
  use cases from your call sites, and replaces each call with config-fetch + a log.

Hosted at [app.prompton.ai](https://app.prompton.ai) · docs at [docs.prompton.ai](https://docs.prompton.ai) ·
CLI at [polimo-dev/prompton-cli](https://github.com/polimo-dev/prompton-cli).

## Repository layout

| path | what |
|---|---|
| `app/` | The Phoenix + Ash application: web UI, runtime API (`/api/v1/use-cases`, `/use-cases/:key/prompt`, `/logs`), management API (`/api/v1/me`, `/api/v1/orgs/…`), device login. Conventions in `app/CLAUDE.md` and `app/AGENTS.md`. |
| `scripts/`, `Makefile` | Worktree lifecycle helpers and the primary-only dev deployment command. |
| `.worktrees/` | Additional Git checkouts, ignored by Git and Docker. The primary checkout stays in place. |

## Worktrees

The existing checkout (`~/ws/prompton` locally) remains the **primary checkout**, matching
HeyDiary's layout. Additional worktrees live under `.worktrees/<name>`; this is not a bare-repo
migration. `app/` and the separate SDK, CLI, home, docs and admin repositories stay where they are.

Run these commands from the primary repository root:

```sh
make worktree name=prompt-editor          # new branch from local main
make worktree name=fix-editor from=main   # choose a starting branch, tag or commit
make worktree name=existing-branch       # reuse an existing local branch unchanged
make worktree-list
make worktree-rm name=prompt-editor       # remove only the worktree; keep its branch
```

Names may include slashes, such as `name=feature/prompt-editor`. For an existing branch, `from`
is ignored. New worktrees start from committed history: uncommitted primary edits and ignored
files (including `.env`, local agent notes, dependencies and build artifacts) are not copied.
The helpers reject linked-checkout lifecycle commands, invalid paths and symlinked destinations.

### Working in a checkout

- Each checkout owns its own `app/deps/`, `app/_build/` and generated assets. Run `mix deps.get`
  from its `app/` directory, then the usual setup/check commands as needed. Do not symlink these
  directories to the primary checkout; branches can have different dependency locks and code.
- Local environment files are optional; dev/test have default secrets. Add only the local values
  you need, rather than copying production credentials. Local private agent notes do not follow
  Git either; `app/AGENTS.md` and `app/CLAUDE.md` remain available in every checkout.
- Worktrees isolate files, **not the database**. The default dev database is still `prompton_dev`;
  `mix setup` applies migrations and seeds there. Do not run conflicting schema work against that
  shared database. `PTN_DATABASE_URL` currently overrides the database only in production mode.
- For simultaneous local servers, use distinct ports, e.g. `PORT=4101 mix phx.server`. For
  simultaneous test runs, use distinct partitions, e.g. `MIX_TEST_PARTITION=_editor mix test`
  (database `prompton_test_editor`) or `MIX_TEST_PARTITION=_editor mix precommit`.
- Git and ripgrep skip `.worktrees/`. Other recursive tools need an explicit exclusion to avoid
  searching every checkout. Docker excludes worktrees from the root build context too.
- Removal uses native `git worktree remove` without force: modified, untracked or locked worktrees
  are refused. Ignored files such as `.env` and build output **are removed**, so save anything you
  need first. The primary checkout is never a removal target, and branches are not deleted.
- Once these tooling changes are committed, new worktrees contain the same root Makefile. Until
  then, run lifecycle commands from the primary checkout; uncommitted tooling does not follow Git.

### Dev deployment

Merge the intended changes into the primary checkout before running `make dev-deploy` there.
The command refuses linked worktrees, builds with the repository root as Docker context, inspects
the resulting image, and rolls only the `prompton` server Deployment in the `prompton` namespace.
Docker and Kubernetes are explicitly pinned to the `orbstack` context; nothing is pushed or sent
to production. The landing/docs/admin deployments are separate and are not changed by this command.
Manifests remain in the deployment repository (`deployment/macmini/prompton/`).

`make test-worktrees` checks lifecycle/path safety and deployment ordering in disposable Git
repositories with Docker/Kubernetes mocked; it never deploys anything.

## Members and invitations

Open an organization's **Members** page to invite people by email, choose a role and select their
projects. The recipient signs in with the invited email address, then clicks **Join** on the
invitation page. Opening the email link does not accept it. Links expire after seven days, are
single-use, and can be revoked from Members. Only a hash of the invitation token is stored.
Invitations use the same mail adapter and `PTN_MAIL_FROM` as sign-in codes; local development can
inspect them in `/dev/mailbox`.

| Role | Access |
|---|---|
| `member` | All operations in assigned projects except deleting a project. New projects they create grant access automatically. They can invite other members only to projects they created. |
| `admin` | All projects and organization settings, invitations and member-to-admin promotion. Cannot remove or demote another admin. |
| `owner` | All admin capabilities, including admin removal/demotion, organization deletion and ownership transfer to an existing member. The previous owner becomes an admin. |

Membership and project permissions apply to the browser and management API. A project grant alone
does not grant access after its organization membership is removed. Invitation acceptance checks
current inviter permissions and the organization's member limit again.

Personal organizations have one owner and use `/personal`. Convert one to a team organization by
claiming a URL in **Organization settings** before inviting people, transferring ownership or
deleting it. Team organization deletion requires typing its name; ownership transfer requires an
explicit confirmation. Existing plan limits continue to apply.

## Self-hosting

The container image is `ghcr.io/polimo-dev/prompton` (tags: `main`, `sha-<commit>`, and `X.Y.Z` / `X.Y` /
`latest` from `vX.Y.Z` releases; linux/amd64 and linux/arm64). It needs
PostgreSQL 18 and an outbound route to [Resend](https://resend.com) for sign-in emails (sign-in is a
6-digit code sent by email — there are no passwords).

| variable | required | meaning |
|---|---|---|
| `PTN_DATABASE_URL` | yes | `ecto://USER:PASS@HOST/DATABASE` |
| `PTN_SECRET_KEY_BASE` | yes | Cookie/session signing (`mix phx.gen.secret`) |
| `PTN_TOKEN_SIGNING_SECRET` | yes | Signs user session and CLI tokens |
| `PTN_VAULT_KEY` | yes | Base64 32-byte key encrypting provider keys and log payloads at rest (`openssl rand -base64 32`) |
| `PTN_PHX_HOST` | yes | Public hostname used to build URLs (e.g. `app.example.com`) |
| `PTN_RESEND_API_KEY` | yes | Resend API key for sign-in code emails (the sending domain must be verified) |
| `PTN_MAIL_FROM` | no | Sender, default `PromptOn <noreply@prompton.ai>` |
| `PTN_DOCS_URL` | no | If set, `/docs/agent` redirects there instead of serving the built-in copy |
| `PTN_OPENROUTER_API_KEY` | no | Fallback OpenRouter key for the arena/AI draft until an organization registers its own |
| `PTN_MODE` | no | `server` (default) \| `library` — start only the data layer (Repo, vault, PubSub; no endpoint, no Oban), for running the domain inside another OTP app or scripts. In `library` mode `PTN_SECRET_KEY_BASE` and `PTN_PHX_HOST` are not required. See [Library mode](#library-mode). |
| `PTN_POOL_SIZE`, `PORT`, `ECTO_IPV6`, `DNS_CLUSTER_QUERY` | no | Pool size (10), HTTP port (4000), IPv6 DB socket, DNS clustering |

See `app/config/runtime.exs` for the full list (the old `PON_*` prefix is still read as a deprecated
fallback for one release). Migrations are applied by the release task — run it once per deploy, before
the new server starts (in Kubernetes, as an init container):

```sh
docker run --rm --env-file prompton.env ghcr.io/polimo-dev/prompton:main \
  bin/prompton eval "PromptOn.ReleaseTasks.migrate()"
docker run -d -p 4000:4000 --env-file prompton.env ghcr.io/polimo-dev/prompton:main
```

`GET /health` is liveness, `GET /health/ready` is readiness (DB + migration gate). Accounts are created
on first sign-in; to pre-create one: `bin/prompton eval 'PromptOn.ReleaseTasks.seed_admin("you@example.com")'`.

## Local development

Requires Elixir 1.20 / OTP 29 (the versions in `app/Dockerfile`) and PostgreSQL on `localhost`
with `postgres` / `password` (see `app/config/dev.exs`).

```sh
cd app
cp .env.example .env     # dev and test fall back to fixed secrets; the Resend key is optional
mix setup                # deps, database + migrations + seeds, assets
mix phx.server           # http://localhost:4000 — sign-in codes land in /dev/mailbox without a Resend key
mix test
mix precommit            # compile --warnings-as-errors, format, credo --strict, ash.codegen --check, test

```

The Elixir SDK (`prompton_sdk`, module `PromptOnSDK`) lives in its own repository,
[prompton-elixir](https://github.com/polimo-dev/prompton-elixir); the server depends on it as a git
dependency pinned to a commit in `app/mix.exs`. The Docker build context is the repository root:
`docker build -f app/Dockerfile .`. CI (`.github/workflows/ci.yml`)
runs the same checks; `image.yml` publishes the image on pushes to `main` and on `v*` tags.

## Library Mode

The Ash domains (`PromptOn.Accounts`, `PromptOn.Projects`, `PromptOn.Catalog`, `PromptOn.Prompts`,
`PromptOn.Deployments`, `PromptOn.Observability`) can be used from another OTP application or a
script without the web layer: depend on `app/` and run it in **library mode**, which starts only
`PromptOn.Repo`, `PromptOn.Vault` and `Phoenix.PubSub` — no endpoint, no Oban, no caches, no
telemetry (`PromptOn.Application.children/1`). Call the domain code interfaces with an actor of your
choosing; `PromptOn.SystemActor.new()` bypasses policies, a `%PromptOn.Accounts.User{}` is subject to them.

```elixir
# mix.exs
{:prompton, path: "../prompton/app"}
```

Mix loads configuration per project, so **none of `app/config/*.exs` applies** — the consuming
project must set these itself (compile-time `config/config.exs` unless noted):

| key | value |
|---|---|
| `config :prompton, :mode` | `:library` |
| `config :prompton, :ash_domains` | The six domains above, verbatim. Read at compile time (Ash's domain/resource inclusion check) and at runtime (token verification walks it). |
| `config :prompton, PromptOn.Repo` | Same database as the server: `url:` or `hostname`/`username`/`password`/`database`, plus `pool_size`. Runtime config is fine. |
| `config :prompton, PromptOn.Vault` | `ciphers: [default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(vault_key)}]` with the server's `PTN_VAULT_KEY` — otherwise encrypted columns (provider keys, log payloads) cannot be read or written. Runtime config is fine. |
| `config :prompton, :token_signing_secret` | The server's `PTN_TOKEN_SIGNING_SECRET`, if you mint or verify session/CLI tokens (`PromptOn.Accounts.CliSession`). Runtime config is fine. |
| `config :ash, ...` | Copy the whole `config :ash` block from `app/config/config.exs`. Several of these flags are read while the resources compile, so a different value compiles different resources. |
| `config :ash_oban, pro?: false` | As in `app/config/config.exs`. |
| `config :swoosh, api_client: false` | Swoosh's default API client is Hackney, which the server does not depend on — without this the `swoosh` application fails to start (`missing hackney dependency`). Use `Swoosh.ApiClient.Req` instead only if you actually send mail. |
| `config :prompton, ecto_repos: [PromptOn.Repo]` | Optional — only for `mix ecto.*` tasks from the consuming project. |

| `config :prompton, :entitlements_plan_override` | Optional. `nil` (default) applies the organization's own plan; `:free \| :team \| :pro` makes `PromptOn.Entitlements` report that plan for every organization — the switch for a self-hosted install where per-organization plan limits (projects, use cases, log retention, members) should not apply. |

Optional, only when the corresponding feature is called: `config :prompton, :llm_adapter` and
`:openrouter_api_key` (arena / AI draft), `config :prompton, PromptOn.Mailer` and `:mail_from`
(sign-in emails). Rate-limited flows (sign-in codes, device login) belong to the server and are not
available in library mode.

Migrations are not run for you — the schema is owned by the server (`mix ash.setup` or
`PromptOn.ReleaseTasks.migrate/0`). The same `PTN_MODE=library` switch works for the server's own
`mix run` / `bin/prompton eval` when a script only needs the data layer.

```elixir
# mix run -e '...' in the consuming project
{:ok, orgs} = PromptOn.Accounts.list_organizations(actor: PromptOn.SystemActor.new())
```

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Every commit must carry a
Developer Certificate of Origin sign-off (`git commit -s`), and contributions are licensed under the
license of the directory they land in.

## License

- This repository is licensed under the **Functional Source License, Version 1.1, Apache 2.0 Future
  License (FSL-1.1-ALv2)** — see [LICENSE](LICENSE). Each version becomes Apache-2.0 two years after
  its release. Licensor: Polimo.
- The SDKs live in their own repositories ([prompton-elixir](https://github.com/polimo-dev/prompton-elixir)
  and the other `prompton-<language>` repositories) under the **Apache License 2.0**, so apps can
  depend on them without any FSL condition.

## Trademark

PromptOn is a trademark of Polimo. The license does not grant permission to use the PromptOn name or
logo; forks and derived services must use a different name.
