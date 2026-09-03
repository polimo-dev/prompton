defmodule PromptOn.Catalog.Model do
  @moduledoc """
  Per-project model catalog entry (plan.md §5.4). The single home of "which model do we call" that a
  Deployment target points at.

  - `metadata` is a **free-form map**: values passed straight through to the app UI, like HeyDiary
    `ai_models.display_name`/`description_key`.
  - `provider_options` is the **default routing** (e.g. OpenRouter `%{"only" => ["Anthropic"]}`); a
    Deployment target shallow-overrides it. Explicit `nil` values such as `%{"only" => nil}` are
    stored and passed through as-is (HeyDiary `provider.only: null` contract).
  - `pricing` is a per-million-token rate map (`input_per_m`/`output_per_m`/`cached_input_per_m`/
    `currency`/`unit`); when ingest has no provider cost, `estimate_cost/3` estimates it.
  - Instead of deletion: `:deprecate` (cannot be selected by new targets; if a live Deployment
    references it, it stays in the snapshot along with `status`) / `:archive` (soft; refused if a
    live Deployment references it, see `Validations.NotReferencedByDeployment`), because logs and
    deployments reference models.
  - `:import_from_provider` (OpenRouter sync) is P1.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Catalog,
    fragments: [PromptOn.ProjectScoped]

  @raw_string [allow_empty?: true, trim?: false]

  postgres do
    table "models"
  end

  actions do
    defaults [:read]

    create :register do
      description "Manual model registration. `(project, provider, model_id)` is unique."

      accept [
        :provider,
        :model_id,
        :display_name,
        :metadata,
        :provider_options,
        :pricing,
        :context_length,
        :capabilities,
        :status
      ]

      validate PromptOn.Catalog.Model.Validations.Pricing
    end

    update :edit_metadata do
      description "Edit display name, free-form metadata, context length and capabilities."
      accept [:display_name, :metadata, :context_length, :capabilities]
    end

    update :set_provider_options do
      description "Replace the default routing options (not a merge)."
      accept [:provider_options]
    end

    update :set_pricing do
      require_atomic? false
      accept [:pricing]
      validate PromptOn.Catalog.Model.Validations.Pricing
    end

    update :deprecate do
      description """
      Cannot be selected by new Deployment targets. Existing deployments and logs are untouched, and
      if a live Deployment references it, it also stays in the snapshot (as `status: "deprecated"`).
      """

      change set_attribute(:status, :deprecated)
    end

    update :archive do
      description "Soft archive; leaves lists. Refused if a live Deployment target references it."
      require_atomic? false
      validate PromptOn.Catalog.Model.Validations.NotReferencedByDeployment
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end

    read :active do
      filter expr(status == :active and is_nil(archived_at))
    end

    read :by_provider_model do
      argument :provider, :atom, allow_nil?: false
      argument :model_id, :string, allow_nil?: false
      get? true
      filter expr(provider == ^arg(:provider) and model_id == ^arg(:model_id))
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    bypass [PromptOn.Checks.ApiKeyActor, action_type(:read)] do
      description """
      An ApiKey reads only its own project's active (not deprecated, not archived) models. The
      snapshot loads the models referenced by live Deployment targets directly by id, regardless of
      status (`PromptOn.Deployments.Snapshot`).
      """

      authorize_if expr(
                     project_id == ^actor(:project_id) and status == :active and
                       is_nil(archived_at)
                   )
    end

    policy [PromptOn.Checks.ApiKeyActor, action_type([:create, :update, :destroy])] do
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if PromptOn.Checks.ProjectMember
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if PromptOn.Checks.ProjectMember
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:openrouter, :groq, :openai, :anthropic, :google]
    end

    attribute :model_id, :string do
      description "Raw provider-side identifier (`anthropic/claude-sonnet-4`, `whisper-large-v3`)."
      allow_nil? false
      public? true
      constraints @raw_string
    end

    attribute :display_name, :string, allow_nil?: false, public?: true
    attribute :metadata, :map, allow_nil?: false, public?: true, default: %{}
    attribute :provider_options, :map, allow_nil?: false, public?: true, default: %{}
    attribute :pricing, :map, allow_nil?: false, public?: true, default: %{}
    attribute :context_length, :integer, public?: true, constraints: [min: 0]

    attribute :capabilities, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      constraints items: [one_of: [:tools, :vision, :json_mode, :reasoning, :streaming]]
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :deprecated]
    end

    attribute :synced_at, :utc_datetime_usec, public?: true
    attribute :archived_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  calculations do
    calculate :archived?, :boolean, expr(not is_nil(archived_at))
  end

  identities do
    identity :unique_provider_model, [:project_id, :provider, :model_id]
  end

  @pricing_units ["token", "audio_second"]

  @doc "Allowed `pricing.unit` values (strings)."
  def pricing_units, do: @pricing_units

  @doc """
  Estimates cost from `pricing` (per-million-token rates). Observability calls this during ingest
  when the provider reports no cost. Returns `nil` when both `input_per_m` and `output_per_m` are
  missing; when only one is present, the missing side counts as 0.
  """
  @spec estimate_cost(t() | map(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          Decimal.t() | nil
  def estimate_cost(%{pricing: pricing}, input_tokens, output_tokens) do
    pricing = PromptOnSDK.Params.stringify_keys(pricing)
    input_rate = to_decimal(pricing["input_per_m"])
    output_rate = to_decimal(pricing["output_per_m"])

    if is_nil(input_rate) and is_nil(output_rate) do
      nil
    else
      Decimal.add(per_million(input_rate, input_tokens), per_million(output_rate, output_tokens))
    end
  end

  @million Decimal.new(1_000_000)

  defp per_million(nil, _tokens), do: Decimal.new(0)
  defp per_million(_rate, nil), do: Decimal.new(0)

  defp per_million(rate, tokens) when is_integer(tokens) do
    rate |> Decimal.mult(Decimal.new(tokens)) |> Decimal.div(@million)
  end

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal(n) when is_binary(n) do
    case Decimal.parse(n) do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp to_decimal(_), do: nil
end
