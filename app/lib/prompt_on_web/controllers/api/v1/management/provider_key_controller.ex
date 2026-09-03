defmodule PromptOnWeb.API.V1.Management.ProviderKeyController do
  @moduledoc """
  `/api/v1/orgs/:org/provider-key` - the organization's **BYOK OpenRouter key**
  (`PromptOn.Accounts.ProviderKey`).

  | Request | Domain action |
  |---|---|
  | `GET  /provider-key` | `ProviderKey.:for_provider` (`{"connected": false}` when there is none) |
  | `POST /provider-key` | `ProviderKey.:register` |

  There is no project in the path - because **the key is owned at the organization level**
  (2026-09-01 revision). There is no reason to register the same OpenRouter key once per project,
  and billing and members live at the organization.

  ## Not needed for onboarding

  This key is used only **where the PromptOn server itself calls an LLM** (arena, AI draft, and the
  P1 evaluation). The app's production calls do not pass through PromptOn, so §3 onboarding
  finishes without this key - register it when the coding AI wants to run the arena or evaluation
  as well (agent-first-spec §3.7).

  ## The raw secret never goes out

  All the response carries is the masked `hint` (`"sk-or-v1-••••4Xa2"`). The raw secret is stored
  encrypted with `AshCloak` (AES-256-GCM) and decrypted only when the server actually makes a call.
  If a key with that label already exists it is **409** with the hint in `details.provider_key`
  (replacing the secret is done on the human-facing screen, `/{org}/settings?tab=providers`).
  """

  use PromptOnWeb, :controller

  alias PromptOn.Accounts
  alias PromptOn.Accounts.ProviderKey
  alias PromptOnWeb.API.V1.Management.JSON
  alias PromptOnWeb.API.V1.Management.Params
  alias PromptOnWeb.API.V1.Management.Scope

  action_fallback PromptOnWeb.API.V1.FallbackController

  @provider :openrouter
  @default_label "default"

  def show(conn, _params) do
    user = Scope.user(conn)

    case Accounts.active_provider_key(Scope.organization(conn).id, @provider, actor: user) do
      {:ok, provider_key} -> json(conn, JSON.provider_key(provider_key))
      {:error, _error} -> json(conn, JSON.provider_key(nil))
    end
  end

  def create(conn, params) do
    user = Scope.user(conn)
    organization = Scope.organization(conn)

    with {:ok, secret} <- Params.required_string(params, "secret"),
         {:ok, label} <- Params.optional_string(params, "label"),
         label = blank_to_default(label),
         :ok <- ensure_available(user, organization, label),
         attrs = %{
           organization_id: organization.id,
           provider: @provider,
           label: label,
           secret: secret
         },
         {:ok, provider_key} <- Accounts.register_provider_key(attrs, actor: user) do
      conn |> put_status(:created) |> json(JSON.provider_key(provider_key))
    end
  end

  # ---------------------------------------------------------------------------

  defp blank_to_default(nil), do: @default_label

  defp blank_to_default(label) do
    case String.trim(label) do
      "" -> @default_label
      trimmed -> trimmed
    end
  end

  defp ensure_available(user, organization, label) do
    case Accounts.list_provider_keys(organization.id, actor: user) do
      {:ok, keys} ->
        conflict_or_ok(Enum.find(keys, &(&1.provider == @provider and &1.label == label)))

      {:error, _error} ->
        :ok
    end
  end

  defp conflict_or_ok(nil), do: :ok

  defp conflict_or_ok(%ProviderKey{} = existing) do
    {:error,
     {:conflict, "an openrouter key labelled #{existing.label} is already registered",
      %{"provider_key" => JSON.provider_key(existing)}}}
  end
end
