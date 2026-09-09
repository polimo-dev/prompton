defmodule PromptOnWeb.ArenaLogSamples do
  @moduledoc """
  Reads recent monitoring-log variables that can seed Arena runs.

  Listing only touches the narrow `Generation` table and payload metadata. The encrypted
  `GenerationPayload.variables` value is loaded only after the user selects one generation.
  """

  require Ash.Query

  alias PromptOn.Observability
  alias PromptOn.Observability.Generation
  alias PromptOn.Observability.GenerationPayload
  alias PromptOn.Prompts.UseCase

  @limit 20
  @stored_payload_states [:stored, :truncated]

  @type sample :: %{
          id: String.t(),
          model: String.t(),
          provider: atom(),
          status: atom(),
          started_at: DateTime.t(),
          latency_ms: non_neg_integer() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          end_user_ref: String.t() | nil,
          trace_id: String.t() | nil,
          sequence: integer() | nil,
          prompt: String.t() | nil,
          prompt_version_id: String.t() | nil
        }

  @doc """
  Returns bounded recent live generations whose unexpired payload can still provide variables.

  `scope` is the caller's normal LiveView scope (`tenant:` and `actor:`). Errors are returned so
  the UI can distinguish "no logs" from "logs could not be read".
  """
  @spec list(UseCase.t(), keyword()) :: {:ok, [sample()]} | {:error, term()}
  def list(%UseCase{} = use_case, scope) when is_list(scope) do
    with :ok <- same_tenant(use_case, scope) do
      now = DateTime.utc_now()

      Generation
      |> Ash.Query.for_read(:read, %{}, scope)
      |> Ash.Query.select([
        :id,
        :model,
        :provider,
        :status,
        :started_at,
        :latency_ms,
        :input_tokens,
        :output_tokens,
        :end_user_ref,
        :trace_id,
        :sequence,
        :prompt,
        :prompt_version_id
      ])
      |> Ash.Query.filter(
        source == :live and payload_state in ^@stored_payload_states and
          exists(payload, expires_at > ^now) and
          (use_case_id == ^use_case.id or
             (is_nil(use_case_id) and use_case_key == ^use_case.key))
      )
      |> Ash.Query.sort(started_at: :desc, id: :desc)
      |> Ash.Query.limit(@limit)
      |> Ash.read()
      |> case do
        {:ok, generations} -> {:ok, Enum.map(generations, &sample/1)}
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc """
  Loads the stored variables for one selected sample.

  The generation is rechecked under the caller's actor and tenant before the encrypted variables
  field is explicitly loaded. Missing, expired, hashed, dropped, playground, or cross-use-case rows
  return `{:error, :unavailable}`.
  """
  @spec variables(UseCase.t(), String.t(), keyword()) :: {:ok, map()} | {:error, :unavailable}
  def variables(%UseCase{} = use_case, generation_id, scope)
      when is_binary(generation_id) and is_list(scope) do
    with :ok <- same_tenant(use_case, scope),
         {:ok, %Generation{} = generation} <- Observability.get_generation(generation_id, scope),
         true <- eligible_generation?(generation, use_case),
         {:ok, loaded} <- load_unexpired_variables(generation.id, scope),
         true <- unexpired_payload?(loaded) do
      {:ok, loaded.variables || %{}}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp same_tenant(%UseCase{project_id: project_id}, scope) do
    if Keyword.get(scope, :tenant) == project_id, do: :ok, else: {:error, :unavailable}
  end

  defp eligible_generation?(%Generation{} = generation, %UseCase{} = use_case) do
    generation.source == :live and generation.payload_state in @stored_payload_states and
      same_use_case?(generation, use_case)
  end

  defp same_use_case?(%{use_case_id: use_case_id}, %{id: use_case_id})
       when not is_nil(use_case_id),
       do: true

  defp same_use_case?(%{use_case_id: nil, use_case_key: key}, %{key: key}), do: true
  defp same_use_case?(_generation, _use_case), do: false

  defp unexpired_payload?(nil), do: false

  defp unexpired_payload?(%{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  defp load_unexpired_variables(generation_id, scope) do
    now = DateTime.utc_now()

    GenerationPayload
    |> Ash.Query.for_read(:read, %{}, scope)
    |> Ash.Query.filter(generation_id == ^generation_id and expires_at > ^now)
    |> Ash.Query.load([:variables])
    |> Ash.read_one()
  end

  defp sample(%Generation{} = generation) do
    %{
      id: generation.id,
      model: generation.model,
      provider: generation.provider,
      status: generation.status,
      started_at: generation.started_at,
      latency_ms: generation.latency_ms,
      input_tokens: generation.input_tokens,
      output_tokens: generation.output_tokens,
      end_user_ref: generation.end_user_ref,
      trace_id: generation.trace_id,
      sequence: generation.sequence,
      prompt: generation.prompt,
      prompt_version_id: generation.prompt_version_id
    }
  end
end
