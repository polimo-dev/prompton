# Development seeds. Run with:
#
#     mix run priv/repo/seeds.exs
#
# Idempotent — does nothing when the heydiary project already has use cases.
# Every write goes through `%PromptOn.SystemActor{}` (policy bypass; the caller is recorded in the
# logs).
#
# What it creates: a development sign-in account + a HeyDiary-shaped project (8 models, 9 use
# cases, committed prompt versions, live production/staging Deployments — **one pin** per revision
# (1 model + one version per prompt name)).
# The contents follow the mockup `design/mockup/app/data.jsx` — the goal is to have the screens run
# on believable data. Model prices are example values (unrelated to actual billing).

require Logger

alias PromptOn.{Accounts, Catalog, Deployments, Projects, Prompts}

actor = PromptOn.SystemActor.new()
opts = [actor: actor]

unwrap = fn
  {:ok, value} -> value
  {:error, error} -> raise "seed failed: #{Exception.message(error)}"
end

# ---------------------------------------------------------------------------
# 1. Development sign-in

# Sign-in is nothing but a 6-digit code sent by email (ADR 0008) — the account is created from an
# email alone, and in dev the code email lands in `/dev/mailbox` (a real email goes out when
# `PTN_RESEND_API_KEY` is set).
dev_email = "dev@prompton.local"

user =
  case Accounts.get_user_by_email("ys@example.com", opts) do
    {:ok, %{} = user} ->
      user

    _ ->
      case Accounts.get_user_by_email(dev_email, opts) do
        {:ok, %{} = user} -> user
        _ -> unwrap.(Accounts.register_user(%{email: dev_email}, opts))
      end
  end

credentials =
  "Sign in at /sign-in with #{user.email} using the 6-digit code we email; in dev the code " <>
    "appears at /dev/mailbox unless PTN_RESEND_API_KEY is set."

[membership | _] =
  unwrap.(
    Accounts.list_memberships(
      Keyword.merge(opts, query: [filter: [user_id: user.id]], load: [:organization])
    )
  )

organization = membership.organization

# ---------------------------------------------------------------------------
# 2. Project + environments

project =
  case Projects.get_project_by_slug(organization.id, "heydiary", opts) do
    {:ok, %{} = project} ->
      project

    _ ->
      unwrap.(
        Projects.create_project(
          %{
            organization_id: organization.id,
            name: "HeyDiary",
            slug: "heydiary",
            timezone: "Asia/Seoul"
          },
          opts
        )
      )
  end

tenant = [tenant: project.id, actor: actor]

environments = unwrap.(Projects.list_environments(tenant))

environments =
  if Enum.any?(environments, &(&1.slug == "development")) do
    environments
  else
    dev_env =
      unwrap.(
        Projects.add_environment(
          %{slug: "development", name: "Development", protected?: false, position: 2},
          tenant
        )
      )

    environments ++ [dev_env]
  end

env = fn slug -> Enum.find(environments, &(&1.slug == slug)) end
production = env.("production")
staging = env.("staging")

# Idempotency guard — stop here when use cases already exist.
existing_use_cases = unwrap.(Prompts.list_use_cases(tenant))

if existing_use_cases != [] do
  Logger.info("""
  [seeds] the heydiary project already has #{length(existing_use_cases)} use case(s); skipping.
  [seeds] sign-in: #{credentials}
  """)
else
  # -------------------------------------------------------------------------
  # 3. Model catalog (data.jsx MODELS)

  register_model = fn attrs -> unwrap.(Catalog.register_model(attrs, tenant)) end

  sonnet4 =
    register_model.(%{
      provider: :openrouter,
      model_id: "anthropic/claude-sonnet-4",
      display_name: "Claude Sonnet 4",
      metadata: %{"description_key" => "model.sonnet4.desc"},
      provider_options: %{"only" => ["Anthropic"]},
      pricing: %{
        "input_per_m" => 3.0,
        "output_per_m" => 15.0,
        "currency" => "USD",
        "unit" => "token"
      },
      context_length: 200_000,
      capabilities: [:tools, :streaming]
    })

  haiku =
    register_model.(%{
      provider: :openrouter,
      model_id: "anthropic/claude-3-5-haiku",
      display_name: "Claude Haiku 3.5",
      metadata: %{"description_key" => "model.haiku.desc"},
      provider_options: %{"only" => ["Anthropic"]},
      pricing: %{
        "input_per_m" => 0.8,
        "output_per_m" => 4.0,
        "currency" => "USD",
        "unit" => "token"
      },
      context_length: 200_000,
      capabilities: [:streaming]
    })

  gpt5_mini =
    register_model.(%{
      provider: :openrouter,
      model_id: "openai/gpt-5-mini",
      display_name: "GPT-5 mini",
      metadata: %{"description_key" => "model.gpt5mini.desc"},
      provider_options: %{"only" => ["OpenAI"]},
      pricing: %{
        "input_per_m" => 0.25,
        "output_per_m" => 2.0,
        "currency" => "USD",
        "unit" => "token"
      },
      context_length: 128_000,
      capabilities: [:tools, :streaming]
    })

  gpt5 =
    register_model.(%{
      provider: :openrouter,
      model_id: "openai/gpt-5",
      display_name: "GPT-5",
      provider_options: %{"only" => ["OpenAI"]},
      pricing: %{
        "input_per_m" => 1.25,
        "output_per_m" => 10.0,
        "currency" => "USD",
        "unit" => "token"
      },
      context_length: 256_000,
      capabilities: [:tools, :streaming, :reasoning]
    })

  register_model.(%{
    provider: :openrouter,
    model_id: "google/gemini-2.5-flash",
    display_name: "Gemini 2.5 Flash",
    pricing: %{
      "input_per_m" => 0.3,
      "output_per_m" => 2.5,
      "currency" => "USD",
      "unit" => "token"
    },
    context_length: 1_000_000,
    capabilities: [:streaming]
  })

  register_model.(%{
    provider: :openrouter,
    model_id: "meta-llama/llama-3.3-70b",
    display_name: "Llama 3.3 70B",
    pricing: %{
      "input_per_m" => 0.12,
      "output_per_m" => 0.3,
      "currency" => "USD",
      "unit" => "token"
    },
    context_length: 128_000,
    capabilities: [:streaming]
  })

  whisper =
    register_model.(%{
      provider: :groq,
      model_id: "whisper-large-v3",
      display_name: "Whisper large v3",
      pricing: %{"input_per_m" => 0.111, "currency" => "USD", "unit" => "audio_second"},
      capabilities: []
    })

  embed =
    register_model.(%{
      provider: :openai,
      model_id: "text-embedding-3-small",
      display_name: "text-embedding-3-small",
      pricing: %{"input_per_m" => 0.02, "currency" => "USD", "unit" => "token"},
      context_length: 8_000,
      capabilities: []
    })

  # -------------------------------------------------------------------------
  # 4. Use cases (data.jsx USE_CASES)

  define_use_case = fn attrs -> unwrap.(Prompts.define_use_case(attrs, tenant)) end

  voice_transcription =
    define_use_case.(%{
      key: "voice_transcription",
      name: "Voice transcription",
      kind: :text,
      input_schema: [%{name: "language", type: :string, required?: true}]
    })

  transcript_revision =
    define_use_case.(%{
      key: "transcript_revision",
      name: "Transcript revision",
      kind: :chat,
      input_schema: [
        %{name: "transcript", type: :string, required?: true},
        %{name: "language", type: :string}
      ]
    })

  diary_generation =
    define_use_case.(%{
      key: "diary_generation",
      name: "Diary generation",
      kind: :chat,
      input_schema: [
        %{name: "transcriptions", type: :list, required?: true},
        %{name: "mode", type: :string, required?: true},
        %{name: "language", type: :string, required?: true},
        %{name: "previous_diary", type: :string}
      ],
      default_params: %{"temperature" => 0.8, "max_tokens" => 1200}
    })

  diary_content_removal =
    define_use_case.(%{
      key: "diary_content_removal",
      name: "Diary content removal",
      kind: :chat,
      input_schema: [
        %{name: "diary", type: :string, required?: true},
        %{name: "target", type: :string, required?: true}
      ]
    })

  mood_inference =
    define_use_case.(%{
      key: "mood_inference",
      name: "Mood inference",
      kind: :chat,
      input_schema: [%{name: "diary", type: :string, required?: true}],
      default_params: %{"temperature" => 0, "max_tokens" => 8}
    })

  chat_response =
    define_use_case.(%{
      key: "chat_response",
      name: "Chat response",
      kind: :chat,
      input_schema: [
        %{name: "history", type: :list, required?: true},
        %{name: "diaries", type: :list},
        %{name: "language", type: :string}
      ],
      default_params: %{"temperature" => 0.7, "max_tokens" => 900}
    })

  memory_extraction =
    define_use_case.(%{
      key: "memory_extraction",
      name: "Memory extraction",
      kind: :chat,
      input_schema: [%{name: "messages", type: :list, required?: true}]
    })

  diary_search_content =
    define_use_case.(%{
      key: "diary_search_content",
      name: "Diary search content",
      kind: :chat,
      input_schema: [%{name: "query", type: :string, required?: true}]
    })

  diary_embedding =
    define_use_case.(%{
      key: "diary_embedding",
      name: "Diary embedding",
      kind: :embedding,
      input_schema: [%{name: "text", type: :string, required?: true}]
    })

  # -------------------------------------------------------------------------
  # 5. Prompt versions (data.jsx PROMPT_VERSIONS — verbatim)

  default_prompt = fn use_case ->
    use_case
    |> Ash.load!([:prompts], tenant)
    |> Map.fetch!(:prompts)
    |> Enum.find(&(&1.name == "default"))
  end

  # Versions are immutable from birth (ADR 0007) — Save = commit. There is no draft/publish/archive
  # state.
  commit_version = fn use_case, attrs ->
    prompt = default_prompt.(use_case)
    unwrap.(Prompts.commit_prompt_version(Map.put(attrs, :prompt_id, prompt.id), tenant))
  end

  diary_system_v7 = """
  You are a thoughtful diary editor. Convert messy voice transcriptions into a natural first-person diary entry.

  Rules:
  1. Preserve the writer's emotions, intent and every factual detail. Never invent events.
  2. Keep the authentic voice.
  3. Continuous first-person prose. No headings, no lists.
  4. Write in {{ language }}.\
  """

  diary_system_v8 = """
  You are a thoughtful diary editor. Convert messy voice transcriptions into a natural first-person diary entry.

  Rules:
  1. Preserve the writer's emotions, intent and every factual detail. Never invent events.
  2. Keep the authentic voice. Fix grammar and flow lightly.
  3. Continuous first-person prose. No headings, no lists.
  4. Write in {{ language }}.\
  """

  diary_user =
    ~s|{% if mode == "incremental" %}Here is the diary so far:\n{{ previous_diary }}\n\nAppend the new material below.{% else %}Write a diary entry from the material below.{% endif %}\n\n{% for t in transcriptions %}- {{ t }}\n{% endfor %}|

  # v1 (mockup v6) — an old version that stays in the history
  diary_generation
  |> commit_version.(%{
    commit_message: "Add length constraint",
    messages: [
      %{
        role: :system,
        content:
          "You are a diary editor. Rewrite transcriptions as a first-person diary entry of 80–140 words."
      },
      %{role: :user, content: "{% for t in transcriptions %}- {{ t }}\n{% endfor %}"}
    ]
  })

  # v2 (mockup v7) — the version the deployment points at
  diary_v7 =
    diary_generation
    |> commit_version.(%{
      commit_message: "Add emotion-preservation rule",
      messages: [
        %{role: :system, content: diary_system_v7},
        %{role: :user, content: diary_user}
      ]
    })

  # v3 (mockup v8) — the latest commit (no deployment points at it yet)
  diary_generation
  |> commit_version.(%{
    commit_message: "Tidy up tone",
    messages: [
      %{role: :system, content: diary_system_v8},
      %{role: :user, content: diary_user}
    ]
  })

  # mood_inference: 1 old version + 1 version the deployment points at
  mood_inference
  |> commit_version.(%{
    commit_message: "Clarify the range description",
    messages: [
      %{role: :system, content: "Infer mood as an integer -3..3."},
      %{role: :user, content: "{{ diary }}"}
    ]
  })

  mood_v3 =
    mood_inference
    |> commit_version.(%{
      commit_message: "Force integer-only output",
      messages: [
        %{
          role: :system,
          content:
            "Infer the writer's mood from the diary entry. Reply with a single integer from -3 (very negative) to 3 (very positive). Output the integer only — no words, no punctuation."
        },
        %{role: :user, content: "{{ diary }}"}
      ]
    })

  chat_v9 =
    chat_response
    |> commit_version.(%{
      commit_message: "Tidy up tool-usage guidance",
      messages: [
        %{
          role: :system,
          content:
            "You are the user's diary companion. Answer using their diary entries when relevant. Be warm, concrete and brief.\n\nReply in {{ language }}."
        },
        %{
          role: :user,
          content: "{% for m in history %}{{ m.role }}: {{ m.content }}\n{% endfor %}"
        }
      ]
    })

  stt_v4 =
    voice_transcription
    |> commit_version.(%{
      commit_message: "Add proper-noun hint",
      text_template:
        "This is a diary voice memo. Transcribe the colloquial Korean speech as spoken, and keep personal and place names in their original form."
    })

  revision_v1 =
    transcript_revision
    |> commit_version.(%{
      commit_message: "Initial version",
      messages: [
        %{
          role: :system,
          content:
            "Clean up the raw voice transcript below. Fix obvious mishearings and punctuation, keep every fact and the speaker's wording. Answer in {{ language }} with the corrected transcript only."
        },
        %{role: :user, content: "{{ transcript }}"}
      ]
    })

  removal_v1 =
    diary_content_removal
    |> commit_version.(%{
      commit_message: "Initial version",
      messages: [
        %{
          role: :system,
          content:
            "Remove the requested content from the diary entry. Keep everything else word for word. Output the edited diary only."
        },
        %{role: :user, content: "Diary:\n{{ diary }}\n\nRemove: {{ target }}"}
      ]
    })

  memory_v1 =
    memory_extraction
    |> commit_version.(%{
      commit_message: "Initial version",
      messages: [
        %{
          role: :system,
          content:
            "Extract durable facts about the user from the conversation. One fact per line, no commentary. Skip anything transient."
        },
        %{
          role: :user,
          content: "{% for m in messages %}{{ m.role }}: {{ m.content }}\n{% endfor %}"
        }
      ]
    })

  search_v1 =
    diary_search_content
    |> commit_version.(%{
      commit_message: "Initial version",
      messages: [
        %{
          role: :system,
          content:
            "Rewrite the user's question into a short search query over their diary entries. Output the query only."
        },
        %{role: :user, content: "{{ query }}"}
      ]
    })

  # Language branching is entirely the **prompt name** (ADR 0007 revision 2026-09-01) — the app
  # sends `prompt: "ko"`.
  diary_ko_prompt =
    unwrap.(
      Prompts.open_prompt(
        %{
          use_case_id: diary_generation.id,
          name: "ko",
          description: "Korean diary (the app picks it with prompt: \"ko\")"
        },
        tenant
      )
    )

  diary_ko_v1 =
    unwrap.(
      Prompts.commit_prompt_version(
        %{
          prompt_id: diary_ko_prompt.id,
          commit_message: "Korean first edition",
          messages: [
            %{
              role: :system,
              content:
                String.replace(
                  diary_system_v7,
                  "Write in {{ language }}.",
                  "Always write in Korean."
                )
            },
            %{role: :user, content: diary_user}
          ]
        },
        tenant
      )
    )

  # -------------------------------------------------------------------------
  # 6. Deployments (data.jsx RELEASES → ADR 0007 revision 2026-09-01) — the commit is what goes
  #    live. A revision is a **pin**, not a router: one model + one version per prompt name.
  #    No rules, conditions, targets, weights, A/B or context dimensions — the only selection axis
  #    at request time is the prompt name.

  pin = fn use_case, environment, attrs ->
    unwrap.(
      Deployments.commit_deployment(
        Map.merge(%{use_case_id: use_case.id, environment_id: environment.id}, attrs),
        tenant
      )
    )
  end

  diary_params = %{"temperature" => 0.8, "max_tokens" => 1200}
  mood_params = %{"temperature" => 0, "max_tokens" => 8}
  chat_params = %{"temperature" => 0.7, "max_tokens" => 900}
  anthropic_only = %{"only" => ["Anthropic"]}

  # Only diary_generation has two prompts — a deployment pins **every** committed prompt.
  diary_pins = %{"default" => diary_v7.id, "ko" => diary_ko_v1.id}

  pin.(diary_generation, production, %{
    model_id: sonnet4.id,
    params: diary_params,
    provider_options: anthropic_only,
    prompt_pins: diary_pins
  })

  # staging runs the same versions on a cheaper model (the environment is picked by a request
  # parameter).
  pin.(diary_generation, staging, %{
    model_id: gpt5_mini.id,
    params: diary_params,
    prompt_pins: diary_pins
  })

  pin.(chat_response, production, %{
    model_id: gpt5.id,
    params: chat_params,
    prompt_pins: %{"default" => chat_v9.id}
  })

  pin.(chat_response, staging, %{
    model_id: gpt5_mini.id,
    params: chat_params,
    prompt_pins: %{"default" => chat_v9.id}
  })

  pin.(mood_inference, production, %{
    model_id: haiku.id,
    params: mood_params,
    prompt_pins: %{"default" => mood_v3.id}
  })

  pin.(voice_transcription, production, %{
    model_id: whisper.id,
    prompt_pins: %{"default" => stt_v4.id}
  })

  pin.(transcript_revision, production, %{
    model_id: gpt5_mini.id,
    prompt_pins: %{"default" => revision_v1.id}
  })

  pin.(diary_content_removal, production, %{
    model_id: sonnet4.id,
    provider_options: anthropic_only,
    prompt_pins: %{"default" => removal_v1.id}
  })

  pin.(memory_extraction, production, %{
    model_id: gpt5_mini.id,
    prompt_pins: %{"default" => memory_v1.id}
  })

  pin.(diary_search_content, production, %{
    model_id: gpt5_mini.id,
    prompt_pins: %{"default" => search_v1.id}
  })

  # diary_embedding is logs only — it has no prompt, so the pins map is empty.
  pin.(diary_embedding, production, %{model_id: embed.id})

  Logger.info("""
  [seeds] created the heydiary project (9 use cases, 8 models, 11 live Deployments — all pins).
  [seeds] sign-in: #{credentials}
  [seeds] start URL: http://localhost:4000/personal/heydiary/use-cases
  """)
end
