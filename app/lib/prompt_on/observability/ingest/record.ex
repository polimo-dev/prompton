defmodule PromptOn.Observability.Ingest.Record do
  @moduledoc """
  Validation and normalization of one §6.4 Generation payload (plan.md §6.4, §9.2). On success it
  returns the `Generation.:ingest` input (attrs) and the raw pieces
  (`input`/`output`/`usage_raw`/`prehashed`); on failure `{:error, message}` -- only that record
  goes to `rejected`, not the whole batch (partial acceptance).

  Validation rules
  - Required: `id` (UUID), `use_case` (string), `model` (string), `status` (`ok|error`),
    `started_at` (ISO8601).
  - `started_at` must be within `[now - 7d, now + 5m]`. Outside it is rejected (guards against
    resend storms and clock skew; backfills go through a mix task).
  - Soft refs (`deployment_id`/`prompt_version_id`/`model_id`) are a UUID or null, `prompt` is a
    string, `deployment_revision` is an integer or null.
  - `context` ≤ 2KB, `metadata` ≤ 4KB (JSON bytes). `usage.*_tokens`/`latency_ms`/`sequence` are
    integers.
  - **Values the DB would reject are filtered here up front** (contract decision #7 -- one record
    must not poison the batch): every integer is within the int8 range (−2^63..2^63−1), every
    string (including keys/values inside jsonb maps) is valid UTF-8 and contains no NUL
    (`\\u0000`).
  - `params` ≤ 4KB, `usage.raw` ≤ 16KB (JSON bytes) -- exceeding them does not reject; **only that
    field is emptied** and its name is written to `metadata.truncated_fields` (decision #9).
  - Lenient normalization: an unknown `provider` → `:other`. `stop_kind` passes through when it is
    one of the five canonical values (`stop|length|tool_call|content_filter|other`); otherwise it is
    derived from `finish_reason` via `PromptOnSDK.StopKind.normalize/1` (decision #1; the payload
    storage decision needs to know about truncation, so it is filled in here up front). `cost_usd`
    number/string → Decimal.
  - A string `input`/`output` is wrapped as `{"text": …}` / `{"content": …}` (decision #5). A map
    holding exactly `{"sha256", "bytes"}` (optionally `"hashed": true`) is something the SDK
    pre-hashed in `mode :hash` -- it is returned as `prehashed` and there is no raw content
    (decision #3).
  - `model_used`/`upstream_provider`/`error.status` →
    `metadata.model_used|upstream_provider|http_status`.
  - `project`/`environment`/`source` ignore the payload values and are forced from the actor (the
    action change).
  """

  alias PromptOn.Observability.Generation
  alias PromptOn.Observability.Ingest.Truncation

  @past_window_seconds 7 * 24 * 3600
  @future_window_seconds 5 * 60
  @context_max_bytes 2_048
  @metadata_max_bytes 4_096
  @params_max_bytes 4_096
  @usage_raw_max_bytes 16_384
  @string_max_bytes 512
  @int8_min -9_223_372_036_854_775_808
  @int8_max 9_223_372_036_854_775_807
  @canonical_stop_kinds Generation.stop_kinds()

  @type prehashed :: %{sha256: String.t(), bytes: non_neg_integer()}
  @type normalized :: %{
          attrs: map(),
          input: map() | nil,
          output: map() | nil,
          usage_raw: map() | nil,
          prehashed: %{input: prehashed() | nil, output: prehashed() | nil}
        }

  @doc """
  One payload map → `{:ok, normalized}` | `{:error, message}`. `now` is the batch-wide receive time.
  """
  @spec normalize(term(), DateTime.t()) :: {:ok, normalized()} | {:error, String.t()}
  def normalize(record, now) when is_map(record) do
    with {:ok, id} <- uuid(record["id"], "id", required: true),
         {:ok, use_case_key} <- string(record["use_case"], "use_case", required: true),
         {:ok, model} <- string(record["model"], "model", required: true),
         {:ok, status} <- enum(record["status"], "status", [:ok, :error], required: true),
         {:ok, started_at} <- started_at(record["started_at"], now),
         {:ok, kind} <- enum(record["kind"], "kind", Generation.kinds()),
         {:ok, deployment_id} <- uuid(record["deployment_id"], "deployment_id"),
         {:ok, deployment_revision} <-
           integer(record["deployment_revision"], "deployment_revision", min: 1),
         {:ok, prompt} <- string(record["prompt"], "prompt"),
         {:ok, prompt_version_id} <- uuid(record["prompt_version_id"], "prompt_version_id"),
         {:ok, model_id} <- uuid(record["model_id"], "model_id"),
         {:ok, resolution_source} <-
           enum(record["resolution_source"], "resolution_source", Generation.resolution_sources()),
         {:ok, finish_reason} <- string(record["finish_reason"], "finish_reason"),
         {:ok, trace_id} <- string(record["trace_id"], "trace_id"),
         {:ok, end_user_ref} <- string(record["end_user_ref"], "end_user_ref"),
         {:ok, model_used} <- string(record["model_used"], "model_used"),
         {:ok, upstream_provider} <- string(record["upstream_provider"], "upstream_provider"),
         {:ok, latency_ms} <- integer(record["latency_ms"], "latency_ms", min: 0),
         {:ok, sequence} <- integer(record["sequence"], "sequence"),
         {:ok, params} <- map(record["params"], "params"),
         {:ok, context} <- map(record["context"], "context", max_bytes: @context_max_bytes),
         {:ok, metadata} <- map(record["metadata"], "metadata", max_bytes: @metadata_max_bytes),
         {:ok, usage} <- map(record["usage"], "usage", deep?: false),
         {:ok, input_tokens} <- integer(usage["input_tokens"], "usage.input_tokens", min: 0),
         {:ok, output_tokens} <- integer(usage["output_tokens"], "usage.output_tokens", min: 0),
         {:ok, cost_usd} <- decimal(usage["cost_usd"], "usage.cost_usd"),
         {:ok, cost_source} <-
           enum(usage["cost_source"], "usage.cost_source", Generation.cost_sources()),
         {:ok, usage_raw} <- map(usage["raw"], "usage.raw", nil?: true),
         {:ok, error} <- map(record["error"], "error", deep?: false),
         {:ok, error_kind} <- enum(error["kind"], "error.kind", Generation.error_kinds()),
         {:ok, http_status} <- integer(error["status"], "error.status"),
         {:ok, error_message} <- string(error["message"], "error.message", max_bytes: nil),
         {:ok, sdk} <- map(record["sdk"], "sdk", deep?: false),
         {:ok, sdk_version} <- string(sdk["version"], "sdk.version"),
         {:ok, {input, input_hash}} <- payload_part(record["input"], "input", "text"),
         {:ok, {output, output_hash}} <- payload_part(record["output"], "output", "content") do
      {params, params_truncated} = cap_field(params, "params", @params_max_bytes, %{})
      {usage_raw, raw_truncated} = cap_field(usage_raw, "usage.raw", @usage_raw_max_bytes, nil)

      metadata =
        metadata
        |> put_present("model_used", model_used)
        |> put_present("upstream_provider", upstream_provider)
        |> put_present("http_status", http_status)
        |> put_truncated_fields(params_truncated ++ raw_truncated)

      attrs = %{
        id: id,
        use_case_key: use_case_key,
        model: model,
        model_id: model_id,
        provider: provider(record["provider"]),
        kind: kind || :chat,
        status: status,
        started_at: started_at,
        received_at: now,
        deployment_id: deployment_id,
        deployment_revision: deployment_revision,
        prompt: prompt,
        prompt_version_id: prompt_version_id,
        resolution_source: resolution_source,
        finish_reason: finish_reason,
        stop_kind: stop_kind(record["stop_kind"], finish_reason),
        error_kind: error_kind,
        error_message: error_message,
        latency_ms: latency_ms,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cost_usd: cost_usd,
        cost_source: cost_source || (cost_usd && :provider),
        trace_id: trace_id,
        sequence: sequence,
        end_user_ref: end_user_ref,
        sdk_version: sdk_version,
        params: params,
        context: context,
        metadata: metadata
      }

      {:ok,
       %{
         attrs: attrs,
         input: input,
         output: output,
         usage_raw: usage_raw,
         prehashed: %{input: input_hash, output: output_hash}
       }}
    end
  end

  def normalize(_record, _now), do: {:error, "generation must be an object"}

  # ---------------------------------------------------------------------------
  # Field validators

  defp uuid(value, field, opts \\ [])

  defp uuid(nil, field, opts),
    do: if(opts[:required], do: {:error, "#{field} is required"}, else: {:ok, nil})

  defp uuid(value, field, _opts) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "#{field} must be a UUID"}
    end
  end

  defp uuid(_value, field, _opts), do: {:error, "#{field} must be a UUID"}

  defp string(value, field, opts \\ [])

  defp string(nil, field, opts),
    do: if(opts[:required], do: {:error, "#{field} is required"}, else: {:ok, nil})

  defp string("", field, opts) do
    if opts[:required], do: {:error, "#{field} must not be empty"}, else: {:ok, nil}
  end

  defp string(value, field, opts) when is_binary(value) do
    max = Keyword.get(opts, :max_bytes, @string_max_bytes)

    cond do
      not String.valid?(value) ->
        {:error, "#{field} must be valid UTF-8"}

      nul?(value) ->
        {:error, "#{field} must not contain NUL bytes"}

      is_integer(max) and byte_size(value) > max ->
        {:error, "#{field} must be at most #{max} bytes"}

      true ->
        {:ok, value}
    end
  end

  defp string(_value, field, _opts), do: {:error, "#{field} must be a string"}

  defp enum(value, field, allowed, opts \\ [])

  defp enum(nil, field, _allowed, opts),
    do: if(opts[:required], do: {:error, "#{field} is required"}, else: {:ok, nil})

  defp enum(value, field, allowed, _opts) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, "#{field} must be one of #{Enum.map_join(allowed, "|", &Atom.to_string/1)}"}
      atom -> {:ok, atom}
    end
  end

  defp enum(value, field, allowed, opts) when is_atom(value),
    do: enum(Atom.to_string(value), field, allowed, opts)

  defp enum(_value, field, _allowed, _opts), do: {:error, "#{field} must be a string"}

  defp integer(value, field, opts \\ [])
  defp integer(nil, _field, _opts), do: {:ok, nil}

  defp integer(value, field, opts) when is_integer(value) do
    min = opts[:min]

    cond do
      value < @int8_min or value > @int8_max ->
        {:error, "#{field} must be within the 64-bit integer range"}

      is_integer(min) and value < min ->
        {:error, "#{field} must be >= #{min}"}

      true ->
        {:ok, value}
    end
  end

  # Integer-valued floats such as 5.0 are allowed (a JSON encoder may send them as floats).
  defp integer(value, field, opts) when is_float(value) do
    if Float.floor(value) == value,
      do: integer(trunc(value), field, opts),
      else: {:error, "#{field} must be integer"}
  end

  defp integer(_value, field, _opts), do: {:error, "#{field} must be integer"}

  defp decimal(nil, _field), do: {:ok, nil}
  defp decimal(%Decimal{} = value, _field), do: {:ok, value}
  defp decimal(value, _field) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal(value, _field) when is_float(value), do: {:ok, Decimal.from_float(value)}

  defp decimal(value, field) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, "#{field} must be a number"}
    end
  end

  defp decimal(_value, field), do: {:error, "#{field} must be a number"}

  defp map(value, field, opts \\ [])
  defp map(nil, _field, opts), do: {:ok, if(opts[:nil?], do: nil, else: %{})}

  defp map(value, field, opts) when is_map(value) do
    with :ok <- if(opts[:deep?] == false, do: :ok, else: storable(value, field)),
         :ok <- within_bytes(value, field, opts[:max_bytes]) do
      {:ok, value}
    end
  end

  defp map(_value, field, _opts), do: {:error, "#{field} must be an object"}

  defp within_bytes(_value, _field, nil), do: :ok

  defp within_bytes(value, field, max) do
    size = Truncation.json_size(value)
    if size > max, do: {:error, "#{field} must be at most #{max} bytes (got #{size})"}, else: :ok
  end

  # A field over its cap is emptied, not rejected (decision #9). Returns `{value, [field] | []}`.
  defp cap_field(nil, _field, _max, empty), do: {empty, []}

  defp cap_field(value, field, max, empty) do
    if Truncation.json_size(value) > max, do: {empty, [field]}, else: {value, []}
  end

  defp put_truncated_fields(metadata, []), do: metadata

  defp put_truncated_fields(metadata, fields) do
    existing = List.wrap(metadata["truncated_fields"])
    Map.put(metadata, "truncated_fields", Enum.uniq(existing ++ fields))
  end

  # input/output: wrap strings (decision #5); a `{"sha256","bytes"}` wrapper is recognized as
  # pre-hashed (decision #3). Returns `{:ok, {content_map | nil, prehashed | nil}}`.
  defp payload_part(nil, _field, _wrap_key), do: {:ok, {nil, nil}}

  defp payload_part(value, field, wrap_key) when is_binary(value),
    do: payload_part(%{wrap_key => value}, field, wrap_key)

  defp payload_part(%{"sha256" => sha256, "bytes" => bytes} = value, field, _wrap_key)
       when map_size(value) == 2 or (map_size(value) == 3 and is_map_key(value, "hashed")) do
    with {:ok, sha256} <- sha256_hex(sha256, field),
         {:ok, bytes} when is_integer(bytes) <- integer(bytes, "#{field}.bytes", min: 0) do
      {:ok, {nil, %{sha256: sha256, bytes: bytes}}}
    else
      {:ok, nil} -> {:error, "#{field}.bytes must be integer"}
      error -> error
    end
  end

  defp payload_part(value, field, _wrap_key) do
    with {:ok, map} <- map(value, field, nil?: true), do: {:ok, {map, nil}}
  end

  defp sha256_hex(value, field) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :mixed) do
      {:ok, _} -> {:ok, String.downcase(value)}
      :error -> {:error, "#{field}.sha256 must be a hex sha256"}
    end
  end

  defp sha256_hex(_value, field), do: {:error, "#{field}.sha256 must be a hex sha256"}

  @doc """
  Walks the whole value that will be stored as jsonb: strings (keys and values) must be valid UTF-8
  with no NUL, integers must be within the int8 range (decision #7). `:ok | {:error, message}`. The
  server-internal recording path (the arena) also pre-filters `context`/`metadata` by the same
  rules -- recording is asynchronous there, so a DB rejection would make the log disappear
  **silently**.
  """
  @spec storable(term(), String.t()) :: :ok | {:error, String.t()}
  def storable(value, field) do
    case find_unstorable(value) do
      nil -> :ok
      :invalid_utf8 -> {:error, "#{field} must be valid UTF-8"}
      :nul -> {:error, "#{field} must not contain NUL bytes"}
      :int_range -> {:error, "#{field} contains an integer outside the 64-bit range"}
    end
  end

  defp find_unstorable(value) when is_binary(value) do
    cond do
      not String.valid?(value) -> :invalid_utf8
      nul?(value) -> :nul
      true -> nil
    end
  end

  defp find_unstorable(value) when is_integer(value) do
    if value < @int8_min or value > @int8_max, do: :int_range, else: nil
  end

  defp find_unstorable(value) when is_map(value) do
    Enum.find_value(value, fn {k, v} -> find_unstorable(k) || find_unstorable(v) end)
  end

  defp find_unstorable(value) when is_list(value), do: Enum.find_value(value, &find_unstorable/1)
  defp find_unstorable(value) when is_atom(value), do: find_unstorable(Atom.to_string(value))
  defp find_unstorable(_value), do: nil

  defp nul?(value), do: :binary.match(value, <<0>>) != :nomatch

  defp started_at(nil, _now), do: {:error, "started_at is required"}

  defp started_at(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        diff = DateTime.diff(dt, now, :second)

        cond do
          diff > @future_window_seconds ->
            {:error, "started_at is more than 5 minutes in the future"}

          diff < -@past_window_seconds ->
            {:error, "started_at is more than 7 days in the past"}

          true ->
            {:ok, dt}
        end

      {:error, _} ->
        {:error, "started_at must be an ISO8601 datetime"}
    end
  end

  defp started_at(_value, _now), do: {:error, "started_at must be an ISO8601 datetime"}

  defp provider(value) when is_binary(value) do
    Enum.find(Generation.providers(), :other, &(Atom.to_string(&1) == value))
  end

  defp provider(_), do: :other

  # A canonical value passes through (idempotent); otherwise derive from finish_reason. Both
  # missing → nil (error records, embeddings); only an unknown stop_kind and no finish_reason →
  # :other.
  defp stop_kind(value, finish_reason) do
    canonical_stop_kind(value) || derived_stop_kind(finish_reason, value)
  end

  defp canonical_stop_kind(value) when is_binary(value) do
    Enum.find(@canonical_stop_kinds, &(Atom.to_string(&1) == value))
  end

  defp canonical_stop_kind(value) when is_atom(value) and not is_nil(value),
    do: canonical_stop_kind(Atom.to_string(value))

  defp canonical_stop_kind(_), do: nil

  defp derived_stop_kind(nil, nil), do: nil
  defp derived_stop_kind(nil, _unknown), do: :other
  defp derived_stop_kind(reason, _), do: PromptOnSDK.StopKind.normalize(reason)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc "Time windows (seconds): 7 days into the past / 5 minutes into the future."
  def windows, do: %{past_seconds: @past_window_seconds, future_seconds: @future_window_seconds}

  @doc "Size caps (bytes): context 2KB, metadata 4KB, params 4KB, usage.raw 16KB, strings 512B."
  def limits,
    do: %{
      context: @context_max_bytes,
      metadata: @metadata_max_bytes,
      params: @params_max_bytes,
      usage_raw: @usage_raw_max_bytes,
      string: @string_max_bytes
    }
end
