import Config
config :prompton, token_signing_secret: "g8TC2vSYXYrXtuVJizuj2shdcWLkk4KO"
config :prompton, Oban, testing: :manual

# The whole suite requests device codes hundreds of times from one IP (127.0.0.1), so the limits
# are lifted. The 429 contract is checked by `PromptOnWeb.Plugs.RateLimitTest`, which tightens
# them briefly.
config :prompton, PromptOnWeb.Plugs.RateLimit,
  device_code: [limit: 1_000_000],
  device_token: [limit: 1_000_000]

# Sign-in code requests and verifications come from the same IP too — lift both IP axes. The email
# axis (3 per 10 minutes) stays as is, since every test uses a different address, and
# `test/prompt_on_web/controllers/sign_in_controller_test.exs` checks that contract.
# The IP-axis contract is checked by `sign_in_throttle_http_test.exs`, which tightens it briefly.
config :prompton, PromptOn.Accounts.SignInThrottle,
  ip: [limit: 1_000_000],
  verify_ip: [limit: 1_000_000]

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Tests never call a real LLM (`PromptOn.LLM.Fake`).
config :prompton, :llm_adapter, PromptOn.LLM.Fake

# Default stub for provider catalog lookups — no test hits openrouter.ai by accident.
# Tests that need catalog contents override this in setup with Application.put_env.
config :prompton, :provider_catalog_req_options,
  plug: fn conn -> Req.Test.json(conn, %{"data" => []}) end

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :prompton, PromptOn.Repo,
  username: "postgres",
  password: "password",
  hostname: "localhost",
  database: "prompton_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :prompton, PromptOnWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "jH/mGpsfDHg8PgJZ86ZZIcK7XJZIYmQwcE/44EOUJsjCAZfMtlQkTV8rA8xH4JiI",
  server: false

# In test we don't send emails
config :prompton, PromptOn.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
