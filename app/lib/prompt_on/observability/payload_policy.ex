defmodule PromptOn.Observability.PayloadPolicy do
  @moduledoc """
  Embedded storage policy for raw content (GenerationPayload) (plan.md §9.3). Project default +
  UseCase override; it rides in the snapshot so the SDK applies the same rules.

  - `mode` `:full` (store raw content) | `:hash` (sha256 only) | `:none`
  - `sample_rate` 0.0~1.0 -- error/truncated records are stored regardless of sampling (not stored
    under `:none`)
  - `max_bytes` default 256KB, max 1MB -- one message = max_bytes/8, input total = max_bytes,
    output = max_bytes/4
  - `retention_days` default 30 (1~365)
  - `encrypt?` whether ash_cloak encrypts
  """

  use Ash.Resource, data_layer: :embedded

  @default_max_bytes 262_144
  @max_max_bytes 1_048_576

  attributes do
    attribute :mode, :atom do
      allow_nil? false
      public? true
      default :full
      constraints one_of: [:full, :hash, :none]
    end

    attribute :sample_rate, :float do
      allow_nil? false
      public? true
      default 1.0
      constraints min: 0.0, max: 1.0
    end

    attribute :max_bytes, :integer do
      allow_nil? false
      public? true
      default @default_max_bytes
      constraints min: 1_024, max: @max_max_bytes
    end

    attribute :retention_days, :integer do
      allow_nil? false
      public? true
      default 30
      constraints min: 1, max: 365
    end

    attribute :encrypt?, :boolean, allow_nil?: false, public?: true, default: true
  end

  @doc "The default policy (at Project creation)."
  def default,
    do:
      struct(__MODULE__,
        mode: :full,
        sample_rate: 1.0,
        max_bytes: @default_max_bytes,
        retention_days: 30,
        encrypt?: true
      )

  @doc "Lays the UseCase override (nil allowed) over the Project default."
  def effective(project_policy, nil), do: project_policy || default()
  def effective(_project_policy, %{__struct__: __MODULE__} = override), do: override

  @doc "Map for snapshot/JSON serialization (the SDK contract, plan.md §6.2)."
  def to_map(%{__struct__: __MODULE__} = p) do
    %{
      "mode" => Atom.to_string(p.mode),
      "sample_rate" => p.sample_rate,
      "max_bytes" => p.max_bytes,
      "retention_days" => p.retention_days,
      "encrypt" => p.encrypt?
    }
  end

  def to_map(nil), do: to_map(default())

  @doc """
  Deterministic sampling (plan.md §7.5, §9.3):
  `first4bytes(sha256(id)) rem 10_000 < round(sample_rate * 10_000)`. The SDK and the server use
  the same rule, so applying it on either side gives the same result. `sample_rate 1.0` is always
  true, `0.0` always false.
  """
  @spec sample?(t() | map(), String.t()) :: boolean()
  def sample?(%{sample_rate: rate}, id) when is_binary(id) do
    cond do
      rate >= 1.0 -> true
      rate <= 0.0 -> false
      true -> bucket(id) < round(rate * 10_000)
    end
  end

  @doc """
  Sampling bucket 0..9999 (contract decision #2): read the **first 4 bytes of the `sha256(id)`
  digest as an unsigned big-endian integer**, then `rem 10_000`. This differs from reading the whole
  digest as an integer -- vectors shared with the SDK:
  `"0192a3b4-0000-7000-8000-000000000001"` → 2656, `"00000000-0000-0000-0000-000000000000"` → 8252.
  """
  @spec bucket(String.t()) :: non_neg_integer()
  def bucket(id) when is_binary(id) do
    <<n::unsigned-big-32, _::binary>> = :crypto.hash(:sha256, id)
    rem(n, 10_000)
  end

  @doc """
  The storage decision (plan.md §5.7, §9.3). `mode :none` → `:drop`; `:hash` → `:hash`; `:full` →
  `:store` when the record is in the sample or is an error/truncated record (`always_keep?`),
  otherwise `:drop`.
  """
  @spec decide(t() | map(), String.t(), boolean()) :: :store | :hash | :drop
  def decide(%{mode: :none}, _id, _always_keep?), do: :drop
  def decide(%{mode: :hash}, _id, _always_keep?), do: :hash

  def decide(%{mode: :full} = policy, id, always_keep?) do
    if always_keep? or sample?(policy, id), do: :store, else: :drop
  end
end
