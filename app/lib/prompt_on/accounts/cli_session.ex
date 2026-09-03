defmodule PromptOn.Accounts.CliSession do
  @moduledoc """
  **CLI session token**: the credential that `prompton login` (device authorization) issues and
  the management API accepts (agent-first-spec batch ③, `docs/management-api.md`).

  ## Why this is not a resource

  Management keys were deleted on 2026-09-02 (user decision). The CLI **signs in as a user**, and
  the actor of every management API call is that user: permissions are exactly the user's
  organization/project membership policies, and there is no separate machine credential hanging
  off the organization. So there is no new table here: what gets issued is an ash_authentication
  **user JWT**, and storage is the existing `tokens` table (`User`'s `store_all_tokens? true`).
  The device name and last-used time live in that row's `extra_data`.

  ## How it differs from a session token

  Same signing secret, same storage, but the **purpose differs**:

  | | Browser session | CLI session |
  |---|---|---|
  | purpose | `"user"` | `"cli"` |
  | lifetime | ash_authentication default | **no expiry** (`@lifetime_days` = 100 years; the JWT spec requires an `exp`) |
  | used where | session cookie | `Authorization: Bearer <token>` (management API) |

  **The management API accepts only `"cli"` tokens** (`PromptOnWeb.Plugs.UserTokenAuth`). If a
  browser session token could be used on the API as is, "revoke this credential"
  (`POST /api/v1/sessions/revoke`) would come to mean cutting off a person's sign-in session. The
  two credentials differ in lifetime and in the unit of revocation, so they do not share one door.

  ## Revocation: three paths

  Token rows live in the `tokens` table, and revoking one means turning that row into a revocation
  (`AshAuthentication.TokenResource.Actions.revoke/2`). `AshAuthentication.Jwt.verify/2` checks
  that state when it validates the `jti`, so a revoked token is a 401 immediately.

  | Where | What | Function |
  |---|---|---|
  | `prompton logout` (`POST /sessions/revoke`) | that one token | `revoke/1` |
  | Account screen "Logged-in devices" | the chosen device (`jti`) | `revoke_jti/2` |
  | Account screen "Sign out everywhere" | all (except the clicking browser's session) | `PromptOn.Accounts.Sessions.revoke_all/2` |

  Since there is no expiry, a lost device is cleaned up by **revocation**, which is why there is a
  list (`list/1`).
  """

  alias PromptOn.Accounts.Token
  alias PromptOn.Accounts.User
  alias PromptOn.SystemActor

  require Ash.Query

  # A credential a person approves once and keeps using (user decision 2026-09-02: no expiry).
  # A lost device is cleaned up by **revocation**, not expiry: cut it off one at a time via
  # `prompton logout` or the account screen's "Logged-in devices". The JWT spec requires an `exp`,
  # so we put in 100 years, which is effectively infinite.
  @lifetime_days 36_500

  @purpose "cli"

  # `last_used_at` is rewritten only when it is older than this: on an API that agents call
  # several times per second we do not issue an UPDATE per request. This resolution is plenty for
  # the list screen's "used 3m ago".
  @touch_after_seconds 300

  @typedoc """
  One live CLI session: one "device" row on the account screen. The `jti` is the session's id
  (the raw token is stored nowhere). `client` is what the CLI declared about itself
  (`prompton-cli/0.1.0 (darwin/arm64)`), `name` is the human-readable label (`CLI on lain`); both
  come from the device authorization request.
  """
  @type t :: %__MODULE__{
          jti: String.t(),
          client: String.t() | nil,
          name: String.t() | nil,
          created_at: DateTime.t(),
          last_used_at: DateTime.t() | nil
        }

  defstruct [:jti, :client, :name, :created_at, :last_used_at]

  @doc "The purpose claim value of CLI session tokens (the same string as `tokens.purpose`)."
  @spec purpose() :: String.t()
  def purpose, do: @purpose

  @doc "Lifetime of a CLI session token, in days."
  @spec lifetime_days() :: pos_integer()
  def lifetime_days, do: @lifetime_days

  @doc "Interval to wait before rewriting `last_used_at`, in seconds."
  @spec touch_after_seconds() :: pos_integer()
  def touch_after_seconds, do: @touch_after_seconds

  @doc """
  Mints the user's CLI session token; it is stored in the `tokens` table with purpose `"cli"`.

  The options `client:` and `name:` are the names shown in the device list (the device
  authorization request's `client` and `key_name`). The token is valid even if storing the
  metadata fails; the device just shows up unnamed.
  """
  @spec issue(User.t(), keyword()) :: {:ok, String.t(), map()} | :error
  def issue(%User{} = user, opts \\ []) do
    with {:ok, token, claims} <-
           AshAuthentication.Jwt.token_for_user(
             user,
             %{"purpose" => @purpose},
             purpose: @purpose,
             token_lifetime: {@lifetime_days, :days}
           ) do
      _ = annotate(claims["jti"], device_meta(opts))
      {:ok, token, claims}
    end
  end

  @doc """
  Bearer token → user. Verifies signature, expiry, issuer, and revocation (`jti`), and also checks
  that the stored token row's purpose is `"cli"` (no row = already swept as expired, or not issued
  by us).
  """
  @spec verify(String.t()) :: {:ok, User.t()} | :error
  def verify(token) do
    case authenticate(token) do
      {:ok, user, _session} -> {:ok, user}
      :error -> :error
    end
  end

  @doc "`verify/1` plus that token's session info (the plug hands it to `touch/1`)."
  @spec authenticate(String.t()) :: {:ok, User.t(), t()} | :error
  def authenticate(token) when is_binary(token) do
    with {:ok, %{"sub" => subject, "jti" => jti, "purpose" => @purpose}, User} <-
           AshAuthentication.Jwt.verify(token, :prompton),
         {:ok, [stored]} <- stored_token(jti),
         {:ok, user} <- AshAuthentication.subject_to_user(subject, User) do
      {:ok, user, to_session(stored)}
    else
      _other -> :error
    end
  end

  def authenticate(_token), do: :error

  @doc """
  All of the user's live CLI sessions, most recently issued first. The account screen's
  "Logged-in devices".
  """
  @spec list(User.t()) :: [t()]
  def list(%User{} = user) do
    Token
    |> Ash.Query.for_read(:cli_sessions, %{subject: subject(user)}, actor: SystemActor.new())
    |> Ash.read!()
    |> Enum.map(&to_session/1)
  end

  @doc "Revokes this one token (`POST /api/v1/sessions/revoke`, the CLI's logout)."
  @spec revoke(String.t()) :: :ok | {:error, term()}
  def revoke(token) when is_binary(token),
    do: AshAuthentication.TokenResource.Actions.revoke(Token, token)

  @doc """
  Revokes one of the user's CLI sessions by `jti`: the per-device "Log out" on the account screen.

  Revokes **only when the session belongs to that user**: someone else's jti, or an already dead
  jti, is `{:error, :not_found}`.
  """
  @spec revoke_jti(User.t(), String.t()) :: :ok | {:error, :not_found | term()}
  def revoke_jti(%User{} = user, jti) when is_binary(jti) do
    subject = subject(user)

    Token
    |> Ash.Query.for_read(:cli_sessions, %{subject: subject}, actor: SystemActor.new())
    |> Ash.Query.filter(jti == ^jti)
    |> Ash.read_one()
    |> case do
      {:ok, %Token{}} -> AshAuthentication.TokenResource.Actions.revoke_jti(Token, jti, subject)
      _other -> {:error, :not_found}
    end
  end

  @doc """
  Records the last-used time; does nothing if it is more recent than `@touch_after_seconds`.
  Failures are swallowed (a side effect on the authentication path must not kill the request).
  """
  @spec touch(t()) :: :ok
  def touch(%__MODULE__{} = session) do
    if stale?(session.last_used_at) do
      _ =
        annotate(session.jti, %{
          "client" => session.client,
          "name" => session.name,
          "last_used_at" => DateTime.to_iso8601(DateTime.utc_now())
        })
    end

    :ok
  end

  @doc "The user identifier string stored in `tokens.subject` (`user?id=…`)."
  @spec subject(User.t()) :: String.t()
  def subject(%User{} = user), do: AshAuthentication.user_to_subject(user)

  # ---------------------------------------------------------------------------

  defp stale?(nil), do: true

  defp stale?(%DateTime{} = at),
    do: DateTime.diff(DateTime.utc_now(), at, :second) >= @touch_after_seconds

  # A device name is one line on screen: wherever it came from, cut it at 200 characters
  # (`DeviceAuthorization` has the same limit).
  @meta_max_length 200

  defp device_meta(opts) do
    %{"client" => opts[:client], "name" => opts[:name]}
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {k, String.slice(to_string(v), 0, @meta_max_length)} end)
  end

  # Replaces `extra_data` wholesale. If the row is not found (e.g. right after revocation) or the
  # update fails, the caller's work continues.
  defp annotate(jti, extra_data) do
    with {:ok, [stored]} <- stored_token(jti),
         {:ok, _updated} <-
           Ash.update(stored, %{extra_data: extra_data},
             action: :annotate,
             actor: SystemActor.new()
           ) do
      :ok
    else
      _other -> :error
    end
  end

  defp stored_token(jti) do
    AshAuthentication.TokenResource.Actions.get_token(Token, %{
      "jti" => jti,
      "purpose" => @purpose
    })
  end

  defp to_session(%Token{} = token) do
    extra = token.extra_data || %{}

    %__MODULE__{
      jti: token.jti,
      client: extra["client"],
      name: extra["name"],
      created_at: token.created_at,
      last_used_at: parse_time(extra["last_used_at"])
    }
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _other -> nil
    end
  end

  defp parse_time(_value), do: nil
end
