# PromptOn — integration reference for coding agents

This page is the whole contract. Everything an agent needs to move an app's LLM calls onto PromptOn is here: the CLI, the REST equivalents, the runtime API, and the rules. `<host>` below is the PromptOn instance that served this page.

## 0. What PromptOn is

- A **control plane** for prompts and models: per use case and per environment it holds one **pin** = prompt version(s) + one model + params.
- **Config-fetch, not a proxy.** The app fetches the pin (`GET /api/v1/snapshot` or `POST /api/v1/resolve`) and then calls the LLM provider **itself, with its own provider key and its own HTTP client**. PromptOn is never in the request path and never sees the provider key.
- **Monitoring logs** are batched `POST /api/v1/generations` calls the app sends after each provider call (successes and failures).
- Two credentials, two doors: a **CLI session token** (from `prompton login`, a human's identity) provisions things under `/api/v1/me` and `/api/v1/orgs/…`; a **runtime API key** (`ptn_<project_slug>_…`, one per project) reads config and sends logs. Neither opens the other door (401).
- Hierarchy: Organization (`personal` or a team slug) → Project (environments `production`, `staging`) → Use case (one per LLM call site) → prompts by name (`default`, `ko`, …) → immutable versions → deployment revisions (pins).

### What to tell the human

Step 1 of the journey below is to explain PromptOn in a few sentences. Paraphrase this in the human's own vocabulary — do not read the bullet list above out loud, and do not paste this block verbatim:

> PromptOn is a control plane for the prompts and models your app uses. Every place your code calls an LLM becomes a **use case**, and for each use case and environment PromptOn holds one **pin**: a prompt version, one model, and its parameters. Your app fetches that configuration and then calls the provider itself, with your own provider key and your own HTTP client — PromptOn is config-fetch, **not a proxy**, so it is never in the request path and never sees your key. After each call your app sends back a **monitoring log**, and those logs are how you see cost, latency, error rate and stop reasons per use case. When a new model comes out you point a staging pin at it, watch it on real traffic in the logs, and then move the production pin — no redeploy, no code change, and a rollback is one command. Your prompts end up versioned in PromptOn; your provider keys, your HTTP calls and your application logic stay exactly where they are.

## 1. The journey

Seven steps, matching the seven numbered lines of the prompt the human pasted. Work them in order. Four of them — 2, 3, 5 and 6 — contain a **STOP**: which project to migrate, whether you can edit at all, the not-a-fit and borderline verdicts, approval of the plan, and the not-a-git-repository question. Do not carry on past a stop until the human answers.

### Step 1 — tell the human what PromptOn is

Before touching the filesystem, before installing anything: three to five sentences from the script in §0. Then go straight on to step 2; this step has no stop.

### Step 2 — confirm you can see the project's code

Prove it, do not assume it. List the working directory, find the repository root, and read the manifest that names the project (`package.json`, `pyproject.toml` / `requirements.txt`, `go.mod`, `mix.exs`, `Gemfile`, `pom.xml` / `build.gradle`, `Cargo.toml`, `composer.json`). Say which project you found, and where.

| situation | what to do |
|---|---|
| exactly one project in reach | name it (path + language + framework) and go on to step 3 |
| several projects in reach (a monorepo with independent services, several checked-out repositories, several workspace folders) | run the step 3 search across all of them **first** — it is a grep, it costs nothing — then list them **with the number of server-side LLM call sites found in each** and ask which app to migrate. **STOP** until the human picks. Never ask them to choose blind: a human who picks the one service that makes no LLM calls gets a false "not a fit" |
| you can read the code but cannot write it (a repository browser, an uploaded archive, a read-only checkout, a review-only sandbox) | say so now, before anything is installed: you can do steps 1–5 (explain, fit check, plan) but not step 6. Ask whether they want the analysis and the plan only, or would rather rerun this prompt in an AI that can edit the repository. **STOP** until they answer |
| no code in reach (a chat window with no filesystem, an empty directory, read-only web access) | say: *"I can't see your project's code from here. Paste this same prompt into an AI that runs inside your codebase — Claude Code, Codex, Cursor, or your IDE's agent — and it will take it from there."* **STOP.** Do not install the CLI, do not create anything in PromptOn, do not guess at the code |

### Step 3 — check the fit

PromptOn is for an app whose **server** calls LLM providers for **several use cases**, each with its own prompt and its own model/params. Establish that from the code before anyone signs up for anything.

Search the codebase for provider SDKs and for raw HTTP to provider hosts: `openai`, `anthropic`, `openrouter`, `groq`, `google`/`genai`/`vertex`, `@google/generative-ai`, `bedrock` / `boto3` / `bedrock-runtime`, `AzureOpenAI`, `mistral`, `cohere`, `ollama`, `litellm`, `langchain`, `llamaindex`, `instructor`, and the Vercel AI SDK — whose imports are `from "ai"` and `@ai-sdk/openai`, not `vercel/ai`. Hosts: `api.openai.com`, `api.anthropic.com`, `openrouter.ai/api`, `api.groq.com`, `generativelanguage.googleapis.com`, `*.openai.azure.com`. An empty grep is not a verdict: before concluding there are no calls, also search for model id strings (`gpt-`, `claude-`, `gemini-`, `llama-`) and for the app's own wrapper names (`llm`, `completion`, `prompt`). Follow each hit to the call site. For each call site record:

| collect | becomes |
|---|---|
| a stable snake_case name for the call site (`diary_generation`) | use case `key` (cannot change later) |
| chat messages vs a single string vs an embedding call | `kind`: `chat` \| `text` \| `embedding` |
| every value interpolated into the prompt (f-strings, template placeholders, string concatenation) | `input_schema` variables and `{{ name }}` placeholders |
| language/tone/tenant variants of the same prompt | prompt names (`default`, `ko`, …) |
| the model id string and the params (`temperature`, `max_tokens`, …) | `model` and `params` of the deployment pin |
| where the prompt text lives today (hard-coded string, config file, database row, prompt-management SaaS, env var) | the "current state" section of the migration plan |
| whether the call runs on the server or in a browser / mobile client | fit, and whether the runtime key is safe there |
| the provider key and the HTTP client | **stay in the app** |

Decide **server vs browser from the file, not from the import** — the same `openai` import means opposite things in the same repository. In Next.js, `app/api/**/route.ts`, a `"use server"` action, `getServerSideProps` and middleware are server; a file with `"use client"` at the top, a key read from `NEXT_PUBLIC_*`, or `dangerouslyAllowBrowser: true` is the browser. In a mobile app, a call made on the device is a client call however the SDK is named.

Show the human the table you filled in, then give a verdict:

| what you found | verdict | what to do |
|---|---|---|
| two or more **server-side** call sites, each with its own prompt (usually its own model and params too) | **fit** | say so and go on to step 4 |
| exactly one server-side call site | **borderline — the human decides** | say it plainly: with one use case PromptOn still buys versioned prompts, a model you can change without a redeploy, and per-call monitoring, but it is a control plane for one thing. Ask whether they want to go ahead. **STOP** until they answer |
| no LLM calls on the server at all | **not a fit** | say so, explain that PromptOn configures server-side provider calls and there are none here, and **STOP** |
| every LLM call is made from a browser or a mobile client | **not a fit** | say so: the runtime key is a server-side credential and must never ship to a client, so there is nothing here for PromptOn to configure. Offer the fix rather than just the verdict — move the call behind a route handler of their own and PromptOn fits that. **STOP** |

**Count across the whole app.** Every service that ships as part of the same deployed app counts into one total: two services with one call each is a **fit**, not two borderline cases. Separate products that ship and scale independently are counted, and later provisioned, separately (§1, step 6b).

Notes that do not change the verdict but belong in the plan: prompts already living in a database or a prompt SaaS are still a migration (§1, step 5); a single call site that fans out into several genuinely different prompts (summarise, classify, reply) is several use cases, not one, and counts as a fit.

### Step 4 — install the CLI and sign in

Only now, with the fit confirmed.

#### 4a. Install

```sh
curl -fsSL https://prompton.ai/install.sh | sh
# equivalent, straight from the repository:
curl -fsSL https://raw.githubusercontent.com/polimo-dev/prompton-cli/main/install.sh | sh
# release archives:      https://github.com/polimo-dev/prompton-cli/releases
# Homebrew tap (planned): brew install polimo-dev/tap/prompton
# from source:           go install github.com/polimo-dev/prompton-cli@latest
prompton --version
```

The script picks OS/arch, verifies the release checksum, installs to `/usr/local/bin` or `~/.local/bin`. `PTN_VERSION=main` installs the rolling build of the `main` branch — which is what the bare command falls back to while there is no tagged release yet — and `PTN_VERSION=v0.1.0` a tagged release once one exists; a tag that does not exist fails loudly (`no release for …`), so do not guess one. `PTN_INSTALL_DIR=…` chooses the destination.

**Host.** The CLI's built-in default host is `https://app.prompton.ai` (the app; `https://prompton.ai` is the landing site). This page describes `https://<host>`. If that is not the default, pass `--host https://<host>` to `prompton login` **and every later command**, or `export PTN_HOST=https://<host>`, or rely on the `host` the login wrote to `~/.config/prompton/config.json`. Precedence: flag > env > config file > default.

#### 4b. `prompton login` (device flow, a human must approve)

`prompton login` **blocks until the human approves** — it polls every 5 seconds for up to 15 minutes, far longer than the default timeout of the shell tool most agents run commands through, and a tool that only returns output when the process exits will hand you nothing to relay before it is killed. So never run it in the foreground of a call that can time out. Start it in the background with its output going to a file, read the URL and the code out of that file as soon as they appear, relay them, and only then wait for the process to finish:

```sh
prompton login --host https://<host> --no-browser > /tmp/ptn-login.log 2>&1 &
# a second later, read what it printed and relay it verbatim:
cat /tmp/ptn-login.log
# then poll for the background job to exit (up to 15 minutes) and read the file again
```

`--no-browser` prints the URL instead of opening it, which is what you want when you cannot see or drive the human's browser. The file will hold an approval URL and an 8-character code:

```text
  Open this URL to approve the login:
    https://<host>/device?code=H4KP-T7WR

  Your code: H4KP-T7WR

Waiting for approval…
```

**STOP and show the human that exact URL and code**, then wait for the command to return. Do not fabricate a code. Do not start a second login while one is pending — `/device/code` allows 20 requests per 10 minutes per IP (§6), and a retry loop burns that budget without helping.

#### 4c. Walk a first-time human through sign-up

Sign-up and sign-in are the same step, and there are no passwords. Tell them, in this order:

1. Open the URL you just showed them (`https://<host>/device?code=…`).
2. They are asked to sign in first: they type their **email address** on `/sign-in`.
3. PromptOn emails them a **6-digit code**, valid **5 minutes**, single use. They type it into the same page. An address that has never signed in before **becomes an account right there**, with its own personal organization — there is nothing else to sign up for, and nothing to pay.
4. The browser lands back on `/device?code=…`, showing the CLI's name and the code. They press **Approve**. (**Deny** ends the CLI with exit 1 and `login was denied in the browser`; after 15 minutes it exits 1 with `the login request expired` and you run `prompton login` again.)

When the poll succeeds the CLI stores a long-lived, revocable session token (`0600`) and prints `Logged in as <email>`. With exactly one organization the CLI adopts it; with several and no TTY it prints a warning instead of choosing — run `prompton use --org <slug|personal>` next. Non-interactive alternative: `PTN_TOKEN=<token>` (a token obtained the same way on another machine).

```sh
prompton whoami --json          # {"host","user","organizations","org","project"}
prompton use --org personal     # or a team slug; verified against the server
```

Confirm the identity back to the human (`Logged in as ada@example.com`, organization `personal`) before going on.

### Step 5 — write the migration plan, then stop

Write the plan as a document the human can read and correct. It is derived from what step 3 found, not from a template you filled in blind. Cover, in this order:

1. **Current state.** Where prompts live today (hard-coded strings, config files, a database table, a prompt-management SaaS, env vars), who edits them, and what shipping a prompt change costs today (a redeploy? a migration? a dashboard click?).
2. **The inventory**, as the table from step 3: one row per call site with its file and line, proposed use case key, `kind`, variables, current model and params, current prompt location.
3. **What gets created in PromptOn.** Organization and project slug, environments used (`production`, `staging`), one use case per call site with its key/kind/`input_schema`/`default_params`, prompt names per use case (`default` plus any real variant), and the model + params each environment pins. Same models and params the app uses today — a migration changes *where* config lives, not what the app sends.
4. **The code change per call site.** For each row: which function changes, what the resolve call replaces, what stays (provider key, HTTP client, retry logic, parsing, function signature), and what gets deleted (the hard-coded prompt text, model id and params).
5. **SDK or hand-written client.** Which the project's language gets, with the registry check that decided it (§1.8).
6. **Resilience.** The snapshot cache (memory + disk), the bundled snapshot committed into the repo for cold starts, and the rule that a generation never fails because PromptOn did (§1.9).
7. **Monitoring logs.** Where the batch buffer lives, what gets logged, what is redacted, and the payload policy that applies.
8. **Rollout.** Staging first: deploy the pins to `staging`, point a staging build at it, compare the logs against what the app produced before. Then `production`. Never both in one step.
9. **Rollback.** `prompton rollback <use-case> --revision N --environment production` for a bad pin; `git` revert of the worktree branch for a bad code change; the previous prompt text is never lost because versions are immutable.
10. **What does not change.** Provider keys, the HTTP client and its timeouts, the provider SDK, model choice, params, function signatures, tests, latency (no extra hop), and the app's behaviour when PromptOn is unreachable.

**STOP. Wait for the human's explicit approval of the plan.** Do not create anything in PromptOn and do not edit a single file before they say go. If they change the model list, the keys, or the staging story, rewrite the plan and ask again.

### Step 6 — migrate

#### 6a. A new git worktree, always

Code changes happen on a branch in a fresh worktree, never in the human's working tree:

```sh
BASE=$(git -C <repo> rev-parse --abbrev-ref HEAD)     # the base branch — not always "main"
git -C <repo> worktree add ../<repo>-prompton -b prompton-migration
```

Work there for the rest of this step; the human's checkout stays untouched and reviewable. Report the worktree path, the branch name, and the base branch you recorded — step 7 diffs against it, and it is `master`, `develop` or `trunk` often enough that hard-coding `main` breaks the last command of the journey.

If the project is **not a git repository**, say so and **STOP**. Ask which they want: `git init` plus one initial commit, so the migration is reviewable as a diff and revertible in one command, or edits in place with no diff to show at step 7. Nothing is edited, and nothing is created in PromptOn, before they answer.

#### 6b. Provision, one use case per call site

Provisioning talks to the server, so it does not depend on the worktree — but do it **after** the 6a question is answered and before you touch any code, so the code has something to resolve against. Use case keys are permanent (§5), so nothing here is created while the human is still deciding whether you may edit at all.

**One PromptOn project per deployable app**: one runtime key, one snapshot. Services that ship and scale independently get separate projects; services that make up one app share a project and are told apart by use case key.

```sh
prompton projects create heydiary --name HeyDiary --timezone Asia/Seoul --idempotent
prompton use --project heydiary

# use case: kind + declared variables (from the placeholders you found)
cat > schema.json <<'EOF'
[{"name": "transcriptions", "type": "list", "required": true,
  "description": "Today's voice notes, oldest first"}]
EOF
prompton use-cases create diary_generation --kind chat --name 'Diary generation' \
  --input-schema-file schema.json --default-params '{"temperature":0.5}' --idempotent

# version 1 = the app's prompt, verbatim, with placeholders as {{ variable }} (Liquid)
cat > messages.json <<'EOF'
[{"role": "system", "content": "You write diaries."},
 {"role": "user", "content": "{% for t in transcriptions %}{{ t }}\n{% endfor %}"}]
EOF
prompton prompts commit diary_generation default --file messages.json \
  --message "migrated from the app's hardcoded prompt"

# a second name only if the app already branched (e.g. by language)
prompton prompts open diary_generation ko --description Korean --idempotent
prompton prompts commit diary_generation ko --file messages.ko.json

# register the model with the provider the app actually calls, BEFORE deploying:
# `prompton deploy` registers an unknown model as provider `openrouter`, which is wrong
# for an app that calls OpenAI or Anthropic directly. `deploy` has no --provider flag.
#   prompton models register gpt-4o --provider openai
#   prompton models register claude-sonnet-4-5-20250929 --provider anthropic
# (this example app really does call OpenRouter, so its default is already right)

# the app's current model and params, unchanged
prompton deploy diary_generation --environment production \
  --model anthropic/claude-sonnet-4 --params '{"temperature":0.4}'
prompton deploy diary_generation --environment staging \
  --model anthropic/claude-sonnet-4 --params '{"temperature":0.4}'

# one runtime key per project; the secret is printed once
PTN_KEY=$(prompton api-keys issue --name 'HeyDiary server' --quiet)
```

**The model string is the app's, byte for byte.** `model_id` is the exact string the app already passes to its provider client — `gpt-4o` for the OpenAI SDK, `claude-sonnet-4-5-20250929` for the Anthropic SDK, `anthropic/claude-sonnet-4` only when the app really calls OpenRouter. Do not reformat it to match the examples on this page: the app reads it back out of the snapshot and sends it to the provider unchanged, so a "normalised" id is a 404 on every call, at runtime, after the migration looks finished. The provider is a property of the **catalog entry**, not of the deployment: `prompton models register <model-id> --provider openrouter|openai|anthropic|google|groq` sets it, and registering first is the only way to keep an app that calls a provider directly from being pointed at OpenRouter.

Template rules: engine `liquid` (default) or `raw`; allowed tags `for` `if` `unless` `assign` `break` `continue`, allowed filters `size` `join` `default`, no whitespace-control markers (`{%-`, `-%}`); anything else (e.g. `{% include %}`) is rejected at commit with 400. `detected_variables` in the commit response is the list to mirror in `input_schema`. `kind: text` commits `--file` as a text template; `kind: embedding` has no prompts. A `chat`/`text` use case is born with a prompt named `default`; if `default` exists it must be pinned.

Prove the pin resolves before touching code:

```sh
curl -sS -H "Authorization: Bearer $PTN_KEY" -H 'content-type: application/json' \
  -d '{"use_case":"diary_generation","variables":{"transcriptions":["a","b"]}}' \
  https://<host>/api/v1/resolve
```

#### 6c. Change the code: config-fetch in, prompt text out

Put `PTN_API_KEY` in the app's server-side environment (and in the deployment's secret store, not in the repo). Then, per call site:

1. Resolve the pin — from a cached snapshot (production path, §4.1) or via `/resolve` (simplest, one round-trip per call, §4.2).
2. Render the pinned prompt with this call's variables (`liquid`: substitute `{{ name }}`; `raw`: send verbatim).
3. Call the provider named by `model.provider` with `model.model_id`, the effective params and provider options — **with the app's existing provider key and HTTP client**. That provider must be the one the app was already calling: if the snapshot says `openrouter` for an app that calls OpenAI directly, the catalog entry is wrong (§1, step 6b). Fix the entry; never rewrite the call site to hit a provider the app has no key for.
4. Generate a UUIDv7 before the provider call; after it, enqueue a monitoring log (§4.3) and flush in batches.
5. On any PromptOn failure keep serving the last cached snapshot. A generation must never fail because PromptOn did.

**With the SDK** (today: Elixir only — §1.8). Add the dependency, configure `api_key`, `environment`, `base_url`, the disk cache path and the bundled snapshot, start it in the supervision tree, and replace each call site's prompt/model constants with resolve → render → your provider call inside the SDK's generation wrapper. The snapshot polling, the disk/bundle fallback, the payload policy and the log batching come with it; do not reimplement them.

For the bundled snapshot use the task the SDK ships rather than a hand-rolled fetch: `mix prompton.export --out priv/prompton/snapshot.json`, run in CI on every build, with the result committed (on a failed fetch it leaves the existing file untouched). Commit **both** files it writes — `snapshot.json` and the `snapshot.json.meta.json` sidecar — because the sidecar carries the `etag`, `last_modified` and `environment` the store reads back; without it the SDK reports a fabricated snapshot age and cannot seed the first poll's `If-None-Match`. Then point the SDK at it: `bundle: {:file, Application.app_dir(:myapp, "priv/prompton/snapshot.json")}`. The SDK's README in the repository is the reference for the rest of the configuration keys.

**Without an SDK.** Write one small module — one, not one per call site — that owns:

- a snapshot poller (§4.1) with the memory cache, the disk cache and the bundled snapshot (§1.9);
- the local resolve algorithm from §4.1 (deployment → prompt version → model → layered params and provider options);
- template rendering for the `liquid` and `raw` engines. **Liquid is a real template language, not `{{ }}` substitution** — the allowed set includes `{% for %}` and `{% if %}`, and the example prompt above is a loop. Use a genuine Liquid implementation (Python `python-liquid`, JavaScript `liquidjs`, Ruby `liquid`, Go `osteele/liquid`). A regex over `{{ name }}` silently drops every tag body, and Jinja2 only *looks* the same: its `default` behaves differently, it has no `size` filter, and it will render something other than what the PromptOn arena and the web app show. If the language has no Liquid library, either keep every prompt to bare `{{ name }}` placeholders with no tags, or render server-side with `POST /resolve` (§4.2) and accept the round-trip per call — the snapshot cache is still what keeps the app alive when PromptOn is down (§1.9);
- a monitoring-log buffer that batches, truncates per the use case's `payload_policy` (§4.3), retries `429` and 5xx (honour `Retry-After`; back off otherwise), splits a `413` batch in half, and drops on any other 4xx.

Call sites then depend on that module and nothing else. Keep each surrounding function's signature so callers do not change, and delete the hard-coded prompt text, model name and params from the repo.

Commit the bundled snapshot as part of this change: `GET /snapshot?environment=…` written to a file in the repository, **one file per environment** (`prompton-snapshot.production.json`, `prompton-snapshot.staging.json`), because the environment guard in §1.9 refuses a bundle exported from a different environment. Add refreshing them to the build so they do not rot. Storing each response's `ETag`, `Last-Modified` and `environment` beside its file is optional but worth it — without them the client cannot seed its first `If-None-Match` and cannot report how old the bundle is.

### Step 7 — show the diff

Run the diff on the worktree branch and show it:

```sh
git -C ../<repo>-prompton diff "$BASE"...prompton-migration   # $BASE from 6a; not always "main"
```

Alongside it, hand the human:

- **What exists in PromptOn now:** project slug, each use case key, each prompt name and version number, the pinned model and params per environment, and the runtime key's name (never the secret).
- **What the app needs to run:** `PTN_API_KEY` in the server environment, and any config the new module reads.
- **How to roll back:** `prompton rollback <use-case> --revision N --environment production` puts an older pin back as a new revision (`prompton deployments list <use-case> --environment production` shows the revisions); `git worktree remove ../<repo>-prompton` and deleting the branch throws the code change away; nothing in PromptOn is destroyed by either.
- **What to check first in staging:** that the resolved prompt matches the old hard-coded one byte for byte, and that monitoring logs are arriving on `https://<host>/{org}/{project}`.
- **Proof that an outage is survivable:** the §1.9 test you actually ran — the app started with PromptOn unreachable (wrong host, or the network cut) and still generated, on `resolution_source` `disk` or `bundle`. Show the log line. If you did not run it, the migration is not done; go back and run it.

Do not merge the branch, do not commit on the human's behalf beyond the migration branch, and do not push.

## 1.8 SDKs

Use the official SDK when one exists for the project's language. Today exactly one does.

| language | status | what to do |
|---|---|---|
| **Elixir** | **Written, in the repository — not on Hex yet** — `prompton_sdk`, module `PromptOnSDK` (Apache-2.0, repository [prompton-elixir](https://github.com/polimo-dev/prompton-elixir)) | check `mix hex.info prompton_sdk` first. If it resolves, `{:prompton_sdk, "~> 0.1"}`. If it does not, depend on the repository: `{:prompton_sdk, github: "polimo-dev/prompton", sparse: "sdk/elixir"}`. Either way, start `{PromptOnSDK, []}` in the supervision tree |
| Python | Planned, **not published** | hand-written client (§1, step 6c; §1.9) |
| Node.js / TypeScript | Planned, **not published** | hand-written client |
| Go | Planned, **not published** | hand-written client |
| Ruby | Planned, **not published** | hand-written client |
| Java | Planned, **not published** | hand-written client |
| Kotlin | Planned, **not published** | hand-written client |
| Rust | Planned, **not published** | hand-written client |

What the Elixir SDK gives you, and therefore what a hand-written client has to do for itself: a **snapshot store** that polls `GET /snapshot` with `If-None-Match`, keeps the document in memory, mirrors it to a disk cache and falls back to a snapshot bundled into the release; a **resolver** that turns a use case (plus an optional prompt name) into model, params, provider options and the pinned prompt template; a **renderer** that substitutes this call's variables into that template (resolve and render are two calls, not one — only the server's `POST /resolve` does both at once, and only when `variables` are supplied); and a **monitoring-log buffer** that applies the payload policy, batches, retries and drains on shutdown. Its README in the repository is the reference for its configuration keys, its `mix prompton.export` bundle task and its test mode.

**Verify before you assume.** Every row of that table is a snapshot of a moving target, including the Elixir one:

- Check the registry yourself before you write the dependency line — Hex (`mix hex.info prompton_sdk`), PyPI (`pip index versions …` or pypi.org), npm (`npm view …`), pkg.go.dev, RubyGems, Maven Central, crates.io. Do not trust this page over the registry.
- A package only counts if it is published by **polimo-dev** and its documentation points at PromptOn. A same-named package by anyone else is not the SDK — do not install it, and tell the human you found a lookalike.
- If the package does not resolve, say so and take a fallback that actually installs: depend on the SDK from the repository where one exists there (Elixir: `{:prompton_sdk, github: "polimo-dev/prompton-elixir"}`), otherwise write the client by hand (§1, step 6c). **Never invent an import, a package name or a method signature** for an SDK that does not exist, and never leave a call site importing a package the human cannot install.

## 1.9 Resilience checklist

The single most important behaviour of the migration. Tick every line, whether you used the SDK or wrote the client:

- **Poll, do not fetch per request.** `GET /snapshot?environment=…` with `If-None-Match` every **10 s** by default (the SDKs' default; make it configurable) — a `304` is a no-op, so a short interval is cheap. Refresh in the background or stale-while-revalidate; a refresh never blocks a generation. On `429` wait out `Retry-After` (else back off ×2, up to 5 min) and keep using the previous document; the caller never sees an error. `/resolve` is for smoke tests and low-traffic paths, never a hot loop.
- **Memory cache.** The last good snapshot lives in process memory and is what every resolve reads.
- **Disk cache.** Write each new snapshot to a file (atomically: temp file, then rename) and load it at boot before the first poll returns.
- **Bundled snapshot, one per environment.** Commit a snapshot file into the repository (refreshed by the build) so a cold start with no disk cache and no network still resolves — `snapshot.production.json`, `snapshot.staging.json`, and load the one matching the process's configured environment. A single shared bundle is refused by the environment guard below in whichever environment it was not exported from, which leaves that build with no cold-start fallback at all. Record where the config came from and send it as `resolution_source`: `remote` | `disk` | `bundle` | `manual`.
- **Short-lived and multi-process runtimes.** With several worker processes (`uvicorn --workers 4`, a prefork server) each keeps its own memory cache and they may share one disk-cache file, so the write must stay atomic. In serverless or scale-to-zero runtimes (Lambda, Vercel functions, Cloud Run at zero) there is no 30–60 s poller and often no writable disk: fetch once per cold start with a hard timeout, fall back to the **bundled** snapshot immediately on failure — there it is the primary fallback, not a nicety — and never let that fetch block the first generation.
- **Serve the last good document on any PromptOn failure** — timeout, 5xx, DNS, `503`, an expired key. Log it, alert on it, keep serving.
- **A generation must never fail because PromptOn did.** Config is stale in the worst case, not absent.
- **Never fall back to a hard-coded prompt.** A `404` with `error.code` `not_found` whose `details.reason` is `unresolved` or `unknown_prompt` (§4.2 — the discriminator is in `details`, not in `code`) is a bug in the deployment or the call, not a signal to reach for a copy of the old string. Fail that call loudly instead.
- **Refuse a snapshot from the wrong environment** (a `staging` process must not boot on a `production` bundle) and from an unsupported `schema_version`; keep polling for a good one.
- **Batch monitoring logs** with app-generated UUIDv7 ids, flush on a size or time trigger, and never block the provider call on a log flush. Retry `429` and 5xx (honour `Retry-After`, back off otherwise), split a `413` batch in half, drop on any other 4xx, and cap the buffer by dropping the oldest.
- **Prove it.** Before calling the migration done, run the app with PromptOn unreachable (wrong host, or the network cut) and confirm generations still happen on the cached snapshot.

## 2. CLI reference

Global flags on every command: `--host`, `--token`, `--org <slug|personal>`, `--project <slug>`, `--json`, `--quiet`, `--idempotent`. Env: `PTN_HOST`, `PTN_TOKEN`, `PTN_ORG`, `PTN_PROJECT`, `PTN_OPENROUTER_KEY`, `PTN_CONFIG`.

| command | example |
|---|---|
| `login [--no-browser] [--org O]` | `prompton login --host https://<host> --no-browser` |
| `logout` | `prompton logout` (revokes this token server-side, clears it locally, keeps the host) |
| `whoami` | `prompton whoami --json` |
| `orgs list` | `prompton orgs list --json` |
| `use --org O [--project P]` | `prompton use --org acme-inc --project heydiary` |
| `projects list` | `prompton projects list --json` |
| `projects create <slug> [--name N] [--timezone TZ]` | `prompton projects create heydiary --name HeyDiary --idempotent` |
| `use-cases list` | `prompton use-cases list --json` |
| `use-cases get <key>` | `prompton use-cases get diary_generation --json` (prompts, versions, live deployments) |
| `use-cases create <key> [--kind chat\|text\|embedding] [--name N] [--description D] [--input-schema-file F] [--default-params JSON] [--tags a,b]` | `prompton use-cases create diary_generation --kind chat --input-schema-file schema.json` |
| `use-cases update <key> [--name] [--description] [--tags] [--input-schema-file] [--default-params]` | `prompton use-cases update diary_generation --default-params '{"temperature":0.3}'` (schema/params replace, not merge) |
| `prompts open <use-case> <name> [--description D]` | `prompton prompts open diary_generation ko --description Korean` |
| `prompts commit <use-case> <name> --file F [--format auto\|messages\|text] [--engine liquid\|raw] [--message M]` | `prompton prompts commit diary_generation default --file messages.json --message "v1"` (`--file -` reads stdin) |
| `models list` | `prompton models list --json` |
| `models register <model-id> [--provider P] [--display-name N]` | `prompton models register anthropic/claude-sonnet-4` |
| `deploy <use-case> --model M [--environment E] [--params JSON] [--provider-options JSON] [--pin name=version ...]` | `prompton deploy diary_generation --model anthropic/claude-sonnet-4 --pin default=1 --pin ko=latest` |
| `deployments list <use-case> [--environment E]` | `prompton deployments list diary_generation --environment production` (history) |
| `rollback <use-case> --revision N [--environment E]` | `prompton rollback diary_generation --revision 2 --environment production` |
| `api-keys issue [--name N] [--scopes resolve,logs]` | `PTN_KEY=$(prompton api-keys issue --quiet)` |
| `api-keys list` | `prompton api-keys list --json` |
| `provider-key set [--secret S] [--label L]` | `PTN_OPENROUTER_KEY=sk-or-… prompton provider-key set` |
| `provider-key status` | `prompton provider-key status --json` |

- `--model` takes a provider string (`anthropic/claude-sonnet-4`, registered on the fly) or a catalog UUID. `--pin` takes a version number, `latest`, or a version UUID; omit `--pin` to pin the newest committed version of every prompt. Promote = same `deploy` with another `--environment`.
- `--json`: stdout carries exactly one JSON document (create/get commands print the object; lists print `{"projects": [...]}` etc.); progress goes to stderr. Failures are JSON on stderr in the API envelope plus `"status"`: `{"error": {"code": "not_found", "message": "…", "status": 404, "details": {…}}}`.
- Exit codes: `0` ok · `1` the server or network said no (including "already exists" without `--idempotent`) · `2` wrong invocation (retype the command).
- `--idempotent`: creates that hit 409 print the existing resource and exit 0, so a provisioning script reruns cleanly.

The full command reference is the [CLI reference](https://docs.prompton.ai/cli).

## 3. REST equivalents (management API)

Base `https://<host>/api/v1`, header `Authorization: Bearer <CLI session token>`, JSON in and out, snake_case, ids are bare UUID strings. Success responses are bare objects; lists are `{"<plural>": [...]}`. Every error is `{"error": {"code": "…", "message": "…", "details": {…}}}`. Unknown request fields are ignored. `:org` = team slug or the reserved `personal`. The full reference is the [management API](https://docs.prompton.ai/management-api).

### Device login (no auth; per-IP rate limits)

```jsonc
POST /device/code   {"client": "prompton-cli/0.1.0 (darwin/arm64)", "name": "CLI on lain"}   // client required, name ≤ 200 chars
// 201
{"device_code": "…", "user_code": "H4KP-T7WR", "verification_uri": "https://<host>/device",
 "verification_uri_complete": "https://<host>/device?code=H4KP-T7WR", "expires_in": 900, "interval": 5}

POST /device/token  {"device_code": "…"}                // poll every `interval` seconds
// 200 — exactly once after approval
{"token": "…", "user": {"id": "…", "email": "ada@example.com"},
 "organizations": [{"id": "…", "name": "Ada", "slug": null, "personal": true, "created_at": "…"}]}
// 400 while waiting — error.code: authorization_pending | slow_down | expired_token | access_denied
```

Limits: `/device/code` 20 requests / 10 min / IP, `/device/token` 600 / 10 min / IP → `429 {"error": {"code": "rate_limited", "details": {"retry_after": <seconds>}}}` + `Retry-After`.

### Session

| method & path | body → response |
|---|---|
| `GET /me` | `{"user": {"id","email"}, "organizations": [{"id","name","slug","personal","created_at"}]}` |
| `POST /sessions/revoke` | `{"revoked": true}`; the token is dead afterwards (401) |
| `GET /orgs` | `{"organizations": [...]}` (personal first) |
| `GET /orgs/:org` | one organization; non-member or unknown → 404 `details.organization` |

### Projects

```jsonc
GET  /orgs/:org/projects                      // {"projects": [...]}; archived ones are absent
POST /orgs/:org/projects
     {"key": "heydiary", "name": "HeyDiary", "timezone": "Asia/Seoul"}   // key (alias "slug") required; name defaults to key; timezone defaults to Etc/UTC
// 201
{"id": "…", "slug": "heydiary", "name": "HeyDiary", "timezone": "Asia/Seoul", "created_at": "…",
 "environments": [{"id": "…", "slug": "production", "name": "Production", "protected": true},
                  {"id": "…", "slug": "staging", "name": "Staging", "protected": false}]}
// 400 missing/malformed/reserved key · 409 {"details": {"project": {...}}}
```

### Use cases

```jsonc
GET  /orgs/:org/projects/:project/use-cases            // {"use_cases": [...]}
POST /orgs/:org/projects/:project/use-cases
     {"key": "diary_generation", "name": "Diary generation", "kind": "chat", "description": "…",
      "input_schema": [{"name": "transcriptions", "type": "list", "required": true, "description": "…", "example": "…"}],
      "default_params": {"temperature": 0.5}, "tags": ["diary"]}
// 201 {"id","key","name","description","kind","input_schema","default_params","tags","created_at"}
// key required ([a-z0-9_], starts with a letter); kind chat (default) | text | embedding; type string|number|boolean|list|map
// 400 bad kind / schema · 409 {"details": {"use_case": {...}}}

GET  /orgs/:org/projects/:project/use-cases/:key       // use case + prompts + live deployments
{"id": "…", "key": "diary_generation", "kind": "chat", "input_schema": [...], "default_params": {...}, "tags": [], "created_at": "…",
 "prompts": [{"id": "…", "name": "default", "description": null, "created_at": "…", "version_count": 2,
              "versions": [{"id": "…", "number": 2, "message": "shorter", "detected_variables": ["transcriptions"], "created_at": "…"}]}],
 "deployments": [{"id": "…", "revision": 3, "environment": "production", "model_id": "<catalog uuid>",
                  "model": "anthropic/claude-sonnet-4", "params": {...}, "provider_options": {...},
                  "prompt_pins": {"default": "<version uuid>", "ko": "<version uuid>"}, "created_at": "…"}]}
// 404 {"details": {"use_case": "nope"}}; `versions` holds the 20 most recent

PATCH /orgs/:org/projects/:project/use-cases/:key      // any of name, description, tags, input_schema, default_params (replace, not merge) → 200 use case
```

### Prompts and versions

```jsonc
POST /orgs/:org/projects/:project/use-cases/:key/prompts
     {"name": "ko", "description": "Korean"}                      // 201 {"id","name","description","created_at"}; "default" already exists → 409 details.prompt

POST /orgs/:org/projects/:project/use-cases/:key/prompts/:name/versions
     {"messages": [{"role": "system", "content": "…"}, {"role": "user", "content": "{{ transcript }}"}],
      "engine": "liquid", "message": "migrated from the app"}      // kind chat
     {"text_template": "…"}                                        // kind text
// 201
{"id": "…", "prompt_id": "…", "number": 1, "engine": "liquid", "messages": [...], "text_template": null,
 "detected_variables": ["transcript"], "message": "migrated from the app", "content_sha256": "…", "created_at": "…"}
// 400 content does not match kind / lint failure / a message missing role or content · 404 unknown name {"details": {"prompt": "ja", "available_prompts": ["default"]}}
```

Versions are immutable; committing again yields `number + 1`. Committing alone changes nothing at runtime.

### Models

```jsonc
GET  /orgs/:org/projects/:project/models        // {"models": [...]}, archived excluded
POST /orgs/:org/projects/:project/models
     {"model_id": "anthropic/claude-sonnet-4", "provider": "openrouter", "display_name": "Claude Sonnet 4",
      "metadata": {}, "provider_options": {"only": ["Anthropic"]},
      "pricing": {"input_per_m": 3.0, "output_per_m": 15.0, "currency": "USD", "unit": "token"},
      "context_length": 200000, "capabilities": ["tools", "streaming"], "status": "active"}
// 201 — same fields plus "id" (the catalog UUID a deployment pins) and "created_at"
// only model_id is required; provider defaults to openrouter; OpenRouter models get display_name/pricing/context_length filled from the public catalog
// 400 missing model_id / bad pricing · 409 {"details": {"model": {...}}}
```

Two meanings of `model_id`: on a **model** object it is the provider string; on a **deployment** it is the catalog UUID (the deployment's `model` is the provider string).

### Deployments (pins)

```jsonc
GET  /orgs/:org/projects/:project/use-cases/:key/deployments                        // live revision per environment
GET  /orgs/:org/projects/:project/use-cases/:key/deployments?environment=staging    // that environment's history, newest first
POST /orgs/:org/projects/:project/use-cases/:key/deployments
     {"environment": "production",                       // default production
      "model_id": "<catalog uuid>",                      // or "model": "anthropic/claude-sonnet-4" (registered if missing; model_id wins if both)
      "prompt_pins": {"default": "<version uuid>", "ko": "<version uuid>"},   // omit → newest committed version of every prompt
      "params": {"temperature": 0.4},                    // layered over use case default_params
      "provider_options": {"allow_fallbacks": false}}    // layered over the model's provider_options
// 201 {"id","revision","environment","model_id","model","params","provider_options","prompt_pins","created_at"}
// 400 no model · 404 unknown model_id (details.model_id) / environment (details.environment)
// 400 no committed prompt version · 400 pin names a prompt this use case lacks · 400 prompt_pins not an object of strings

POST /orgs/:org/projects/:project/use-cases/:key/deployments/rollback
     {"environment": "production", "revision": 1}       // revision: positive integer (not a string)
// 200 new revision carrying the old pins · 404 {"details": {"revision": 9, "available_revisions": [2, 1]}}
```

A revision is live the moment it is committed. Embedding use cases pin `{}`.

### Runtime keys and the BYOK provider key

```jsonc
GET  /orgs/:org/projects/:project/api-keys      // {"api_keys": [{"id","name","key_prefix","scopes","last_used_at","created_at"}]} — no secret
POST /orgs/:org/projects/:project/api-keys
     {"name": "HeyDiary server", "scopes": ["resolve", "logs"]}    // name defaults to "CLI key"; scopes default to both
// 201 {"id","name","key_prefix","scopes","last_used_at","created_at","key": "ptn_heydiary_…"}  ← the only time "key" is returned
// 400 unknown scope or non-list scopes

GET  /orgs/:org/provider-key      // {"connected": false, "provider": "openrouter"} or {"connected": true, "id","provider","label","hint": "sk-or-v1-••••4Xa2","last_used_at","created_at"}
POST /orgs/:org/provider-key      {"secret": "sk-or-v1-…", "label": "default"}   // 201 same shape; 409 details.provider_key when the label exists
```

The provider key is optional: PromptOn uses it only where PromptOn itself calls an LLM (arena, AI drafts). The app's own traffic never needs it.

## 4. Runtime contract

Base `https://<host>/api/v1`, header `Authorization: Bearer ptn_<project_slug>_…`. Scopes: `resolve` → `GET /snapshot`, `POST /resolve`; `logs` → `POST /generations`. Missing scope → 403 `forbidden`; missing/revoked key or archived project → 401 `unauthorized`. The key is project-wide; the **environment is a request parameter** (`environment`, default `production`); unknown environment → 404 `{"details": {"environment": "canary"}}`, blank → 400. Body limit 5 MB (413 `payload_too_large`). `GET /health` and `GET /health/ready` need no auth. The full reference is the [runtime API](https://docs.prompton.ai/api).

### 4.1 `GET /snapshot?environment=production` — production path

```text
GET /api/v1/snapshot?environment=production
Authorization: Bearer $PTN_API_KEY
If-None-Match: "sha256-…"          → 304 with an empty body when unchanged
```

Response headers: `ETag: "sha256-<hex>"` (sha256 of the canonical body), `Last-Modified`, `Cache-Control: max-age=30`. Body (schema v3):

```jsonc
{"schema_version": 3, "project": "heydiary", "environment": "production",
 "use_cases": {
   "diary_generation": {"id": "…", "kind": "chat",
     "input_schema": [{"name": "transcriptions", "type": "list", "required": true}],
     "default_params": {"temperature": 0.5},
     "payload_policy": {"mode": "full", "sample_rate": 1.0, "max_bytes": 262144, "retention_days": 30, "encrypt": true}}},
 "deployments": {
   "diary_generation": {"id": "…", "revision": 3, "model_id": "<catalog uuid>",
     "params": {"temperature": 0.4}, "provider_options": {"allow_fallbacks": false},
     "prompt_pins": {"default": "<version uuid>", "ko": "<version uuid>"}}},
 "prompt_versions": {
   "<version uuid>": {"id": "…", "prompt_id": "…", "number": 2, "engine": "liquid",
     "messages": [{"role": "system", "content": "…"}, {"role": "user", "content": "…"}], "text_template": null}},
 "models": {
   "<catalog uuid>": {"id": "…", "provider": "openrouter", "model_id": "anthropic/claude-sonnet-4", "display_name": "…",
     "metadata": {}, "provider_options": {"only": ["Anthropic"]}, "capabilities": ["tools"], "status": "active"}}}
```

Resolve locally (`<-` = shallow merge, right side wins):

```text
deployment       = snapshot.deployments[use_case]          # absent → no live deployment (error, not fallback)
version          = snapshot.prompt_versions[deployment.prompt_pins[prompt_name or "default"]]   # name not in prompt_pins → error
model            = snapshot.models[deployment.model_id]
params           = snapshot.use_cases[use_case].default_params <- deployment.params
provider_options = model.provider_options <- deployment.provider_options
```

Poll every 10 s by default with `If-None-Match` (a `304` costs nothing); keep the last good document in memory and on disk; serve it when the poll fails or returns `429` (§1.9). A use case with no live deployment is simply absent from `deployments`; an environment with none is `{"deployments": {}, "prompt_versions": {}}`, not an error. The server caches the snapshot per environment for about 5 s, so a fresh deployment can lag that long here (never on `/resolve`).

### 4.2 `POST /resolve` — reference implementation and smoke test

```jsonc
// request
{"use_case": "diary_generation",          // required
 "environment": "production",             // default production
 "prompt": "ko",                          // default "default"; the only selection axis
 "variables": {"transcriptions": ["a", "b"]}}   // present → rendered; absent → raw template
// 200
{"use_case": "diary_generation", "kind": "chat",
 "deployment": {"id": "…", "revision": 3},
 "prompt": "ko", "prompts": ["default", "ko"],
 "model_id": "<catalog uuid>", "model": "anthropic/claude-sonnet-4", "provider": "openrouter",
 "effective_params": {"temperature": 0.4},
 "effective_provider_options": {"only": ["Anthropic"], "allow_fallbacks": false},
 "prompt_version": {"id": "…", "number": 1},
 "messages": [{"role": "system", "content": "…"}, {"role": "user", "content": "…rendered…"}],   // kind text: "text": "…"; embedding: neither, prompt null, prompts [], prompt_version null
 "warnings": [], "etag": "sha256-…"}
```

Errors: 400 `invalid_request` — `use_case` missing, `variables` not an object, `prompt` not a non-empty string, environment not a string, or a required variable missing (`{"details": {"missing_variable": "transcriptions"}}`); 404 `not_found` — unknown `use_case`, no live deployment (`{"details": {"reason": "unresolved"}}`), unpinned prompt name (`{"details": {"reason": "unknown_prompt", "prompt": "ja", "available_prompts": ["default", "ko"]}}`), unknown environment. Not cached: a just-committed revision shows immediately.

### 4.3 `POST /generations?environment=production` — monitoring logs

```jsonc
{"generations": [
  {"id": "<UUIDv7 made by the app>",         // required — idempotency key
   "use_case": "diary_generation",           // required (unknown keys are stored, not rejected)
   "model": "anthropic/claude-sonnet-4",     // required — provider model string
   "status": "ok",                           // required — "ok" | "error"
   "started_at": "2026-09-01T09:12:03.123Z", // required — ISO 8601; ≤ 5 min in the future, ≤ 7 days in the past
   "kind": "chat",                           // chat (default) | text | embedding
   "deployment_id": "…", "deployment_revision": 3, "prompt": "ko", "prompt_version_id": "…", "model_id": "<catalog uuid>",
   "resolution_source": "remote",            // remote | disk | bundle | manual
   "provider": "openrouter", "model_used": "…", "upstream_provider": "Anthropic",
   "params": {"temperature": 0.4},           // > 4 KB → blanked, listed in metadata.truncated_fields
   "input": {"variables": {...}, "messages": [{"role": "system", "content": "…"}], "truncated": false},   // or {"text": "…"}
   "output": {"content": "…", "tool_calls": [], "truncated": false},
   "finish_reason": "stop", "stop_kind": "stop",   // stop | length | tool_call | content_filter | other; derived from finish_reason when absent
   "error": {"kind": "rate_limited", "status": 429, "message": "…"},   // on status "error": kind http_4xx | http_5xx | rate_limited | timeout | transport | parse | app
   "usage": {"input_tokens": 1830, "output_tokens": 412, "cost_usd": 0.00312, "cost_source": "provider", "raw": {}},   // cost_source provider | catalog | unknown; raw > 16 KB → blanked
   "latency_ms": 4180, "trace_id": "job:88213", "sequence": 1, "end_user_ref": "u_…",
   "context": {"language": "ko", "plan": "pro"},   // ≤ 2 KB or the record is rejected
   "metadata": {"job_id": 88213},                  // ≤ 4 KB or the record is rejected
   "sdk": {"name": "myapp-prompton-client", "version": "0.1.0"}}
]}
// 202
{"accepted": 98, "duplicates": 2,
 "rejected": [{"index": 5, "id": "…", "code": "invalid_request", "message": "started_at is more than 7 days in the past"}]}
```

Rules:

- ≤ 200 records per request (more → 400 `invalid_request`), ≤ 5 MB body (→ 413). Batch on a size or time trigger; never one HTTP call per generation.
- `id` is the idempotency key: a resend is counted in `duplicates`, never stored twice. An `id` already owned by another project is `rejected` with `code: "conflict"`.
- Partial acceptance: one bad record never fails the batch. Read `rejected`, do not resend accepted ones.
- The `environment` query parameter is forced on the whole batch; send one batch per environment.
- `503 unavailable` + `Retry-After` is the one status PromptOn itself asks you to retry — resend the same batch with the same ids. Be robust to whatever sits in front of it too: retry `429` and any 5xx (honour `Retry-After`, back off otherwise), split a `413` batch in half, and drop on any other 4xx.
- Send failures too (`status: "error"` + `error`); error rates and truncation rates are meaningless without them.
- Payload storage follows the use case's `payload_policy` from the snapshot: `mode` `full` stores `input`/`output` (encrypted at rest), sampled by `sample_rate` on a hash of `id` — errors and `stop_kind: "length"` are always kept; `hash` keeps only sha256 + byte size; `none` drops it. A client may pre-hash by sending `input`/`output` as `{"sha256": "<64 hex>", "bytes": n}`.
- Truncate before sending, relative to `max_bytes` (default 262144): one message `content` ≤ `max_bytes/8`; `input.messages`, `input.text`, `input.variables` ≤ `max_bytes` each; `output.content` and `output.tool_calls` ≤ `max_bytes/4`. Keep head and tail, set `"truncated": true`. The server re-checks with the same rules. Strings with NUL bytes or invalid UTF-8 are rejected per record.
- Free plan: 10,000 logs / month with 7-day retention. Not enforced yet; when billing ships, overage degrades softly (counts kept, payloads dropped).

## 5. Do / don't

- **Do** keep the provider key and the HTTP call in the app. **Never** route generations through PromptOn — there is no proxy endpoint.
- **Do** treat `production` as the default environment everywhere (`/snapshot`, `/resolve`, `/generations`, `deploy`); name `staging` explicitly.
- **Do** cache the snapshot (memory + disk) and poll with `If-None-Match`; **don't** call `/resolve` per request in a hot path.
- **Do** treat a 404 `unknown_prompt` / `unresolved` as a bug in the app or the deployment, **never** as a signal to fall back to a hard-coded prompt.
- **Do** batch monitoring logs with app-generated UUIDv7 ids; **don't** retry on 4xx.
- **Don't** log secrets: no provider keys, no `PTN_API_KEY`, no user PII beyond `end_user_ref`, in `input`, `output`, `context` or `metadata`.
- **Don't** ship the runtime key to a browser or mobile client; both runtime calls belong server-side.
- **Don't** invent use case keys ad hoc: one key per call site, agreed with the human, and never renamed (create a new use case instead).
- **Do** use `--idempotent` / expect 409 in provisioning scripts; the 409 `details` carry the existing resource, so no second lookup is needed.
- **Don't** commit a version and assume it is live — only a deployment revision makes it live.
- **Don't** skip a stop in §1. All of them are the human's call, not yours: which project to migrate, whether you can edit the code at all, the **not-a-fit** verdict, the **borderline single call site**, approval of the plan, and the not-a-git-repository question.

## 6. Troubleshooting

| symptom | meaning | action |
|---|---|---|
| 401 `unauthorized` on `/api/v1/orgs…` or `/me` | no token, wrong token, revoked session (logout, device list, "Sign out everywhere" on `/account`), or a **runtime key** used on the management door | `prompton login` again (`--host https://<host>` if not the default host) |
| 401 on `/snapshot`, `/resolve`, `/generations` | runtime key missing/wrong/revoked, its project archived, or a **CLI token** used on the runtime door | issue a key: `prompton api-keys issue` |
| 403 `forbidden` on the runtime API | key lacks the scope (`resolve` or `logs`) | issue a key with both scopes |
| 404 `not_found` with `details.organization` / `details.project` | you are not a member, or it does not exist — non-members get 404, never 403 | `prompton orgs list`, `prompton projects list`; check `--org` |
| 404 with `details.use_case` / `details.prompt` + `available_prompts` / `details.environment` | wrong name; the details list what exists | fix the name; open the prompt with `prompts open` |
| 404 `details.reason = "unresolved"` | the use case has no live deployment in that environment | `prompton deploy <use-case> --environment <env> --model …` |
| 404 `details.reason = "unknown_prompt"` | the requested `prompt` is not pinned by the live revision | pin it (`--pin name=latest`) and redeploy, or send a pinned name |
| 400 `details.missing_variable` | template needs a variable the call did not send | send it; mirror `detected_variables` in `input_schema` |
| 409 `conflict` on a create | already exists; `details.<resource>` is the existing object | continue with it (`--idempotent`) |
| 429 `rate_limited` on `/device/code` or `/device/token` | 20 code requests or 600 polls per 10 min per IP | wait `details.retry_after` seconds, then `prompton login` again |
| `expired_token` from `/device/token` after the human approved | the 15-minute window passed, the token was already collected once, or the code never existed | `prompton login` again; approve within 15 minutes |
| `slow_down` from `/device/token` | polled faster than `interval` | add 5 s to the interval |
| `access_denied` | the human pressed Deny | stop; ask the human |
| 400 `no committed prompt version` on deploy | nothing to pin yet | `prompton prompts commit … --file …` first |
| CLI exit 2 `no organization selected` | scope not set | `prompton use --org <slug|personal>` or `--org` |
| 413 `payload_too_large` on `/generations` | batch over 5 MB | halve the batch and resend |
| 503 `unavailable` | PromptOn degraded | honour `Retry-After`; keep serving the cached snapshot |

Programs should fetch this page as raw markdown from `https://docs.prompton.ai/agent.md`.
