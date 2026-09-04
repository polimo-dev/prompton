defmodule PromptOn.Application do
  @moduledoc """
  OTP application entry point. The size of the supervision tree is chosen by
  `config :prompton, :mode` (`config/runtime.exs` reads it from `PTN_MODE`):

  | Mode | What starts | Use case |
  |---|---|---|
  | `:server` (default) | Everything: Repo, Vault, PubSub, then the endpoint, Oban, caches, rate limiting, telemetry, DNS cluster | The PromptOn server itself |
  | `:library` | **Data layer only**: `PromptOn.Repo`, `PromptOn.Vault`, `Phoenix.PubSub` | Another OTP app that pulls in `:prompton` as a dependency and calls domain actions directly, or a script that only uses the domain on top of the DB |

  In `:library` mode neither HTTP requests nor scheduled jobs (AshOban) run: the caller is the only
  entry point to domain actions and also decides the actor (usually `PromptOn.SystemActor.new()`).
  Modules that presuppose a process outside the supervision tree work without one:
  `PromptOn.Deployments.SnapshotCache` and `PromptOn.Accounts.ProviderKeyCache` read uncached when
  the ETS table is missing, and token verification (`PromptOn.Accounts.CliSession`) needs only the
  Repo and `config :prompton, :token_signing_secret`. Conversely, sign-in code issuance and device
  sign-in, which rely on rate limiting (`PromptOn.RateLimit`), are not part of this mode; they are
  the server's job.

  When another project pulls this in as a dependency, this repo's `config/*.exs` is not read; the
  config keys that project has to fill in are listed in the "Embedding" section of the repo root
  `README.md`.
  """

  use Application

  @modes [:server, :library]

  @typedoc "Supervision tree mode (`config :prompton, :mode`)."
  @type mode :: :server | :library

  @impl true
  def start(_type, _args) do
    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PromptOn.Supervisor]
    Supervisor.start_link(children(mode()), opts)
  end

  @doc "The configured mode. `:server` when unset; an unknown value raises `ArgumentError`."
  @spec mode() :: mode()
  def mode do
    case Application.get_env(:prompton, :mode, :server) do
      mode when mode in @modes ->
        mode

      other ->
        raise ArgumentError,
              "config :prompton, :mode must be one of #{inspect(@modes)}, got: #{inspect(other)}"
    end
  end

  @doc "Supervision tree children per mode (`Supervisor.child_spec/1` arguments, in start order)."
  @spec children(mode()) :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children(:library) do
    [
      PromptOn.Repo,
      # Encryption vault (GenerationPayload / ProviderKey); required to read and write encrypted
      # attributes.
      PromptOn.Vault,
      {Phoenix.PubSub, name: PromptOn.PubSub}
    ]
  end

  def children(:server) do
    [
      PromptOnWeb.Telemetry,
      PromptOn.Repo,
      {DNSCluster, query: Application.get_env(:prompton, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:prompton, :ash_domains),
         Application.fetch_env!(:prompton, Oban)
       )},
      {Phoenix.PubSub, name: PromptOn.PubSub},
      # Per-IP rate limit counters for unauthenticated routes (device sign-in); ETS, node-local.
      {PromptOn.RateLimit, clean_period: :timer.minutes(10)},
      # Encryption vault (GenerationPayload / ProviderKey)
      PromptOn.Vault,
      # ETS cache for config-fetch serving (`GET /use-cases`,
      # `POST /use-cases/:key/prompt`) polling, so the document is not reassembled and decoded on
      # every poll.
      PromptOn.Deployments.SnapshotCache,
      # Decrypted BYOK key cache used by server-side LLM calls (arena, AI drafts, and later
      # auto-grading).
      PromptOn.Accounts.ProviderKeyCache,
      # Start to serve requests, typically the last entry
      PromptOnWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :prompton]}
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated. `:library` mode has no endpoint.
  @impl true
  def config_change(changed, _new, removed) do
    if mode() == :server, do: PromptOnWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
