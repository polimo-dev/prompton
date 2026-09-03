import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/prompton start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# ---------------------------------------------------------------------------
# PromptOn convention: operational environment variables use the `PTN_` prefix (plan.md §11.6).
# Local development fills the same keys from `.env` (dotenvy). The old `PON_` prefix is a
# **deprecated fallback** — it is read for this one release only, so deployment manifests can move
# over to `PTN_`, and is removed in the next release.
# Phoenix conventional keys (DATABASE_URL etc.) are also read as a last fallback, for compatibility
# with existing deployment tooling.
# ---------------------------------------------------------------------------
import Dotenvy

env_dir = Path.expand("..", __DIR__)

source!([
  Path.join(env_dir, ".env"),
  Path.join(env_dir, ".env.#{config_env()}"),
  System.get_env()
])

# Precedence: `PTN_<name>` → `PON_<name>` (deprecated — one release only) → `<name>` (Phoenix
# convention) → default
ptn_env = fn name, default ->
  env!("PTN_#{name}", :string, env!("PON_#{name}", :string, env!(name, :string, default)))
end

# Supervision tree mode (`PromptOn.Application`): "server" (default) = everything, "library" = the
# data layer only (Repo, Vault, PubSub — no endpoint, no Oban). For when another OTP app pulls in
# `:prompton` as a dependency or a script uses only the domain. The endpoint secrets in the prod
# block below are required only in "server" mode.
mode =
  case ptn_env.("MODE", "server") do
    "server" ->
      :server

    "library" ->
      :library

    other ->
      raise ~s(environment variable PTN_MODE must be "server" or "library", got: #{inspect(other)})
  end

config :prompton, :mode, mode

# Vault key for encrypting payloads/provider keys (base64, 32 bytes). dev/test use a fixed default.
vault_key =
  ptn_env.("VAULT_KEY", nil) ||
    if config_env() == :prod do
      raise "environment variable PTN_VAULT_KEY is missing (base64-encoded 32-byte key)"
    else
      # Fixed key for dev/test only — never use it in production
      "8mCzXd6TmSTHR6yWK1lNMoORqzR20+bxHqSc0/qzsO8="
    end

config :prompton, PromptOn.Vault,
  ciphers: [
    default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(vault_key)}
  ]

# OpenRouter fallback key (for the Phase 2 Playground/Experiment; temporary until one is registered
# in the UI)
config :prompton, :openrouter_api_key, ptn_env.("OPENROUTER_API_KEY", nil)

# ---------------------------------------------------------------------------
# Mail — sign-in code emails are all there is (ADR 0008). Sending goes through Resend
# (`Resend.Swoosh.Adapter`).
#   PTN_RESEND_API_KEY  Required in prod (boot fails without it). dev uses Resend when set,
#                       `/dev/mailbox` otherwise. test always uses `Swoosh.Adapters.Test`
#                       (`config/test.exs`), even when `.env` has a key.
#   PTN_MAIL_FROM       Sender, of the form `"PromptOn <noreply@prompton.ai>"` (the default).
# ---------------------------------------------------------------------------
# An empty value in `.env` (`PTN_RESEND_API_KEY=`) means "absent" — dotenvy returns empty
# strings as values too.
resend_api_key =
  case ptn_env.("RESEND_API_KEY", nil) do
    "" -> nil
    key -> key
  end

config :prompton, :mail_from, ptn_env.("MAIL_FROM", "PromptOn <noreply@prompton.ai>")

# Docs site (prompton-docs) URL — when set, the app's `/docs/agent` redirects there with a 302
# (otherwise the bundled copy is served).
config :prompton, :docs_url, ptn_env.("DOCS_URL", nil)

case config_env() do
  :prod ->
    config :prompton, PromptOn.Mailer,
      adapter: Resend.Swoosh.Adapter,
      api_key:
        resend_api_key ||
          raise("""
          environment variable PTN_RESEND_API_KEY is missing.
          Sign-in emails are sent through Resend — create an API key at https://resend.com
          (the sending domain prompton.ai must be verified there: SPF + DKIM).
          """)

  :dev ->
    if resend_api_key do
      config :prompton, PromptOn.Mailer, adapter: Resend.Swoosh.Adapter, api_key: resend_api_key
    end

  _test ->
    :ok
end

if System.get_env("PHX_SERVER") do
  config :prompton, PromptOnWeb.Endpoint, server: true
end

config :prompton, PromptOnWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :prompton, PromptOnWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/prompt_on_web/router\.ex$"E,
        ~r"lib/prompt_on_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    ptn_env.("DATABASE_URL", nil) ||
      raise """
      environment variable PTN_DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :prompton, PromptOn.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(ptn_env.("POOL_SIZE", "10")),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  config :prompton, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # The endpoint starts only in "server" mode — "library" mode needs neither the cookie signing
  # secret nor a public host (the token signing secret below is independent of the mode: verifying
  # session/CLI tokens is the data layer's job).
  if mode == :server do
    # The secret key base is used to sign/encrypt cookies and other secrets.
    # A default value is used in config/dev.exs and config/test.exs but you
    # want to use a different value for prod and you most likely don't want
    # to check this value into version control, so we use an environment
    # variable instead.
    secret_key_base =
      ptn_env.("SECRET_KEY_BASE", nil) ||
        raise """
        environment variable PTN_SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    host = ptn_env.("PHX_HOST", "example.com")

    config :prompton, PromptOnWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        # Enable IPv6 and bind on all interfaces.
        # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
        # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
        # for details about using IPv6 vs IPv4 and loopback vs public addresses.
        ip: {0, 0, 0, 0, 0, 0, 0, 0}
      ],
      secret_key_base: secret_key_base
  end

  config :prompton,
    token_signing_secret:
      ptn_env.("TOKEN_SIGNING_SECRET", nil) ||
        raise("Missing environment variable `PTN_TOKEN_SIGNING_SECRET`!")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :prompton, PromptOnWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :prompton, PromptOnWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # The mailer (Resend) is configured for all environments by the "Mail" block above.
end
