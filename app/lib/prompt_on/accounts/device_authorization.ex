defmodule PromptOn.Accounts.DeviceAuthorization do
  @moduledoc """
  **Device authorization request**: the path by which `prompton login` obtains a CLI session token
  via the browser (RFC 8628 style, agent-first-spec batch ③, `docs/management-api.md` §2).

      CLI ──POST /api/v1/device/code──▶ (device_code, user_code, verification_uri)
      Person ──browser /device?code=…──▶ sign in + Approve
      CLI ──POST /api/v1/device/token (polling)──▶ token, once

  ## The two codes do different jobs

  - `device_code`: a **secret** only the CLI knows. So the raw value is not stored; only its
    sha256 is (`device_code_hash`, the same rule as `ApiKey` and the old management keys).
    Polling uses this value.
  - `user_code`: 8 characters (`ABCD-EFGH`) that a person **reads and copies over**. It is an
    uppercase alphabet with confusable characters removed (`@alphabet`), so O/0 and I/1 can never
    be mixed up, and input is case- and hyphen-insensitive (`normalize_user_code/1`).

  ## The token is minted at approval time and lives here briefly

  It is a **person** who clicks Approve, and that person is the token's owner. So the CLI session
  token is minted inside the approval transaction and sits briefly in `token` (AshCloak
  AES-256-GCM encryption); once the CLI has fetched it (`:consume`) it is erased, so polling can
  never receive the same token twice. `status` says where things stand:

  | status | meaning |
  |---|---|
  | `pending` | created; the person has not touched it yet |
  | `approved` | the person approved and the token is here (before the CLI fetches it) |
  | `denied` | the person denied → `access_denied` |
  | `consumed` | the CLI fetched it. The token is erased and will not be handed out again |

  Once `expires_at` (15 minutes) has passed the request is dead regardless of status;
  `:by_device_code` does not filter out expired rows and returns them as they are (the controller
  has to say `expired_token` precisely).

  ## Expired rows are deleted (`:sweep_expired`, every 15 minutes)

  An AshOban schedule deletes expired requests on the `maintenance` queue, so rows left behind by
  the unauthenticated `POST /device/code` do not pile up. One thing to watch: a request that was
  **approved but never fetched by the CLI** (expired while `approved`) still holds a minted CLI
  session token, encrypted, and that token has no expiry. Deleting only the row would leave a
  live credential in `tokens` that nobody holds, so the sweeper **revokes** that token first and
  then deletes (`Actions.SweepExpired`).
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak, AshOban]

  alias PromptOn.Accounts.DeviceAuthorization.Changes

  # A 26-character uppercase alphabet with one side of each confusable pair removed (of I/1, O/0,
  # S/5, Z/2, G/6, B/8 only the letters were kept). The bar is that it survives being read out
  # over the phone or copied by hand without mistakes.
  @alphabet ~c"ABCDEFGHJKLMNPQRTUVWXY3479"

  # The two RFC 8628 constants. 15 minutes is ample for "open the browser, sign in, approve", and
  # 5 seconds is the interval at which polling knocks on the server.
  @ttl_seconds 900
  @poll_interval_seconds 5

  postgres do
    table "device_authorizations"
    repo PromptOn.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  cloak do
    vault(PromptOn.Vault)
    attributes([:token])
    decrypt_by_default([])
  end

  oban do
    scheduled_actions do
      schedule :sweep_expired_device_authorizations, "*/15 * * * *" do
        action :sweep_expired
        queue :maintenance
        worker_module_name PromptOn.Accounts.DeviceAuthorization.Workers.SweepExpired
        default_actor(%PromptOn.SystemActor{})
        max_attempts 1
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    action :sweep_expired, :map do
      description """
      Deletes expired requests. For those that expired while `approved`, the CLI session token
      inside is revoked first. Returns `%{deleted: n, revoked: m, kept: k}` (kept = rows whose
      token revocation failed, deferred to the next run).
      """

      argument :batch_size, :integer, default: 1_000, constraints: [min: 1, max: 10_000]
      argument :max_batches, :integer, default: 100, constraints: [min: 1, max: 1_000]

      run PromptOn.Accounts.DeviceAuthorization.Actions.SweepExpired
    end

    create :start do
      description """
      The CLI receives a pair of codes. The raw `device_code` leaves only as the result metadata
      `:device_code`; what is stored is just the sha256 (`Changes.GenerateCodes`).
      """

      accept [:client, :key_name]
      change Changes.GenerateCodes
    end

    update :approve do
      description "The person approved: plant that person's CLI session token along with it."
      require_atomic? false
      accept [:token]
      argument :user_id, :uuid, allow_nil?: false

      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:status, :approved)
      change set_attribute(:decided_at, &DateTime.utc_now/0)
    end

    update :deny do
      description "The person denied → polling receives `access_denied`."
      require_atomic? false
      change set_attribute(:status, :denied)
      change set_attribute(:decided_at, &DateTime.utc_now/0)
    end

    update :consume do
      description """
      The CLI fetched the token. Clear the ciphertext so it is **never handed out twice**.
      """

      require_atomic? false
      change set_attribute(:status, :consumed)
      change Changes.ClearToken
    end

    update :touch_poll do
      description "Records the poll time, the basis for the `slow_down` verdict (internal only)."
      change set_attribute(:last_polled_at, &DateTime.utc_now/0)
    end

    read :by_user_code do
      description """
      The code a person typed or prefilled on the screen → one request. Expired rows are returned
      as is (the screen tells the person it expired).
      """

      argument :user_code, :string, allow_nil?: false
      get? true
      filter expr(user_code == ^arg(:user_code))
    end

    read :by_device_code do
      description """
      CLI polling: looks up by the sha256 of the raw device_code. Called without an actor.
      """

      argument :device_code, :string, allow_nil?: false, sensitive?: true
      get? true

      prepare PromptOn.Accounts.DeviceAuthorization.Preparations.FilterByDeviceCode
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      description """
      Code issuance and polling are **unauthenticated** paths: the controller calls as
      SystemActor.
      """

      authorize_if always()
    end

    policy PromptOn.Checks.ApiKeyActor do
      description "Runtime keys (public API) can neither see nor touch device authorizations."
      forbid_if always()
    end

    bypass action(:by_user_code) do
      description """
      A signed-in person looks up the code they hold on the approval screen. The code itself is
      proof that the person is sitting in front of the CLI, so there is no separate owner filter
      (before approval no owner has been decided).
      """

      authorize_if actor_present()
    end

    bypass action([:approve, :deny]) do
      description """
      Approve and deny belong to the signed-in person, who is the owner of the token about to be
      issued.
      """

      authorize_if actor_present()
    end

    policy action_type(:read) do
      description "There is no other read (there is no list screen)."
      forbid_if always()
    end

    policy action_type([:create, :update, :destroy, :action]) do
      description """
      Create, poll touch, consume, and the sweeper pass only through the SystemActor bypass
      above.
      """

      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :device_code_hash, :string, allow_nil?: false, sensitive?: true

    attribute :user_code, :string do
      description """
      The human-readable 8-character code (`ABCD-EFGH`). Stored uppercase with the hyphen.
      """

      allow_nil? false
      public? true
    end

    attribute :client, :string do
      description """
      The name the CLI declared for itself (`"prompton-cli/0.1.0 (darwin/arm64)"`). Shown on
      screen as is.
      """

      constraints max_length: 200
      allow_nil? false
      public? true
    end

    attribute :key_name, :string do
      description """
      The label a person will attach to this session (`"CLI on lain"`). Suggested by the CLI.
      Length is capped because this is an unauthenticated write.
      """

      constraints max_length: 200
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :approved, :denied, :consumed]
    end

    attribute :token, :string do
      description """
      The CLI session token minted at approval: stored encrypted (`encrypted_token`), erased on
      consume.
      """

      public? true
      sensitive? true
    end

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :last_polled_at, :utc_datetime_usec, public?: true
    attribute :decided_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, PromptOn.Accounts.User do
      description "The person who approved = the owner of the issued token. Empty before approval."
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_device_code_hash, [:device_code_hash]
    identity :unique_user_code, [:user_code]
  end

  @doc """
  The stored hash of a raw device_code (sha256 hex), the same rule as
  `PromptOn.Projects.ApiKey.hash/1`.
  """
  @spec hash(String.t()) :: String.t()
  def hash(raw) when is_binary(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  @doc "Lifetime of a request, in seconds. RFC 8628's `expires_in`."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc "Recommended polling interval, in seconds. RFC 8628's `interval`."
  @spec poll_interval_seconds() :: pos_integer()
  def poll_interval_seconds, do: @poll_interval_seconds

  @doc "The alphabet used for human-readable codes (confusable characters excluded)."
  @spec alphabet() :: String.t()
  def alphabet, do: List.to_string(@alphabet)

  @doc """
  A new `user_code`: `XXXX-XXXX`.

      iex> code = PromptOn.Accounts.DeviceAuthorization.generate_user_code()
      iex> String.match?(code, ~r/^[A-Z0-9]{4}-[A-Z0-9]{4}$/)
      true
  """
  @spec generate_user_code() :: String.t()
  def generate_user_code do
    chars = for _ <- 1..8, do: Enum.random(@alphabet)
    {left, right} = Enum.split(chars, 4)
    List.to_string(left) <> "-" <> List.to_string(right)
  end

  @doc """
  Normalizes what a person typed into the stored form; case, hyphens, and whitespace are ignored.

      iex> PromptOn.Accounts.DeviceAuthorization.normalize_user_code("abcd efgh")
      "ABCD-EFGH"

      iex> PromptOn.Accounts.DeviceAuthorization.normalize_user_code("abcdefgh")
      "ABCD-EFGH"

      iex> PromptOn.Accounts.DeviceAuthorization.normalize_user_code("nope")
      nil
  """
  @spec normalize_user_code(term()) :: String.t() | nil
  def normalize_user_code(value) when is_binary(value) do
    stripped =
      value
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]/, "")

    case stripped do
      <<left::binary-size(4), right::binary-size(4)>> -> left <> "-" <> right
      _other -> nil
    end
  end

  def normalize_user_code(_value), do: nil

  @doc "Whether it has expired (looks only at the time, regardless of status)."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: at}),
    do: DateTime.compare(DateTime.utc_now(), at) != :lt
end
