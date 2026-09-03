defmodule PromptOnWeb.IntegrationComponents do
  @moduledoc """
  The **Integration** section of the use case hub's Deployments tab: "how do I attach this
  deployment to my app", handed whole to each of two readers. It is exactly what the user does next
  from the deployment screen.

  Both bodies teach **config-fetch + monitoring logs** (agent-first-spec §2, ADR 0001/0007):
  PromptOn does not stand in the app's request path. The app fetches the configuration, calls the
  provider **directly with its own provider key**, and reports the result back as a log. Proxy mode
  (`POST /api/v1/generate`) was removed on 2026-09-01.

  1. `#integration-curl` — a curl that a **person** pastes as is. It is a **smoke test** that
     fetches this use case's deployed configuration (model, parameters, rendered prompt) verbatim
     through `POST /api/v1/resolve`. It comes filled in with this project's real host, the chosen
     environment, the prompt name this deployment pins, and example variables built from this use
     case's `input_schema`, so it runs unchanged. Only the key is an environment variable
     (`$PTN_API_KEY`); the raw key is never drawn on the screen again (the issue screen shows it
     once).
  2. `#integration-prompt` — a brief to hand to the **user's coding AI**. It contains one paragraph
     on what PromptOn is, the two ways to fetch the configuration (`/resolve` vs `/snapshot` + a
     local cache; the latter is recommended), where to call the provider directly, the envelope for
     reporting monitoring logs (`POST /api/v1/generations`), this use case's real key, prompt names
     and variable table, an error table, and finally the "change it like this" instruction.

  The bodies are built by **pure functions** (`curl_snippet/1`, `ai_prompt/1`): they must be
  testable apart from the screen, and the two sets of wording must not drift apart. The copy button
  reuses the same colocated hook as the settings screen
  (`PromptOnWeb.SettingsComponents.copy_button/1`).
  """

  use PromptOnWeb, :html

  alias PromptOnWeb.SettingsComponents, as: SC

  @default_prompt "default"

  # The free plan's monitoring log quota (agent-first-spec §6). Not enforced yet; it is switched on
  # when billing arrives.
  @free_log_quota "10,000 logs / month, 7-day retention"

  @typedoc """
  The ingredients both bodies share.

  * `:host` — `https://app.example.com` (with scheme, no trailing slash)
  * `:use_case_key`, `:kind` — this use case
  * `:environment` — the currently selected environment slug
  * `:prompts` — the prompt names this deployment pins (`[]` when none)
  * `:variables` — `input_schema` as is (`%{name:, type:, required?:, description:, example:}`)
  """
  @type spec :: %{
          host: String.t(),
          use_case_key: String.t(),
          kind: atom(),
          environment: String.t(),
          prompts: [String.t()],
          variables: [map()]
        }

  # ---------------------------------------------------------------------------
  # Bodies (pure functions)

  @doc """
  curl snippet: a smoke test that fetches the deployed configuration verbatim through
  `POST /api/v1/resolve`. Example variables use the declared `example` first and otherwise a
  placeholder matching the type.

      iex> PromptOnWeb.IntegrationComponents.curl_snippet(%{
      ...>   host: "https://app.example.com", use_case_key: "diary", kind: :chat,
      ...>   environment: "production", prompts: ["default"], variables: []
      ...> }) =~ "https://app.example.com/api/v1/resolve"
      true
  """
  @spec curl_snippet(spec()) :: String.t()
  def curl_snippet(spec) do
    body =
      spec
      |> request_example()
      |> Jason.encode!(pretty: true)

    """
    curl -sS -X POST #{spec.host}/api/v1/resolve \\
      -H "Authorization: Bearer $PTN_API_KEY" \\
      -H "Content-Type: application/json" \\
      -d '#{body}'\
    """
  end

  @doc """
  Example `POST /resolve` request. It is a `Jason.OrderedObject` because of **order**: if Jason
  sorted the map keys, `use_case` would be pushed into the middle and the reader's eye would not
  meet the head of the contract first.
  """
  @spec request_example(spec()) :: Jason.OrderedObject.t()
  def request_example(spec) do
    values =
      [
        {"use_case", spec.use_case_key},
        {"environment", spec.environment}
      ] ++ prompt_entry(spec) ++ variables_entry(spec)

    %Jason.OrderedObject{values: values}
  end

  # Kind embedding pins no prompt, so there is no name to send either.
  defp prompt_entry(%{kind: :embedding}), do: []
  defp prompt_entry(spec), do: [{"prompt", first_prompt(spec.prompts)}]

  defp variables_entry(%{variables: variables}) do
    case required_examples(variables) do
      example when example == %{} -> []
      example -> [{"variables", example}]
    end
  end

  defp required_examples(variables) do
    variables
    |> List.wrap()
    |> Enum.filter(& &1.required?)
    |> Map.new(&{to_string(&1.name), example_value(&1)})
  end

  @doc """
  Example value for one variable: the declared `example` as is when present, otherwise a type
  placeholder.

      iex> PromptOnWeb.IntegrationComponents.example_value(%{name: "tone", type: :string, example: nil})
      "<tone>"

      iex> PromptOnWeb.IntegrationComponents.example_value(%{name: "n", type: :number, example: nil})
      0
  """
  @spec example_value(map()) :: term()
  def example_value(%{example: example}) when is_binary(example) and example != "" do
    case Jason.decode(example) do
      {:ok, decoded} when is_list(decoded) or is_map(decoded) or is_number(decoded) -> decoded
      _other -> example
    end
  end

  def example_value(%{name: name, type: :list}), do: ["<#{name}>"]
  def example_value(%{type: :map}), do: %{}
  def example_value(%{type: :number}), do: 0
  def example_value(%{type: :boolean}), do: false
  def example_value(%{name: name}), do: "<#{name}>"

  @doc """
  The integration brief pasted whole to a coding AI (in English). It carries this use case's real
  key, prompt names and variable table.

      iex> PromptOnWeb.IntegrationComponents.ai_prompt(%{
      ...>   host: "https://app.example.com", use_case_key: "diary", kind: :chat,
      ...>   environment: "production", prompts: ["default", "ko"], variables: []
      ...> }) =~ ~s|"use_case": "diary"|
      true
  """
  @spec ai_prompt(spec()) :: String.t()
  def ai_prompt(spec) do
    """
    Integrate this application with PromptOn.

    ## What PromptOn is

    PromptOn is a control plane for prompts and models, and **it is not in your request path**. The \
    prompt text, the model id and its parameters live in PromptOn and are deployed per environment; \
    this app fetches that configuration and then calls the model provider **itself, with its own \
    provider credentials**. PromptOn never sees your provider key, never proxies the call, and adds \
    no latency to it — if PromptOn is unreachable the app keeps running on the configuration it \
    already holds. Changing a prompt or swapping a model later is a deploy in PromptOn, not a code \
    change here.

    So there are exactly two integration points:

    1. **Config fetch** — read the deployed pin (prompt version + model + params) for a use case.
    2. **Monitoring logs** — after each provider call, report what happened back to PromptOn.

    Both use the same credential: `Authorization: Bearer $PTN_API_KEY`, read from the \
    environment. Never hard-code it and never ship it to a browser — both calls belong on the \
    server side. The key is scoped: `resolve` covers config fetch, `logs` covers monitoring logs.

    All responses are JSON with snake_case keys. Every failure is \
    `{"error": {"code": "…", "message": "…", "details": {…}}}` with a standard HTTP status.

    ## 1. Config fetch — two options

    ### (a) `POST #{spec.host}/api/v1/resolve` — one call per resolution

    PromptOn resolves the pin server-side and (if you send `variables`) renders the template for you.

    ```json
    #{spec |> request_example() |> Jason.encode!(pretty: true)}
    ```

    | field | required | meaning |
    |---|---|---|
    | `use_case` | yes | `"#{spec.use_case_key}"` for this integration |
    | `environment` | no | environment slug, default `"production"` (this deployment: `"#{spec.environment}"`) |
    | `prompt` | no | which named prompt to use, default `"default"`#{prompt_note(spec.prompts)} |
    | `variables` | no | template variables; when present the response is **rendered**, when absent you get the raw template |

    Response 200:

    ```json
    {"use_case": "#{spec.use_case_key}", "kind": "#{spec.kind}",
     "deployment": {"id": "…", "revision": 12},
    #{resolve_prompt_line(spec)}
     "model_id": "…", "model": "anthropic/claude-sonnet-4", "provider": "openrouter",
     "effective_params": {"temperature": 0.4},
     "effective_provider_options": {"allow_fallbacks": false},
    #{resolve_pin_lines(spec.kind)}
     "warnings": [], "etag": "sha256-…"}
    ```

    Correct, but it puts a PromptOn round-trip in front of every generation — exactly what this \
    architecture exists to avoid. Use it for smoke tests, prototypes and low-volume paths.

    ### (b) `GET #{spec.host}/api/v1/snapshot?environment=#{spec.environment}` + a local cache — **use this in production**

    One document holds every live deployment of that environment, so resolution becomes a map lookup \
    in this process. The response carries a strong `ETag`; poll on an interval (30–60s is plenty) \
    with `If-None-Match: "<etag>"` and an unchanged snapshot answers `304` with no body.

    ```
    GET #{spec.host}/api/v1/snapshot?environment=#{spec.environment}
    Authorization: Bearer $PTN_API_KEY
    If-None-Match: "sha256-…"
    ```

    Keep the last successful document in memory, and also write it to disk so a cold start survives \
    PromptOn being down. Never fail a generation because the poll failed — serve the cached document.

    Resolve locally:

    ```
    deployment = snapshot.deployments[use_case_key]        # missing => no live deployment
    version    = snapshot.prompt_versions[deployment.prompt_pins[prompt_name]]
    model      = snapshot.models[deployment.model_id]

    params           = snapshot.use_cases[use_case_key].default_params <- deployment.params
    provider_options = model.provider_options                          <- deployment.provider_options
    ```

    (`<-` is a shallow merge, right-hand side wins.) `version` gives you `messages` (chat) or \
    `text_template` (text) plus `engine`: `"liquid"` means render `{{ variable }}` placeholders, \
    `"raw"` means send the text verbatim. A `prompt` name that is not a key of `prompt_pins` is an \
    **error, not a silent fallback** — the pinned names are the whole selection axis.

    ## 2. Call the provider yourself

    Render the pinned prompt with this call's variables, then call the provider named by \
    `model.provider` with `model.model_id`, the effective params and the effective provider options, \
    using **this app's** provider credentials. Measure the wall-clock latency and keep the token \
    usage and cost the provider reports — step 3 wants them.

    #{kind_note(spec.kind)}

    ## 3. Report monitoring logs

        POST #{spec.host}/api/v1/generations?environment=#{spec.environment}
        Authorization: Bearer $PTN_API_KEY
        Content-Type: application/json

    ```json
    {"generations": [
      {"id": "<UUIDv7 generated by this app>",
       "use_case": "#{spec.use_case_key}",
       "deployment_id": "…", "deployment_revision": 12,
    #{log_pin_line(spec)}
       "kind": "#{spec.kind}", "model": "anthropic/claude-sonnet-4", "provider": "openrouter",
       "params": {"temperature": 0.4},
       "input": {"variables": {}, "messages": [{"role": "system", "content": "…"}]},
       "output": {"content": "…"},
       "status": "ok", "finish_reason": "stop", "stop_kind": "stop",
       "usage": {"input_tokens": 1830, "output_tokens": 412, "cost_usd": 0.00312},
       "latency_ms": 4180, "started_at": "2026-09-01T09:12:03.123Z",
       "trace_id": "job:88213", "end_user_ref": "u_…", "metadata": {}}
    ]}
    ```

    Required per record: `id`, `use_case`, `model`, `status` (`"ok"` or `"error"`), `started_at` \
    (ISO 8601 UTC). Everything else is optional but each field you drop is a column of the dashboard \
    you lose. On failure send `status: "error"` plus \
    `error: {"kind": "http_4xx|http_5xx|rate_limited|timeout|transport|parse|app", "status": 429, "message": "…"}` \
    — failed calls are the whole point of monitoring, so report them too.

    Rules that matter:

    - **Idempotency.** `id` is a **UUIDv7 this app generates** before the provider call, and it is the \
    idempotency key: resending the same id is absorbed as a duplicate, never a second row. Generate \
    it once, log it locally, and reuse it on every retry.
    - **Batching.** Up to **200 records** and **5MB** per request; over either limit is `413`. Buffer \
    records and flush on a size or time trigger rather than one HTTP call per generation.
    - **Partial acceptance.** `202 {"accepted": 98, "duplicates": 2, "rejected": [{"index": 5, "id": "…", "code": "…", "message": "…"}]}`. \
    One bad record never fails the batch — read `rejected`, fix or drop those, and do not resend the \
    accepted ones.
    - **Retry.** `503 unavailable` (with `Retry-After`) is the only status worth retrying; resend the \
    same batch with the same ids and duplicates are absorbed.
    - **Environment.** The `environment` query parameter (default `production`) is forced on the whole \
    batch; whatever a record claims is ignored. Send one batch per environment.
    - **Freshness.** `started_at` must be within 5 minutes of the future and 7 days of the past.
    - **Size caps.** `context` ≤ 2KB and `metadata` ≤ 4KB or the record is rejected. `params` > 4KB and \
    `usage.raw` > 16KB are not rejected — the field is blanked and named in `metadata.truncated_fields`.
    - **Truncate payloads before sending.** Relative to the use case's `payload_policy.max_bytes` \
    (default 256KB, it travels in the snapshot): one message's `content` ≤ `max_bytes/8`; \
    `input.messages` and `input.text` and `input.variables` ≤ `max_bytes` each; `output.content` and \
    `output.tool_calls` ≤ `max_bytes/4`. Cut the middle, keep head and tail, and set \
    `"truncated": true` on that `input`/`output` object. The server re-checks with the same rules.

    Free plan includes a monthly monitoring-log quota (#{@free_log_quota}); it is not enforced yet and \
    will be when billing ships. Nothing else about this integration changes.

    ## This use case

    Key `#{spec.use_case_key}`, kind `#{spec.kind}`, environment `#{spec.environment}`. \
    Prompts pinned by this deployment: #{prompt_list(spec.prompts)}.

    #{variable_table(spec.variables)}

    ## Errors

    | status | `code` | what to do |
    |---|---|---|
    | 400 | `invalid_request` | the request is wrong — a missing template variable is named in `details.missing_variable`. Fix the call; do not retry. |
    | 401 | `unauthorized` | the API key is missing, wrong, revoked, or its project is archived. |
    | 403 | `forbidden` | the key lacks the scope this endpoint needs (`resolve` or `logs`). |
    | 404 | `not_found` | unknown `use_case` or `environment`; no live deployment (`details.reason = "unresolved"`); or a `prompt` name that is not pinned (`details.reason = "unknown_prompt"`, `details.available_prompts` lists the ones that are). |
    | 413 | `payload_too_large` | the batch is over 200 records or 5MB — split it in half and resend. |
    | 503 | `unavailable` | PromptOn is degraded. Honour `Retry-After`. **Config fetch must fall back to the cached snapshot; a generation must never fail because PromptOn did.** |

    ## Task

    Find where this codebase calls an LLM for "#{spec.use_case_key}" (or where that call should be \
    added) and rework it as follows. Fetch the configuration from PromptOn — snapshot + local cache \
    with ETag polling unless the volume is genuinely trivial — and delete the hard-coded prompt text, \
    model name and parameters from this repo, building the `variables` from the data that used to be \
    interpolated into the prompt. Keep calling the provider from this app with its existing \
    credentials. Then add the monitoring-log report: generate the UUIDv7 up front, buffer the records, \
    and POST them in batches. Handle the errors above, keep the surrounding function's signature so \
    callers do not change, and make sure a PromptOn outage degrades to the cached configuration \
    instead of an exception.
    """
  end

  defp prompt_note([]), do: ""

  defp prompt_note(names),
    do: ". This deployment pins: " <> Enum.map_join(names, ", ", &"`#{&1}`")

  defp prompt_list([]), do: "none (this deployment pins no prompt)"
  defp prompt_list(names), do: Enum.map_join(names, ", ", &"`#{&1}`")

  # An embedding use case pins no prompt, so there is no chosen name either.
  defp resolve_prompt_line(%{kind: :embedding}), do: ~s| "prompts": [],|

  defp resolve_prompt_line(spec),
    do:
      ~s| "prompt": "#{first_prompt(spec.prompts)}", "prompts": | <>
        Jason.encode!(spec.prompts) <> ","

  # The lines of the `/resolve` response that differ per kind (chat has messages, text has text,
  # embedding has no prompt at all).
  defp resolve_pin_lines(:chat) do
    ~s| "prompt_version": {"id": "…", "number": 7},\n| <>
      ~s| "messages": [{"role": "system", "content": "…"}, {"role": "user", "content": "…"}],|
  end

  defp resolve_pin_lines(:text),
    do: ~s| "prompt_version": {"id": "…", "number": 7},\n| <> ~s| "text": "…",|

  defp resolve_pin_lines(_kind), do: ~s| "prompt_version": null,|

  # The line of the monitoring log example that points at the resolution source; an embedding use
  # case has no prompt.
  defp log_pin_line(%{kind: :embedding}), do: ~s|   "resolution_source": "remote",|

  defp log_pin_line(spec) do
    ~s|   "prompt": "#{first_prompt(spec.prompts)}", "prompt_version_id": "…",\n| <>
      ~s|   "resolution_source": "remote",|
  end

  defp kind_note(:chat),
    do:
      "This is a `chat` use case: the pinned version is a list of messages. Render each " <>
        "`content`, keep the roles as they are, and append this call's own user turn after them."

  defp kind_note(:text),
    do:
      "This is a `text` use case: the pinned version is a single template, not a message list. " <>
        "Render it and send it as the whole prompt (as one user message for chat-only providers)."

  defp kind_note(_kind),
    do:
      "This is an `embedding` use case: the deployment pins a model only, no prompt. " <>
        "Fetch the model and its params and embed the input text directly."

  @doc "Variable table (markdown). When empty, says so in one line."
  @spec variable_table([map()]) :: String.t()
  def variable_table([]), do: "This use case declares no variables."

  def variable_table(variables) do
    rows =
      Enum.map_join(variables, "\n", fn variable ->
        "| `#{variable.name}` | #{variable.type} | #{required_label(variable)} | #{describe(variable)} |"
      end)

    """
    | name | type | required | description |
    |---|---|---|---|
    #{rows}\
    """
  end

  defp required_label(%{required?: true}), do: "yes"
  defp required_label(_variable), do: "no"

  defp describe(%{description: description}) when is_binary(description) and description != "",
    do: String.replace(description, "|", "\\|")

  defp describe(%{example: example}) when is_binary(example) and example != "",
    do: "e.g. " <> String.replace(example, "|", "\\|")

  defp describe(_variable), do: "—"

  defp first_prompt([]), do: @default_prompt
  defp first_prompt(names), do: if(@default_prompt in names, do: @default_prompt, else: hd(names))

  # ---------------------------------------------------------------------------
  # Components

  @doc """
  The whole Integration section: one curl card + one AI brief card. Both have a copy button at the
  top right. `spec` is `t:spec/0` above.
  """
  attr :spec, :map, required: true
  attr :api_keys_path, :string, required: true

  def integration_section(assigns) do
    assigns =
      assigns
      |> assign(:curl, curl_snippet(assigns.spec))
      |> assign(:ai, ai_prompt(assigns.spec))

    ~H"""
    <div id="integration" style="display:flex;flex-direction:column;gap:9px;min-width:0;">
      <div style="display:flex;align-items:center;gap:8px;">
        <span class="mono-label">Integration</span>
        <.link
          id="integration-keys-link"
          navigate={@api_keys_path}
          style="font-size:12px;color:var(--link);text-decoration:none;margin-left:auto;"
        >
          API keys →
        </.link>
      </div>

      <.snippet_card
        id="integration-curl"
        title="Smoke-test the deployed config"
        sub="Returns the model, params and prompt this deployment pins. Set PTN_API_KEY to a key of this project first."
        text={@curl}
      />

      <.snippet_card
        id="integration-prompt"
        title="Hand this to your coding AI"
        sub="A complete brief: fetch the config, call your own provider, report monitoring logs."
        text={@ai}
        scroll_h={260}
      />
    </div>
    """
  end

  @doc "One `<pre>` card with a copy button."
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :sub, :string, default: nil
  attr :text, :string, required: true
  attr :scroll_h, :integer, default: nil

  def snippet_card(assigns) do
    ~H"""
    <div id={@id} class="card2" style="padding:11px 13px;display:flex;flex-direction:column;gap:8px;">
      <div style="display:flex;align-items:flex-start;gap:8px;">
        <div style="min-width:0;">
          <div style="font-size:13.5px;font-weight:600;color:var(--tx-0);">{@title}</div>
          <div :if={@sub} style="font-size:12px;color:var(--tx-3);margin-top:2px;line-height:1.5;">
            {@sub}
          </div>
        </div>
        <span style="margin-left:auto;flex-shrink:0;">
          <SC.copy_button id={"copy-#{@id}"} text={@text} title="Copy" />
        </span>
      </div>
      <div style={
        DS.style_list([
          "background:var(--bg-1);border:1px solid var(--line-2);border-radius:var(--r);padding:9px 11px;",
          "overflow:auto;",
          @scroll_h && "max-height:#{@scroll_h}px;"
        ])
      }>
        <DS.code_block text={@text} size={12} wrap={false} />
      </div>
    </div>
    """
  end
end
