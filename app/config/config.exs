# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ash_oban, pro?: false

# Default sender for sign-in code emails — production overrides it with `PTN_MAIL_FROM`
# (`config/runtime.exs`).
config :prompton, :mail_from, "PromptOn <noreply@prompton.ai>"

# Parameter filter for logs (substring match) — keeps the sign-in code (`code` of
# `POST /sign-in/verify`) and tokens out of controller/LiveView debug logs
# (`test/prompt_on_web/controllers/sign_in_logging_test.exs`).
config :phoenix, :filter_parameters, ["password", "token", "code"]

# `evals: 4` is the concurrency ceiling on judge calls per node (ADR 0010 §3.1): one Oban job per
# scored sample, so a 1,000-item run is ≈ 12 minutes and never more than four concurrent requests
# against one organization's OpenRouter key.
#
# The queue is global, so one organization's batch occupies the node's whole eval capacity while it
# runs and another organization's batch waits behind it. That is accepted for now — there is no
# per-tenant fairness and no admission control. `NoActiveRun` plus the partial unique index on
# `EvaluationRun` cap it at one run per deployment revision; a per-organization cap on concurrently
# active runs is the next lever if a tenant ever holds the queue too long.
config :prompton, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 10, maintenance: 1, evals: 4],
  repo: PromptOn.Repo,
  plugins: [{Oban.Plugins.Cron, []}]

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :authentication,
        :token,
        :user_identity,
        :admin,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:admin, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :prompton,
  namespace: PromptOn,
  ecto_repos: [PromptOn.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    PromptOn.Accounts,
    PromptOn.Projects,
    PromptOn.Catalog,
    PromptOn.Prompts,
    PromptOn.Deployments,
    PromptOn.Observability,
    PromptOn.Evals
  ]

# Evals (ADR 0010).
#
# `:judge_model` is the last fallback of the judge model chain (rubric → organization → this key).
# `:entitlements_plan_override`, when set to `:free | :team | :pro`, makes `PromptOn.Entitlements`
# report that plan for every organization — the one switch a self-hosted operator needs so that
# plan limits do not apply to a single-tenant install (README "Embedding").
config :prompton, :judge_model, "openai/gpt-4o-mini"
config :prompton, :entitlements_plan_override, nil

# The channel through which the server calls LLMs directly (Playground/Experiment/judge only,
# plan.md §11.2). The test environment overrides it with `PromptOn.LLM.Fake`.
config :prompton, :llm_adapter, PromptOn.LLM.OpenRouter

# Configure the endpoint
config :prompton, PromptOnWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PromptOnWeb.ErrorHTML, json: PromptOnWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PromptOn.PubSub,
  live_view: [signing_salt: "VBTEFrfE"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer — sign-in code emails are all there is (`PromptOn.Accounts.SignIn.Email`).
#
# The default is the "Local" adapter (mail piles up in `/dev/mailbox`). prod switches to Resend in
# `config/prod.exs`, and the key is read from `PTN_RESEND_API_KEY` by `config/runtime.exs`; dev also
# uses Resend when that key is present. test uses `Swoosh.Adapters.Test` (`config/test.exs`).
config :prompton, PromptOn.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  prompton: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  prompton: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
