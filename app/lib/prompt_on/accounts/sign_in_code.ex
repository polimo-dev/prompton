defmodule PromptOn.Accounts.SignInCode do
  @moduledoc """
  **Sign-in code**: the 6-digit number `/sign-in` sends by email (user decision 2026-09-03,
  ADR 0008 revision: a code rather than a link). It is the one and only sign-in method. Entering
  the right code signs you in, and for a never-seen address the user (+ personal organization) is
  created at that moment; the whole flow is `PromptOn.Accounts.SignIn`.

  ## The raw code is not stored

  `code_hash` is `sha256(id <> ":" <> code)` (`hash/2`). The row id is used as salt, so the same
  code does not hash the same in two rows, and even if the whole store leaks the code is not
  sitting there. Of course a 6-digit number has only a million possibilities, so reversing the
  hash offline is instant; what the hash protects is "the raw code is not in a dump" and "the raw
  code is not visible in logs, backups, or admin screens", while **online brute force is stopped
  by the window and the attempt count**:

  - A code lives only **5 minutes** (`ttl_seconds/0`).
  - A code can be tried at most **5 times** (`max_attempts/0`); right or wrong, an attempt is an
    attempt. After 5 misses the 6th fails even if correct. The success probability is 5/10⁶ per
    code.
  - Requesting a new code for the same address **deletes the previous code**
    (`Changes.InvalidateOlderCodes`); there is always exactly one live code per address.
  - Verification requests themselves are limited to 20 per 10 minutes per IP
    (`PromptOn.Accounts.SignInThrottle.allow_verify?/2`, counted by `SignIn.verify/3` before it
    touches the DB).

  ## Attempts are counted under a lock

  `:attempt` locks the address's newest live row with `SELECT … FOR UPDATE` and increments
  `attempts` (`Actions.Attempt`). Submitting the same code twice concurrently (double click, two
  tabs) still yields one sign-in: the second waits for the first's commit, then sees the row with
  `consumed_at` set and fails
  (`test/prompt_on/accounts/sign_in_code_concurrency_test.exs`).

  ## There is one response

  Whether the code is missing, wrong, expired, or used up, `:attempt`'s failure has one shape and
  the screen has one message ("That code didn't work. Check it or request a new one."). Saying
  which case it was would leak the address's activity.

  ## Expired rows are deleted (`:sweep_expired`, every 15 minutes)

  An AshOban schedule deletes rows whose `expires_at` has passed on the `maintenance` queue
  (`Actions.SweepExpired`); consumed rows disappear with them once expired. No credential hangs
  off a code, so there is nothing to revoke (the difference from `DeviceAuthorization`'s sweeper).
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  alias PromptOn.Accounts.SignInCode.Changes

  # 5 minutes: ample for the mail to arrive and be copied over, short for brute force.
  @ttl_seconds 300
  # How many times one code may be tried.
  @max_attempts 5
  @digits 6

  postgres do
    table "sign_in_codes"
    repo PromptOn.Repo

    # `:attempt` looks up by address (the sweeper keeps the table small, but the shorter the lock
    # scan the better).
    custom_indexes do
      index [:email]
    end
  end

  oban do
    scheduled_actions do
      schedule :sweep_expired_sign_in_codes, "*/15 * * * *" do
        action :sweep_expired
        queue :maintenance
        worker_module_name PromptOn.Accounts.SignInCode.Workers.SweepExpired
        default_actor(%PromptOn.SystemActor{})
        max_attempts 1
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    action :sweep_expired, :map do
      description "Deletes expired code rows. Returns `%{deleted: n}`."

      argument :batch_size, :integer, default: 1_000, constraints: [min: 1, max: 10_000]
      argument :max_batches, :integer, default: 100, constraints: [min: 1, max: 1_000]

      run PromptOn.Accounts.SignInCode.Actions.SweepExpired
    end

    create :request do
      description """
      Creates a new code. The raw value leaves only as the result metadata `:code` (the same
      pattern as `device_code` in `DeviceAuthorization.:start`); what is stored is just the hash
      (`Changes.GenerateCode`). Previous rows for the same address are deleted first
      (`Changes.InvalidateOlderCodes`).
      """

      accept [:email, :requested_ip]

      change Changes.InvalidateOlderCodes
      change Changes.GenerateCode
    end

    action :attempt, :struct do
      description """
      Tries a code. Locks the address's newest live row, counts the attempt, and on a match stamps
      `consumed_at` and returns the row. Missing, wrong, expired, and over the limit are **one
      error shape** (`Actions.Attempt`).
      """

      constraints instance_of: __MODULE__

      argument :email, :ci_string, allow_nil?: false
      argument :code, :string, allow_nil?: false, sensitive?: true

      run PromptOn.Accounts.SignInCode.Actions.Attempt
    end

    update :record_attempt do
      description """
      Writes the attempt count (and the consumed time on success); for `Actions.Attempt` only
      (internal).
      """

      accept [:attempts, :consumed_at]
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      description """
      Issuance, verification, and cleanup are all called by `PromptOn.Accounts.SignIn` as the
      system actor.
      """

      authorize_if always()
    end

    policy always() do
      description "No other actor may read or touch codes."
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :email, :ci_string do
      description "The address the code was sent to (trimmed, case-insensitive)."
      allow_nil? false
      public? true
    end

    attribute :code_hash, :string do
      description "`sha256(id <> \":\" <> code)` hex; the raw code is stored nowhere."
      allow_nil? false
      sensitive? true
    end

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :attempts, :integer do
      description """
      How many times it has been tried so far. Once it reaches `max_attempts/0` the code is dead.
      """

      allow_nil? false
      default 0
      public? true
    end

    attribute :consumed_at, :utc_datetime_usec do
      description "When it was matched. Once set, it cannot be used again."
      public? true
    end

    attribute :requested_ip, :string do
      description """
      The client IP that requested the code (for abuse investigation). Empty if unknown.
      """

      constraints max_length: 45
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @doc "The stored hash: sha256 hex salted with the row id."
  @spec hash(String.t(), String.t()) :: String.t()
  def hash(id, code) when is_binary(id) and is_binary(code),
    do: :crypto.hash(:sha256, id <> ":" <> code) |> Base.encode16(case: :lower)

  @doc "Lifetime of a code, in seconds."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc "How many times one code may be tried."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: @max_attempts

  @doc "Number of digits in a code."
  @spec digits() :: pos_integer()
  def digits, do: @digits

  @doc """
  A new code: 6 uniform digits from `:crypto.strong_rand_bytes/1`, left-padded with 0.

      iex> code = PromptOn.Accounts.SignInCode.generate_code()
      iex> String.match?(code, ~r/^[0-9]{6}$/)
      true
  """
  @spec generate_code() :: String.t()
  def generate_code do
    10
    |> Integer.pow(@digits)
    |> uniform_below()
    |> Integer.to_string()
    |> String.pad_leading(@digits, "0")
  end

  # Accepts a 32-bit random number only below a multiple of the bound (rejection sampling) to
  # remove the bias of `rem`.
  @word 4_294_967_296
  defp uniform_below(bound) do
    ceiling = @word - rem(@word, bound)
    value = 4 |> :crypto.strong_rand_bytes() |> :binary.decode_unsigned()
    if value < ceiling, do: rem(value, bound), else: uniform_below(bound)
  end

  @doc """
  Normalizes what a person typed into the comparison form: drops whitespace and hyphens and
  returns a value only when it is **exactly 6 digits**.

      iex> PromptOn.Accounts.SignInCode.normalize_code(" 123 456 ")
      {:ok, "123456"}

      iex> PromptOn.Accounts.SignInCode.normalize_code("12345")
      :error
  """
  @spec normalize_code(term()) :: {:ok, String.t()} | :error
  def normalize_code(value) when is_binary(value) do
    stripped = String.replace(value, ~r/[\s-]/, "")
    if Regex.match?(~r/^[0-9]{6}$/, stripped), do: {:ok, stripped}, else: :error
  end

  def normalize_code(_value), do: :error

  @doc "Whether it has expired (looks only at the time, regardless of consumption)."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: at}),
    do: DateTime.compare(DateTime.utc_now(), at) != :lt
end
