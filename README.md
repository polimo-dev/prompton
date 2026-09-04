# PromptOn

PromptOn is a **control plane for an app's LLM prompts**. For every use case (one per LLM call site)
and every environment it holds one **pin** — prompt version(s) + one model + params — and the app
fetches that pin and calls the provider itself.

- **Config-fetch, not a proxy.** The app reads its pin (`GET /api/v1/snapshot`, cached and polled
  with ETags, or `POST /api/v1/resolve`) and then calls the LLM provider with its **own** key and its
  **own** HTTP client. PromptOn is never in the request path and never sees the provider key; an
  outage costs the app nothing but fresher config.
- **Monitoring logs.** After each provider call the app sends a batched `POST /api/v1/generations`
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
| `app/` | The Phoenix + Ash application: web UI, runtime API (`/api/v1/snapshot`, `/resolve`, `/generations`), management API (`/api/v1/me`, `/api/v1/orgs/…`), device login. Conventions in `app/CLAUDE.md` and `app/AGENTS.md`. |

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
| `PTN_MODE` | no | `server` (default) \| `library` — start only the data layer (Repo, vault, PubSub; no endpoint, no Oban), for embedding the domain in another OTP app or running scripts. In `library` mode `PTN_SECRET_KEY_BASE` and `PTN_PHX_HOST` are not required. See [Embedding](#embedding). |
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

## Embedding

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
