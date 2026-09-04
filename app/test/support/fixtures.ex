defmodule PromptOn.Fixtures do
  @moduledoc """
  Test fixtures. Every function creates with `%PromptOn.SystemActor{}` and returns the record.
  Calls on project-scoped resources need `tenant: project.id`; see the `scope/1,2` helper.
  """

  alias PromptOn.{Accounts, Catalog, Observability, Projects, Prompts}

  def system_actor, do: PromptOn.SystemActor.new()

  def unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  @doc """
  User + personal Organization + Membership (owner). There is no password (ADR 0008: email codes
  are the only sign-in); created from just an email through `User.:register` (system actor). For a
  signed-in state use `PromptOnWeb.ConnCase.log_in_user/2`.
  """
  def user_fixture(attrs \\ %{}) do
    email = Map.get(attrs, :email, unique_email())
    {:ok, user} = Accounts.register_user(%{email: email}, actor: system_actor())
    user
  end

  @doc "The user's personal organization (created automatically at sign-up, no slug)."
  def organization_for(user) do
    {:ok, %{} = org} = Accounts.personal_organization_for(user.id, actor: system_actor())
    org
  end

  @doc """
  Team organization (globally unique slug + owner membership). Creates a new user when `attrs.user`
  is absent. Returns the organization record; when the user is needed, use the one passed as
  `attrs.user`.
  """
  def team_org_fixture(attrs \\ %{}) do
    user = Map.get_lazy(attrs, :user, fn -> user_fixture() end)
    n = System.unique_integer([:positive])

    {:ok, org} =
      Accounts.create_organization(
        %{
          name: Map.get(attrs, :name, "Team #{n}"),
          slug: Map.get(attrs, :slug, "team-#{n}")
        },
        actor: system_actor()
      )

    {:ok, _membership} =
      Accounts.add_member(
        %{organization_id: org.id, user_id: user.id, role: Map.get(attrs, :role, :owner)},
        actor: system_actor()
      )

    org
  end

  @doc """
  Sets an organization's entitlement plan (`:free | :team | :pro`). `Organization.:set_plan` is
  system-actor only, so this is the only way a test reaches a paid plan. Accepts an organization
  record, an organization id, or a project (its owning organization).
  """
  def set_plan(organization, plan) do
    record =
      Ash.get!(PromptOn.Accounts.Organization, organization_id(organization),
        actor: system_actor()
      )

    {:ok, updated} =
      Accounts.set_organization_plan(record, %{plan: plan}, actor: system_actor())

    updated
  end

  @doc """
  Project (with the default production/staging environments). Creates a new user when `attrs.user`
  is absent. `attrs.organization` picks the organization (default: the user's personal
  organization); project slugs are unique **per organization**, so use it to test slug collisions
  across organizations.
  """
  def project_fixture(attrs \\ %{}) do
    user = Map.get_lazy(attrs, :user, fn -> user_fixture() end)
    org = Map.get_lazy(attrs, :organization, fn -> organization_for(user) end)
    n = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(
        %{
          organization_id: org.id,
          name: Map.get(attrs, :name, "Project #{n}"),
          slug: Map.get(attrs, :slug, "project-#{n}")
        },
        actor: user
      )

    Ash.load!(project, [:environments], actor: system_actor(), tenant: project.id)
  end

  def environment(project, slug \\ "production") do
    Enum.find(project.environments, &(&1.slug == slug)) ||
      raise "no environment #{slug} in project #{project.slug}"
  end

  @doc """
  API key (**per project**; the environment binding was removed on 2026-09-01). Returns
  `{api_key_record, raw_key}`.
  """
  def api_key_fixture(project, opts \\ []) do
    {:ok, key} =
      Projects.issue_api_key(
        %{
          project_id: project.id,
          name: Keyword.get(opts, :name, "test key"),
          scopes: Keyword.get(opts, :scopes, [:resolve, :logs])
        },
        actor: system_actor()
      )

    {key, Ash.Resource.get_metadata(key, :raw_key)}
  end

  @doc """
  CLI session token (what `prompton login` receives at the end of device authorization). Returns
  the raw token.

  Management keys were removed on 2026-09-02; the management API's credential is the **user
  token**, and the permissions are exactly that user's organization memberships.
  """
  def cli_token_fixture(%PromptOn.Accounts.User{} = user) do
    {:ok, token, _claims} = PromptOn.Accounts.CliSession.issue(user)
    token
  end

  @doc "Call options for tenant-scoped resources."
  def scope(project, actor \\ nil), do: [tenant: project.id, actor: actor || system_actor()]

  # ---------------------------------------------------------------------------
  # Catalog / Prompts

  @doc "Catalog model (default openrouter `anthropic/claude-sonnet-4`, unique model_id)."
  def model_fixture(project, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, model} =
      Catalog.register_model(
        Map.merge(
          %{
            provider: :openrouter,
            model_id: "anthropic/claude-sonnet-4-#{n}",
            display_name: "Claude Sonnet 4 #{n}",
            metadata: %{"description_key" => "chat_model.sonnet4"},
            provider_options: %{"only" => ["Anthropic"]},
            pricing: %{
              "input_per_m" => 3.0,
              "output_per_m" => 15.0,
              "currency" => "USD",
              "unit" => "token"
            },
            capabilities: [:tools, :streaming]
          },
          attrs
        ),
        scope(project)
      )

    model
  end

  @doc "Use case (chat/fixed by default, loaded with its default Prompt `default`)."
  def use_case_fixture(project, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, use_case} =
      Prompts.define_use_case(
        Map.merge(%{key: "use_case_#{n}", name: "Use case #{n}", kind: :chat}, attrs),
        scope(project)
      )

    Ash.load!(use_case, [:prompts], scope(project))
  end

  @doc "The use case's (first) Prompt, usually `default`."
  def default_prompt(%PromptOn.Prompts.UseCase{} = use_case) do
    prompts = use_case.prompts

    prompts =
      if is_list(prompts),
        do: prompts,
        else:
          Ash.load!(use_case, [:prompts], tenant: use_case.project_id, actor: system_actor()).prompts

    Enum.find(prompts, &(&1.name == "default")) || hd(prompts)
  end

  @default_messages [
    %{role: :system, content: "You are helpful."},
    %{role: :user, content: "{{ input }}"}
  ]

  @doc """
  Commits a prompt version (immutable, ADR 0007: no publish). The first argument is a UseCase
  (→ its default Prompt) or a Prompt. Defaults to two chat messages; text use cases pass
  `attrs.text_template`.
  """
  def prompt_version_fixture(use_case_or_prompt, attrs \\ %{})

  def prompt_version_fixture(%PromptOn.Prompts.UseCase{} = use_case, attrs),
    do: prompt_version_fixture(default_prompt(use_case), attrs)

  def prompt_version_fixture(%PromptOn.Prompts.Prompt{} = prompt, attrs) do
    opts = [tenant: prompt.project_id, actor: system_actor()]

    input =
      if Map.has_key?(attrs, :text_template),
        do: Map.merge(%{prompt_id: prompt.id}, attrs),
        else: Map.merge(%{prompt_id: prompt.id, messages: @default_messages}, attrs)

    {:ok, version} = Prompts.commit_prompt_version(input, opts)
    version
  end

  @doc """
  One arena message (on the `(use case × model)` axis). Defaults to a short `role: :user` input.
  The `:actor` option swaps in an actor for policy tests; calls that expect failure invoke
  `PromptOn.Prompts.append_arena_message/2` directly (this fixture only handles success).
  """
  def arena_message_fixture(%PromptOn.Prompts.UseCase{} = use_case, model, attrs \\ %{}) do
    {actor, attrs} = Map.pop(attrs, :actor)
    n = System.unique_integer([:positive])

    {:ok, message} =
      Prompts.append_arena_message(
        Map.merge(
          %{
            use_case_id: use_case.id,
            model_id: model.id,
            role: :user,
            content: "arena input #{n}"
          },
          attrs
        ),
        tenant: use_case.project_id,
        actor: actor || system_actor()
      )

    message
  end

  @heydiary_diary_user_template ~s|{% if mode == "incremental" %}Here is the existing diary:\n\n{{ existing_diary }}\n\nAppend these new voice transcriptions:\n\n{% for t in transcriptions %}{{ forloop.index }}. {{ t }}\n\n{% endfor %}{% elsif mode == "edit" %}Edit the diary below according to the user's request.\n\n{{ user_content }}{% else %}Please write a diary entry based on these voice transcriptions:\n\n{% for t in transcriptions %}{{ forloop.index }}. {{ t }}\n\n{% endfor %}{% endif %}|

  @doc "The raw HeyDiary diary_generation user message template (for golden tests)."
  def heydiary_diary_user_template, do: @heydiary_diary_user_template

  @doc """
  A whole HeyDiary-shaped project (plan.md §6.2). Only the production environment has live
  Deployments; staging is empty.

  Deployments are **pins**: one model per use case + one version per prompt name. Only
  `diary_generation` has two prompts (`default`, `ko`), so the language branch (= prompt name
  selection) can be tested.

  Returned map:
  - `:project`, `:user`, `:production`, `:staging`
  - `:models` — `%{sonnet, mini, opus, whisper, embed}`
  - `:use_cases` — `%{diary, chat, stt, embedding}` (keys `diary_generation`, `chat_response`,
    `voice_transcription`, `diary_embedding`)
  - `:prompts` — `%{diary_default, diary_ko, chat, stt}`
  - `:prompt_versions` — `%{diary, diary_ko, chat, stt}`
  - `:deployments` — `%{diary, chat, stt, embedding}` (production live revision #1)
  """
  def heydiary_project_fixture(attrs \\ %{}) do
    user = Map.get_lazy(attrs, :user, fn -> user_fixture() end)
    n = System.unique_integer([:positive])

    project =
      project_fixture(%{
        user: user,
        slug: Map.get(attrs, :slug, "heydiary-#{n}"),
        name: "HeyDiary"
      })

    production = environment(project, "production")
    staging = environment(project, "staging")

    # --- Catalog (ai_models) -------------------------------------------------
    sonnet =
      model_fixture(project, %{
        model_id: "anthropic/claude-sonnet-4",
        display_name: "Claude Sonnet 4",
        metadata: %{"description_key" => "chat_model.sonnet4"},
        provider_options: %{"only" => ["Anthropic"]}
      })

    mini =
      model_fixture(project, %{
        model_id: "openai/gpt-5-mini",
        display_name: "GPT-5 mini",
        metadata: %{"description_key" => "chat_model.gpt5_mini"},
        provider_options: %{"only" => ["OpenAI"]},
        pricing: %{}
      })

    opus =
      model_fixture(project, %{
        model_id: "anthropic/claude-opus-4",
        display_name: "Claude Opus 4",
        metadata: %{"description_key" => "chat_model.opus4"},
        provider_options: %{"only" => ["Anthropic"]}
      })

    whisper =
      model_fixture(project, %{
        provider: :groq,
        model_id: "whisper-large-v3",
        display_name: "Whisper large v3",
        metadata: %{},
        provider_options: %{},
        pricing: %{"input_per_m" => 0.111, "unit" => "audio_second"},
        capabilities: []
      })

    embed =
      model_fixture(project, %{
        provider: :openai,
        model_id: "text-embedding-3-small",
        display_name: "Embedding 3 small",
        metadata: %{},
        provider_options: %{},
        pricing: %{},
        capabilities: []
      })

    # --- Use cases (ai_tasks) ---------------------------------------------------
    diary =
      use_case_fixture(project, %{
        key: "diary_generation",
        name: "Diary generation",
        kind: :chat,
        input_schema: [
          %{name: "transcriptions", type: :list, required?: true},
          %{name: "mode", type: :string, required?: true},
          %{name: "existing_diary", type: :string},
          %{name: "user_content", type: :string}
        ],
        default_params: %{"temperature" => 0.5}
      })

    chat =
      use_case_fixture(project, %{
        key: "chat_response",
        name: "Chat response",
        kind: :chat,
        input_schema: [%{name: "tone", type: :string}],
        default_params: %{"temperature" => 0.7}
      })

    stt =
      use_case_fixture(project, %{
        key: "voice_transcription",
        name: "Voice transcription",
        kind: :text
      })

    embedding =
      use_case_fixture(project, %{
        key: "diary_embedding",
        name: "Diary embedding",
        kind: :embedding
      })

    # --- Prompts (per name) + versions ------------------------------------------
    diary_default = default_prompt(diary)

    {:ok, diary_ko_prompt} =
      Prompts.open_prompt(%{use_case_id: diary.id, name: "ko"}, scope(project))

    diary_v1 =
      prompt_version_fixture(diary_default, %{
        messages: [
          %{role: :system, content: "You write diaries from voice transcriptions."},
          %{role: :user, content: @heydiary_diary_user_template}
        ],
        commit_message: "import from ai_tasks"
      })

    diary_ko_v1 =
      prompt_version_fixture(diary_ko_prompt, %{
        messages: [
          %{role: :system, content: "You write diaries in Korean from voice transcriptions."},
          %{role: :user, content: @heydiary_diary_user_template}
        ]
      })

    chat_v1 =
      prompt_version_fixture(chat, %{
        messages: [
          %{
            role: :system,
            content: "You are a warm diary companion.{% if tone %} Tone: {{ tone }}.{% endif %}"
          }
        ]
      })

    stt_v1 = prompt_version_fixture(stt, %{text_template: "diary, day, today's mood"})

    # --- Deployment (production): a revision is a pin, one model + one version per prompt name --
    d_diary =
      deployment_fixture(diary, production, %{
        model_id: sonnet.id,
        params: %{"temperature" => 0.4},
        provider_options: %{"allow_fallbacks" => false},
        prompt_pins: %{"default" => diary_v1.id, "ko" => diary_ko_v1.id}
      })

    d_chat =
      deployment_fixture(chat, production, %{
        model_id: mini.id,
        params: %{"max_tokens" => 1024},
        prompt_pins: %{"default" => chat_v1.id}
      })

    d_stt =
      deployment_fixture(stt, production, %{
        model_id: whisper.id,
        prompt_pins: %{"default" => stt_v1.id}
      })

    d_embedding = deployment_fixture(embedding, production, %{model_id: embed.id})

    %{
      project: project,
      user: user,
      production: production,
      staging: staging,
      models: %{sonnet: sonnet, mini: mini, opus: opus, whisper: whisper, embed: embed},
      use_cases: %{diary: diary, chat: chat, stt: stt, embedding: embedding},
      prompts: %{
        diary_default: diary_default,
        diary_ko: diary_ko_prompt,
        chat: default_prompt(chat),
        stt: default_prompt(stt)
      },
      prompt_versions: %{diary: diary_v1, diary_ko: diary_ko_v1, chat: chat_v1, stt: stt_v1},
      deployments: %{diary: d_diary, chat: d_chat, stt: d_stt, embedding: d_embedding}
    }
  end

  # ---------------------------------------------------------------------------
  # Deployments (ADR 0007 revised 2026-09-01: a revision is a pin, not a router)

  @doc """
  Commits a Deployment revision. `attrs` is passed through as
  `%{model_id:, params:, provider_options:, prompt_pins:}`. `opts` has the `scope/2` shape (default:
  system actor).
  """
  def deployment_fixture(%PromptOn.Prompts.UseCase{} = use_case, env, attrs \\ %{}, opts \\ nil) do
    opts = opts || [tenant: use_case.project_id, actor: system_actor()]

    {:ok, deployment} =
      PromptOn.Deployments.commit_deployment(
        Map.merge(%{use_case_id: use_case.id, environment_id: env.id}, attrs),
        opts
      )

    deployment
  end

  @doc """
  A Deployment that pins one model + one `default` prompt. Creates `attrs.prompt_version` /
  `attrs.model` when absent (embedding use cases get no prompt). The rest of `attrs`
  (`params` / `provider_options` / `prompt_pins`) is passed through as is.
  """
  def simple_deployment_fixture(%PromptOn.Prompts.UseCase{} = use_case, env, attrs \\ %{}) do
    project = %{id: use_case.project_id}
    {model, attrs} = Map.pop_lazy(attrs, :model, fn -> model_fixture(project) end)

    {version, attrs} =
      Map.pop_lazy(attrs, :prompt_version, fn ->
        if use_case.kind == :embedding, do: nil, else: prompt_version_fixture(use_case)
      end)

    pins = if is_nil(version), do: %{}, else: %{"default" => record_id(version)}

    deployment_fixture(
      use_case,
      env,
      Map.merge(%{model_id: record_id(model), prompt_pins: pins}, attrs)
    )
  end

  defp record_id(nil), do: nil
  defp record_id(id) when is_binary(id), do: id
  defp record_id(%{id: id}), do: id

  # ---------------------------------------------------------------------------
  # Observability

  @doc """
  A §6.4 Generation payload map (string keys). The first argument is a UseCase or a use_case key
  string. Defaults: chat, ok, `stop`, 100/20 tokens, provider cost 0.001, 2 rendered messages +
  output, current time. `attrs` (string or atom keys) is shallowly merged on top (nested maps such
  as `"usage"`, `"input"` and `"error"` are replaced whole).
  """
  def generation_payload_fixture(use_case_or_key, attrs \\ %{})

  def generation_payload_fixture(%PromptOn.Prompts.UseCase{key: key}, attrs),
    do: generation_payload_fixture(key, attrs)

  def generation_payload_fixture(use_case_key, attrs) when is_binary(use_case_key) do
    Map.merge(
      %{
        "id" => Ash.UUIDv7.generate(),
        "use_case" => use_case_key,
        "kind" => "chat",
        "model" => "anthropic/claude-sonnet-4",
        "model_used" => "anthropic/claude-sonnet-4",
        "provider" => "openrouter",
        "upstream_provider" => "Anthropic",
        "resolution_source" => "remote",
        "context" => %{"language" => "ko", "plan" => "pro"},
        "params" => %{"temperature" => 0.5},
        "input" => %{
          "variables" => %{"input" => "hello"},
          "messages" => [
            %{"role" => "system", "content" => "You are helpful."},
            %{"role" => "user", "content" => "hello"}
          ],
          "truncated" => false
        },
        "output" => %{"content" => "Hi there!", "tool_calls" => [], "truncated" => false},
        "status" => "ok",
        "finish_reason" => "stop",
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 20,
          "cost_usd" => 0.001,
          "cost_source" => "provider",
          "raw" => %{"prompt_tokens" => 100}
        },
        "latency_ms" => 1200,
        "started_at" => DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601(),
        "trace_id" => "oban:1",
        "sequence" => 1,
        "end_user_ref" => "u_1",
        "metadata" => %{"job_id" => 1},
        "sdk" => %{"name" => "prompton_sdk", "version" => "0.1.0"}
      },
      Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    )
  end

  @doc """
  Feeds a list of payloads through `PromptOn.Observability.Ingest.ingest/2`. Creates a new `:logs`
  key when `opts[:api_key]` is absent. The environment is chosen by the **caller** (`opts[:env]`,
  default `"production"`): the request decides it, not the key (2026-09-01). Returns
  `%{accepted:, duplicates:, rejected:}`.
  """
  def ingest_fixture(project, generations, opts \\ []) when is_list(generations) do
    api_key =
      Keyword.get_lazy(opts, :api_key, fn ->
        {key, _raw} = api_key_fixture(project, scopes: [:logs])
        key
      end)

    env = environment(project, Keyword.get(opts, :env, "production"))

    {:ok, result} =
      Observability.Ingest.ingest(generations,
        actor: api_key,
        tenant: project.id,
        environment_id: env.id
      )

    result
  end

  @doc """
  `count` monitoring logs of one use case **with their raw payloads stored** — the shape every
  evals and retention test needs and that `generation_payload_fixture/2` (one payload map) does
  not provide on its own.

  Ingests through the real path (`Observability.Ingest`), so `payload_state` and the encrypted
  `GenerationPayload` rows are produced exactly as a live SDK batch would produce them. Log `i` is
  `started_at = now - (count - i) minutes`, so the list comes back **oldest first** and the newest
  log is the last element.

  `attrs` is merged into every payload map (`generation_payload_fixture/2` semantics); the two
  fixture-only keys are `:env` (environment slug, default `"production"`) and `:api_key`.
  """
  def stored_generations_fixture(project, use_case, count, attrs \\ %{})
      when is_integer(count) and count > 0 do
    {env, attrs} = Map.pop(attrs, :env, "production")
    {api_key, attrs} = Map.pop(attrs, :api_key)
    now = DateTime.utc_now()

    payloads =
      for i <- 1..count do
        started = DateTime.add(now, -(count - i) * 60, :second)

        generation_payload_fixture(
          use_case,
          Map.merge(
            %{
              "id" => Ash.UUIDv7.generate(),
              "started_at" => DateTime.to_iso8601(started)
            },
            Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
          )
        )
      end

    opts = [env: env] ++ if(api_key, do: [api_key: api_key], else: [])
    %{accepted: ^count} = ingest_fixture(project, payloads, opts)

    Enum.map(payloads, fn payload ->
      {:ok, generation} = Observability.get_generation(payload["id"], scope(project))
      generation
    end)
  end

  # ---------------------------------------------------------------------------
  # ProviderKey

  @doc """
  Provider key (default openrouter/default). The first argument is the **organization** (or an
  organization id); BYOK keys are owned by the organization.
  Options: `:provider`, `:label`, `:secret`, `:actor`.
  Without `secret`, a different raw `sk-or-v1-…` value is generated every time.
  """
  def provider_key_fixture(organization, opts \\ []) do
    n = System.unique_integer([:positive])

    {:ok, key} =
      Accounts.register_provider_key(
        %{
          organization_id: organization_id(organization),
          provider: Keyword.get(opts, :provider, :openrouter),
          label: Keyword.get(opts, :label, "default"),
          secret: Keyword.get(opts, :secret, "sk-or-v1-#{String.duplicate("0", 24)}#{n}")
        },
        actor: Keyword.get(opts, :actor) || system_actor()
      )

    key
  end

  @doc "Organization record | organization id | project → organization id."
  def organization_id(%PromptOn.Accounts.Organization{id: id}), do: id
  def organization_id(%PromptOn.Projects.Project{organization_id: id}), do: id
  def organization_id(id) when is_binary(id), do: id
end
