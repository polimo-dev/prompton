# PromptOn — integration reference for coding agents

This page is the whole contract. Everything an agent needs to move an app's LLM calls onto PromptOn is here: the CLI, the REST equivalents, the runtime API, and the rules. `<host>` below is the PromptOn instance that served this page.

## 0. What PromptOn is

- A **control plane** for prompts and models: per use case and per environment it holds one **pin** = prompt version(s) + one model + params.
- **Config-fetch, not a proxy.** The app fetches the pin (`GET /api/v1/snapshot` or `POST /api/v1/resolve`) and then calls the LLM provider **itself, with its own provider key and its own HTTP client**. PromptOn is never in the request path and never sees the provider key.
- **Monitoring logs** are batched `POST /api/v1/generations` calls the app sends after each provider call (successes and failures).
- Two credentials, two doors: a **CLI session token** (from `prompton login`, a human's identity) provisions things under `/api/v1/me` and `/api/v1/orgs/…`; a **runtime API key** (`ptn_<project_slug>_…`, one per project) reads config and sends logs. Neither opens the other door (401).
- Hierarchy: Organization (`personal` or a team slug) → Project (environments `production`, `staging`) → Use case (one per LLM call site) → prompts by name (`default`, `ko`, …) → immutable versions → deployment revisions (pins).

## 1. Migration recipe

### Step 1 — install the CLI

```sh
curl -fsSL https://prompton.ai/install.sh | sh
# equivalent, straight from the repository:
curl -fsSL https://raw.githubusercontent.com/polimo-dev/prompton-cli/main/install.sh | sh
# Homebrew tap (planned): brew install polimo-dev/tap/prompton
# from source:           go install github.com/polimo-dev/prompton-cli@latest
prompton --version
```

The script picks OS/arch, verifies the release checksum, installs to `/usr/local/bin` or `~/.local/bin`. `PTN_VERSION=v0.1.0` and `PTN_INSTALL_DIR=…` override.

**Host.** The CLI's built-in default host is `https://app.prompton.ai` (the app; `prompton.ai` is the landing site). If `<host>` is anything else, pass `--host https://<host>` to `prompton login` **and every later command**, or `export PTN_HOST=https://<host>`, or rely on the `host` the login wrote to `~/.config/prompton/config.json`. Precedence: flag > env > config file > default.

### Step 2 — `prompton login` (device flow, a human must approve)

```sh
prompton login --host https://<host> --no-browser
```

The CLI prints an approval URL and an 8-character code, then polls every 5 seconds for up to 15 minutes:

```
  Open this URL to approve the login:
    https://<host>/device?code=H4KP-T7WR

  Your code: H4KP-T7WR

Waiting for approval…
```

**Stop and show the human the URL and the code.** They sign in and press Approve on `/device`. Signing in is by **email only**: they enter their address on `/sign-in`, PromptOn emails them a **6-digit code** (from `PromptOn <noreply@prompton.ai>`, valid 5 minutes, single use) and they type it into the same page — no password, no link to click, and a new address becomes an account on its first sign-in. Once the code is accepted they land back on `/device?code=…`. When the poll succeeds the CLI stores a long-lived, revocable session token (`0600`) and prints `Logged in as <email>`. With several organizations and no TTY it prints a warning instead of choosing — run `prompton use --org <slug|personal>` next. Non-interactive alternative: `PTN_TOKEN=<token>` (a token obtained the same way on another machine).

```sh
prompton whoami --json          # {"host","user","organizations","org","project"}
prompton use --org personal     # or a team slug; verified against the server
```

### Step 3 — inventory every LLM call in the codebase

Search for provider SDKs and raw HTTP to provider hosts (`openai`, `anthropic`, `openrouter`, `groq`, `google`/`genai`, `litellm`, `langchain`, `vercel/ai`, `api.openai.com`, `openrouter.ai/api`, `api.anthropic.com`). For each call site record:

| collect | becomes |
|---|---|
| a stable snake_case name for the call site (`diary_generation`) | use case `key` (cannot change later) |
| chat messages vs a single string vs an embedding call | `kind`: `chat` \| `text` \| `embedding` |
| every value interpolated into the prompt (f-strings, template placeholders, string concatenation) | `input_schema` variables and `{{ name }}` placeholders |
| language/tone/tenant variants of the same prompt | prompt names (`default`, `ko`, …) |
| the model id string and the params (`temperature`, `max_tokens`, …) | `model` and `params` of the deployment pin |
| the provider key and the HTTP client | **stay in the app** |

### Step 4 — provision, one use case per call site

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

# the app's current model, unchanged — deploy registers it in the catalog on the way
prompton deploy diary_generation --environment production \
  --model anthropic/claude-sonnet-4 --params '{"temperature":0.4}'
prompton deploy diary_generation --environment staging \
  --model anthropic/claude-sonnet-4 --params '{"temperature":0.4}'

# one runtime key per project; the secret is printed once
PTN_KEY=$(prompton api-keys issue --name 'HeyDiary server' --quiet)
```

Template rules: engine `liquid` (default) or `raw`; allowed tags `for` `if` `unless` `assign`, allowed filters `size` `join` `default`; anything else (e.g. `{% include %}`) is rejected at commit with 400. `detected_variables` in the commit response is the list to mirror in `input_schema`. `kind: text` commits `--file` as a text template; `kind: embedding` has no prompts. A `chat`/`text` use case is born with a prompt named `default`; if `default` exists it must be pinned.

Prove the pin resolves before touching code:

```sh
curl -sS -H "Authorization: Bearer $PTN_KEY" -H 'content-type: application/json' \
  -d '{"use_case":"diary_generation","variables":{"transcriptions":["a","b"]}}' \
  https://<host>/api/v1/resolve
```

### Step 5 — replace each call with config-fetch, keep the provider call

Put `PTN_API_KEY` in the app's server-side environment. Then, per call site:

1. Resolve the pin — from a cached snapshot (production path, §5.2) or via `/resolve` (simplest, one round-trip per call, §5.3).
2. Render the pinned prompt with this call's variables (`liquid`: substitute `{{ name }}`; `raw`: send verbatim).
3. Call the provider named by `model.provider` with `model.model_id`, the effective params and provider options — **with the app's existing provider key and HTTP client**.
4. Generate a UUIDv7 before the provider call; after it, enqueue a monitoring log (§5.4) and flush in batches.
5. On any PromptOn failure keep serving the last cached snapshot. A generation must never fail because PromptOn did.

Delete the hard-coded prompt text, model name and params from the repo. Keep the surrounding function's signature so callers do not change.

**Show the human a diff of the code changes before applying them**, and list which prompts/models were created in PromptOn.

## 2. CLI reference

Global flags on every command: `--host`, `--token`, `--org <slug|personal>`, `--project <slug>`, `--json`, `--quiet`, `--idempotent`. Env: `PTN_HOST`, `PTN_TOKEN`, `PTN_ORG`, `PTN_PROJECT`, `PTN_OPENROUTER_KEY`, `PTN_CONFIG`.

| command | example |
|---|---|
| `login [--no-browser]` | `prompton login --host https://<host> --no-browser` |
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

## 3. REST equivalents (management API)

Base `https://<host>/api/v1`, header `Authorization: Bearer <CLI session token>`, JSON in and out, snake_case, ids are bare UUID strings. Success responses are bare objects; lists are `{"<plural>": [...]}`. Every error is `{"error": {"code": "…", "message": "…", "details": {…}}}`. Unknown request fields are ignored. `:org` = team slug or the reserved `personal`.

### Device login (no auth; per-IP rate limits)

```jsonc
POST /device/code   {"client": "prompton-cli/0.1.0 (darwin/arm64)", "name": "CLI on lain"}   // client required, name ≤ 200 chars
// 201
{"device_code": "…", "user_code": "H4KP-T7WR", "verification_uri": "https://<host>/device",
 "verification_uri_complete": "https://<host>/device?code=H4KP-T7WR", "expires_in": 900, "interval": 5}

POST /device/token  {"device_code": "…"}                // poll every `interval` seconds
// 200 — exactly once after approval
{"token": "…", "user": {"id": "…", "email": "ada@example.com"},
 "organizations": [{"id": "…", "name": "Ada", "slug": null, "personal": true}]}
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

The provider key is optional: PromptOn uses it only where PromptOn itself calls an LLM (arena, AI drafts, evaluations). The app's own traffic never needs it.

## 4. Runtime contract

Base `https://<host>/api/v1`, header `Authorization: Bearer ptn_<project_slug>_…`. Scopes: `resolve` → `GET /snapshot`, `POST /resolve`; `logs` → `POST /generations`. Missing scope → 403 `forbidden`; missing/revoked key or archived project → 401 `unauthorized`. The key is project-wide; the **environment is a request parameter** (`environment`, default `production`); unknown environment → 404 `{"details": {"environment": "canary"}}`, blank → 400. Body limit 5 MB (413 `payload_too_large`). `GET /health` and `GET /health/ready` need no auth.

### 4.1 `GET /snapshot?environment=production` — production path

```
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

```
deployment       = snapshot.deployments[use_case]          # absent → no live deployment (error, not fallback)
version          = snapshot.prompt_versions[deployment.prompt_pins[prompt_name or "default"]]   # name not in prompt_pins → error
model            = snapshot.models[deployment.model_id]
params           = snapshot.use_cases[use_case].default_params <- deployment.params
provider_options = model.provider_options <- deployment.provider_options
```

Poll every 30–60 s with `If-None-Match`; keep the last good document in memory and on disk; serve it when the poll fails. A use case with no live deployment is simply absent from `deployments`; an environment with none is `{"deployments": {}, "prompt_versions": {}}`, not an error. The server caches the snapshot per environment for about 5 s, so a fresh deployment can lag that long here (never on `/resolve`).

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
- `503 unavailable` + `Retry-After` is the only status worth retrying — resend the same batch with the same ids.
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

## 6. Troubleshooting

| symptom | meaning | action |
|---|---|---|
| 401 `unauthorized` on `/api/v1/orgs…` or `/me` | no token, wrong token, revoked session (logout, device list, "Sign out everywhere" on `/account`), or a **runtime key** used on the management door | `prompton login` again (`--host` if not the default host) |
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
