defmodule PromptOn.Observability.Ingest do
  @moduledoc """
  The `POST /generations` batch ingest service (plan.md §6.4, §9.2, §9.3). Called directly from the
  request handler; no queue or job in between.

      ingest(generations, actor: api_key, tenant: api_key.project_id)
      #=> {:ok, %{accepted: 98, duplicates: 2, rejected: [%{index: 5, id: "…", code: "invalid_request", message: "…"}]}}

  Flow
  1. Per-record validation and normalization (`Ingest.Record`) -- failures go to `rejected`
     (partial acceptance).
  2. Remove duplicate ids within the batch + look up already-stored ids
     (`SELECT id, project_id WHERE id = ANY` -- **without a tenant filter**) → the same project
     means `duplicates`, a different project means `rejected(code: "conflict")` (decision #10; a
     PK conflict is DO NOTHING, which silently stores nothing, so it has to be caught here). The
     DO NOTHING upsert of `:ingest` is the safety net for racing resends; the counts come from
     this pre-check.
  3. Look up `use_case_key` → UseCase (id/kind/payload_policy) once per batch and combine it with
     the Project default policy to decide the **effective PayloadPolicy**.
  4. Raw-content storage decision (`PayloadPolicy.decide/3`): `:none` → `payload_state :dropped`;
     `:hash` → hashes and sizes only (`:hashed`); `:full` → sampling (`sha256(id)`, deterministic;
     **error/truncated records are always stored**) then size-cap truncation
     (`Ingest.Truncation`) → `:stored | :truncated`. With no raw content (input/output) at all →
     `:dropped`. A record the SDK already hashed as `{"sha256","bytes"}` becomes `:hashed` with
     those values regardless of policy (`:none` is the only exception) (decision #3).
  5. Inside `Repo.transaction`, `Ash.bulk_create(Generation, :ingest)` (actor = the calling actor;
     the environment is forced by the action change) → the payloads of the accepted records go
     through `Ash.bulk_create(GenerationPayload, :store)` (SystemActor). Both use
     `return_records?: false, notify?: false, upsert?: true, upsert_fields: []`.

  **No poison batches (decision #7)**: even when the batch statement fails with a DB error (a value
  the pre-validation could not filter, a MERGE unique violation from a concurrent same-id batch),
  the whole request is not turned into a 503. The batch runs inside a SAVEPOINT; on an error whose
  position is unknown, roll back to the SAVEPOINT and then -- for a unique violation, re-query the
  stored ids, pull them out as `duplicates`/`conflict`, and run the rest as one more batch; for any
  other error, retry per record (each in its own SAVEPOINT) and isolate only the culprit as
  `rejected`. Payload storage works the same way (a failed payload is dropped after a warning log
  -- the Generation row remains).

  Telemetry: `[:prompton, :ingest, :batch]` (`count/accepted/duplicates/rejected/duration/bytes`),
  `[:prompton, :ingest, :retry]` (`%{count: 1, records: n}`,
  `%{reason: :unique_violation | :other, tenant:}` -- a retry after a batch failure),
  `[:prompton, :ingest, :rejected]` (`%{count: 1}`, `%{reason: message}`) per record.
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query
  require Logger

  alias PromptOn.Observability.{Generation, GenerationPayload, PayloadPolicy}
  alias PromptOn.Observability.Ingest.{Record, Truncation}
  alias PromptOn.Projects.ApiKey
  alias PromptOn.Prompts.UseCase
  alias PromptOn.Repo

  @max_batch 200
  @bulk_opts [
    return_records?: false,
    notify?: false,
    batch_size: 200,
    upsert?: true,
    upsert_fields: [],
    stop_on_error?: false,
    return_errors?: true,
    transaction: false,
    rollback_on_error?: false
  ]

  @type rejected :: %{
          index: non_neg_integer(),
          id: String.t() | nil,
          code: String.t(),
          message: String.t()
        }
  @type result :: %{
          accepted: non_neg_integer(),
          duplicates: non_neg_integer(),
          rejected: [rejected()]
        }

  @doc "The batch cap (records)."
  def max_batch, do: @max_batch

  @doc """
  Options: `actor:` (required -- `%ApiKey{}` or `%SystemActor{}`), `tenant:` (required,
  project_id), `environment_id:` (the environment this batch is recorded under -- the controller
  picks it from the request parameter; nil when absent), `bytes:` (request body size, for
  telemetry).
  If the ApiKey actor's project differs from `tenant`, `{:error, :forbidden}` (decision #10 -- the
  policy applies the same condition).
  """
  @spec ingest([map()], keyword()) :: {:ok, result()} | {:error, term()}
  def ingest(generations, opts) when is_list(generations) and length(generations) <= @max_batch do
    actor = Keyword.fetch!(opts, :actor)
    tenant = Keyword.fetch!(opts, :tenant)

    case actor do
      %ApiKey{project_id: project_id} when project_id != tenant -> {:error, :forbidden}
      _ -> do_ingest(generations, actor, tenant, opts)
    end
  end

  def ingest(generations, _opts) when is_list(generations),
    do: {:error, {:invalid_request, "at most #{@max_batch} generations per request"}}

  def ingest(_generations, _opts), do: {:error, {:invalid_request, "generations must be a list"}}

  defp do_ingest(generations, actor, tenant, opts) do
    now = DateTime.utc_now()
    started = System.monotonic_time()

    {normalized, rejected} = normalize_all(generations, now)
    {unique, in_batch_dups} = dedupe(normalized)
    {fresh, existing_dups, conflicts} = split_existing(unique, tenant)

    fresh = attach_use_cases(fresh, tenant, opts)
    fresh = Enum.map(fresh, &decide_payload(&1, now))

    with {:ok, {accepted, insert_rejected, insert_dups}} <- insert(fresh, actor, tenant) do
      rejected = Enum.sort_by(rejected ++ conflicts ++ insert_rejected, & &1.index)
      duplicates = in_batch_dups + existing_dups + insert_dups

      result = %{accepted: accepted, duplicates: duplicates, rejected: rejected}

      :telemetry.execute(
        [:prompton, :ingest, :batch],
        %{
          count: length(generations),
          accepted: accepted,
          duplicates: duplicates,
          rejected: length(rejected),
          duration: System.monotonic_time() - started,
          bytes: Keyword.get(opts, :bytes, 0)
        },
        %{tenant: tenant}
      )

      {:ok, result}
    end
  end

  # ---------------------------------------------------------------------------
  # 1. Validation

  defp normalize_all(generations, now) do
    generations
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {record, index}, {ok, rejected} ->
      case Record.normalize(record, now) do
        {:ok, normalized} ->
          {[Map.put(normalized, :index, index) | ok], rejected}

        {:error, message} ->
          {ok, [reject(index, record, message) | rejected]}
      end
    end)
    |> then(fn {ok, rejected} -> {Enum.reverse(ok), Enum.reverse(rejected)} end)
  end

  defp reject(index, record, message, code \\ "invalid_request") do
    :telemetry.execute([:prompton, :ingest, :rejected], %{count: 1}, %{reason: message})
    id = if is_map(record), do: record["id"], else: nil

    %{
      index: index,
      id: if(is_binary(id), do: id, else: nil),
      code: code,
      message: message
    }
  end

  defp reject_item(item, message, code \\ "invalid_request"),
    do: reject(item.index, %{"id" => item.attrs.id}, message, code)

  # ---------------------------------------------------------------------------
  # 2. Duplicates

  # Keep only the first of any repeated id within a batch (MERGE/ON CONFLICT cannot touch the same
  # row twice in one statement).
  defp dedupe(normalized) do
    {unique, _seen, dups} =
      Enum.reduce(normalized, {[], MapSet.new(), 0}, fn item, {acc, seen, dups} ->
        if MapSet.member?(seen, item.attrs.id),
          do: {acc, seen, dups + 1},
          else: {[item | acc], MapSet.put(seen, item.attrs.id), dups}
      end)

    {Enum.reverse(unique), dups}
  end

  # Look up stored ids without a tenant filter and split into {fresh records, same-project
  # duplicate count, other-project conflicts (rejected)}.
  defp split_existing([], _tenant), do: {[], 0, []}

  defp split_existing(items, tenant) do
    existing = existing_ids(items)

    Enum.reduce(items, {[], 0, []}, fn item, {fresh, dups, conflicts} ->
      case Map.fetch(existing, item.attrs.id) do
        :error ->
          {[item | fresh], dups, conflicts}

        {:ok, ^tenant} ->
          {fresh, dups + 1, conflicts}

        {:ok, _other_project} ->
          rejected = reject_item(item, "id already exists in another project", "conflict")
          {fresh, dups, [rejected | conflicts]}
      end
    end)
    |> then(fn {fresh, dups, conflicts} ->
      {Enum.reverse(fresh), dups, Enum.reverse(conflicts)}
    end)
  end

  # The PK is globally unique, so look without a tenant (`Generation` is `global? false`, so Ash
  # cannot read it -- this is an internal pre-check, so go through Ecto directly). Returns
  # `%{id => project_id}`.
  defp existing_ids(items) do
    ids = Enum.map(items, & &1.attrs.id)

    from(g in Generation, where: g.id in ^ids, select: {g.id, g.project_id})
    |> Repo.all()
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # 3. UseCase / policy

  defp attach_use_cases([], _tenant, _opts), do: []

  defp attach_use_cases(items, tenant, opts) do
    keys = items |> Enum.map(& &1.attrs.use_case_key) |> Enum.uniq()
    system = PromptOn.SystemActor.new()

    use_cases =
      UseCase
      |> Ash.Query.filter(key in ^keys)
      |> Ash.Query.select([:id, :key, :kind, :payload_policy])
      |> Ash.read!(tenant: tenant, actor: system)
      |> Map.new(&{&1.key, &1})

    project_policy =
      case PromptOn.Projects.get_project(tenant, actor: system) do
        {:ok, %{payload_policy: policy}} when not is_nil(policy) -> policy
        _ -> PayloadPolicy.default()
      end

    environment_id = Keyword.get(opts, :environment_id)

    Enum.map(items, fn item ->
      use_case = Map.get(use_cases, item.attrs.use_case_key)
      policy = PayloadPolicy.effective(project_policy, use_case && use_case.payload_policy)

      attrs =
        item.attrs
        |> Map.put(:use_case_id, use_case && use_case.id)
        |> Map.put(:environment_id, environment_id)

      item |> Map.put(:attrs, attrs) |> Map.put(:policy, policy)
    end)
  end

  # ---------------------------------------------------------------------------
  # 4. Raw-content storage decision

  defp decide_payload(%{attrs: attrs, policy: policy} = item, now) do
    always_keep? = attrs.status == :error or attrs.stop_kind == :length
    has_content? = not (is_nil(item.input) and is_nil(item.output))
    prehashed? = not (is_nil(item.prehashed.input) and is_nil(item.prehashed.output))

    decision =
      cond do
        policy.mode == :none -> :drop
        prehashed? -> :hash
        has_content? -> PayloadPolicy.decide(policy, attrs.id, always_keep?)
        true -> :drop
      end

    {state, payload} = build_payload(decision, item, now)
    item |> put_in([:attrs, :payload_state], state) |> Map.put(:payload, payload)
  end

  defp build_payload(:drop, _item, _now), do: {:dropped, nil}

  defp build_payload(:hash, item, now) do
    payload =
      Map.merge(base_payload(item, now), %{
        truncated?: flagged_truncated?(item),
        encrypted?: false
      })

    {:hashed, payload}
  end

  defp build_payload(:store, item, now) do
    {input, output, truncated?} =
      Truncation.apply(item.input, item.output, item.policy.max_bytes)

    {variables, input} = pop_variables(input)

    payload =
      Map.merge(base_payload(item, now), %{
        input: input,
        output: output,
        variables: variables,
        truncated?: truncated?,
        encrypted?: true
      })

    {if(truncated?, do: :truncated, else: :stored), payload}
  end

  defp base_payload(item, now) do
    Map.merge(hashes(item), %{
      generation_id: item.attrs.id,
      usage_raw: item.usage_raw,
      received_at: now,
      retention_days: item.policy.retention_days
    })
  end

  # The side the SDK pre-hashed uses that value; the side that arrived raw uses the server's
  # computation (decision #3).
  defp hashes(%{input: input, output: output, prehashed: prehashed}) do
    %{
      input_sha256: (prehashed.input && prehashed.input.sha256) || sha256(input),
      output_sha256: (prehashed.output && prehashed.output.sha256) || sha256(output),
      bytes_in: (prehashed.input && prehashed.input.bytes) || json_size(input),
      bytes_out: (prehashed.output && prehashed.output.bytes) || json_size(output)
    }
  end

  defp sha256(nil), do: nil
  defp sha256(term), do: :crypto.hash(:sha256, Jason.encode!(term)) |> Base.encode16(case: :lower)

  defp json_size(nil), do: nil
  defp json_size(term), do: Truncation.json_size(term)

  defp flagged_truncated?(%{input: input, output: output}) do
    (is_map(input) and input["truncated"] == true) or
      (is_map(output) and output["truncated"] == true)
  end

  defp pop_variables(%{"variables" => variables} = input) when is_map(variables),
    do: {variables, Map.delete(input, "variables")}

  defp pop_variables(input), do: {nil, input}

  # ---------------------------------------------------------------------------
  # 5. Insert

  defp insert([], _actor, _tenant), do: {:ok, {0, [], 0}}

  defp insert(items, actor, tenant) do
    Repo.transaction(fn ->
      {accepted_items, insert_rejected, insert_dups} = insert_generations(items, actor, tenant)
      store_payloads(accepted_items, tenant)
      {length(accepted_items), insert_rejected, insert_dups}
    end)
  end

  # Generation batch → {accepted_items, rejected, duplicates}. The batch runs inside a SAVEPOINT.
  defp insert_generations(items, actor, tenant, retried? \\ false) do
    case bulk_generations(items, actor, tenant) do
      {:ok, failed} ->
        {accepted, rejected} = split_failed(items, failed)
        {accepted, rejected, 0}

      {:error, :unique_violation, _error} when not retried? ->
        # A concurrent same-id batch committed first: pull the stored ids out again and run the
        # rest as one more batch.
        retry_event(:unique_violation, tenant, length(items))
        {fresh, dups, conflicts} = split_existing(items, tenant)
        {accepted, rejected, more_dups} = insert_generations(fresh, actor, tenant, true)
        {accepted, conflicts ++ rejected, dups + more_dups}

      {:error, kind, error} ->
        Logger.warning(
          "prompton ingest: batch insert failed, isolating per record: #{Exception.message(error)}"
        )

        retry_event(kind, tenant, length(items))
        insert_individually(items, actor, tenant)
    end
  end

  defp retry_event(reason, tenant, count) do
    :telemetry.execute([:prompton, :ingest, :retry], %{count: 1, records: count}, %{
      reason: reason,
      tenant: tenant
    })
  end

  # One record at a time (each in its own SAVEPOINT) -- only the failed ones are isolated as
  # rejected/duplicate.
  defp insert_individually(items, actor, tenant) do
    Enum.reduce(items, {[], [], 0}, fn item, {accepted, rejected, dups} ->
      case insert_one(item, actor, tenant) do
        :accepted -> {[item | accepted], rejected, dups}
        :duplicate -> {accepted, rejected, dups + 1}
        {:rejected, rejected_item} -> {accepted, [rejected_item | rejected], dups}
      end
    end)
    |> then(fn {accepted, rejected, dups} ->
      {Enum.reverse(accepted), Enum.reverse(rejected), dups}
    end)
  end

  defp insert_one(item, actor, tenant) do
    case bulk_generations([item], actor, tenant) do
      {:ok, []} ->
        :accepted

      {:ok, [{0, message}]} ->
        {:rejected, reject_item(item, message)}

      {:error, :unique_violation, _error} ->
        case Map.get(existing_ids([item]), item.attrs.id) do
          ^tenant -> :duplicate
          _ -> {:rejected, reject_item(item, "id already exists in another project", "conflict")}
        end

      {:error, _kind, error} ->
        Logger.warning(
          "prompton ingest: record #{item.attrs.id} rejected by the database: #{Exception.message(error)}"
        )

        {:rejected, reject_item(item, "record could not be stored")}
    end
  end

  # `{:ok, [{position, message}]}` (failures with a known position = Ash validation) |
  # `{:error, :unique_violation | :other, error}`.
  defp bulk_generations([], _actor, _tenant), do: {:ok, []}

  defp bulk_generations(items, actor, tenant) do
    with_savepoint(fn ->
      items
      |> Enum.map(& &1.attrs)
      |> Ash.bulk_create(
        Generation,
        :ingest,
        @bulk_opts ++ [actor: actor, tenant: tenant, authorize?: true]
      )
      |> failed_positions()
    end)
  end

  defp split_failed(items, failed) do
    failed_positions = failed |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    rejected =
      Enum.map(failed, fn {position, message} ->
        reject_item(Enum.at(items, position), message)
      end)

    accepted =
      items
      |> Enum.with_index()
      |> Enum.reject(fn {_item, i} -> MapSet.member?(failed_positions, i) end)
      |> Enum.map(&elem(&1, 0))

    {accepted, rejected}
  end

  defp store_payloads(items, tenant) do
    payloads = items |> Enum.map(& &1.payload) |> Enum.reject(&is_nil/1)

    case bulk_payloads(payloads, tenant) do
      {:ok, []} ->
        :ok

      {:ok, failed} ->
        Logger.warning(
          "prompton ingest: #{length(failed)} payload(s) failed to store: #{inspect(failed)}"
        )

      {:error, _kind, error} ->
        Logger.warning(
          "prompton ingest: payload batch failed, isolating per record: #{Exception.message(error)}"
        )

        Enum.each(payloads, &store_payload_alone(&1, tenant))
    end

    :ok
  end

  defp store_payload_alone(payload, tenant) do
    case bulk_payloads([payload], tenant) do
      {:ok, []} ->
        :ok

      {:ok, failed} ->
        Logger.warning(
          "prompton ingest: payload #{payload.generation_id} not stored: #{inspect(failed)}"
        )

      {:error, _kind, error} ->
        Logger.warning(
          "prompton ingest: payload #{payload.generation_id} rejected by the database: #{Exception.message(error)}"
        )
    end
  end

  defp bulk_payloads([], _tenant), do: {:ok, []}

  defp bulk_payloads(payloads, tenant) do
    with_savepoint(fn ->
      payloads
      |> Ash.bulk_create(
        GenerationPayload,
        :store,
        @bulk_opts ++ [actor: PromptOn.SystemActor.new(), tenant: tenant, authorize?: true]
      )
      |> failed_positions()
    end)
  end

  # `fun` runs under a SAVEPOINT inside the transaction. On an error with no known position (a DB
  # error -- the failed statement leaves the transaction aborted), roll back to the SAVEPOINT to
  # keep the transaction alive and return `{:error, kind, error}`.
  defp with_savepoint(fun) do
    name = "prompton_ingest_" <> Integer.to_string(System.unique_integer([:positive]))
    Repo.query!("SAVEPOINT #{name}")

    result =
      try do
        fun.()
      catch
        # When the data layer returns `{:error, _}` inside a transaction, Ash **throws**
        # `Repo.rollback/1` (`Ash.Actions.Helpers.rollback_if_in_transaction/3`). Intercept here
        # and roll back only the SAVEPOINT before DBConnection catches it and fails the whole
        # transaction -- the throw itself has no side effects (`DBConnection.rollback/2`).
        :throw, {DBConnection, _conn_ref, reason} -> {:error, reason}
      end

    case result do
      {:ok, _failed} = ok ->
        Repo.query!("RELEASE SAVEPOINT #{name}")
        ok

      {:error, error} ->
        Repo.query!("ROLLBACK TO SAVEPOINT #{name}")
        {:error, error_kind(error), error}
    end
  end

  # bulk_create errors → {:ok, [{input position, message}]} | {:error, error}. Ash puts the
  # changeset's bulk_create index in error.path (validation failures). An error with no known
  # position is a failure of the batch statement itself (a DB error).
  defp failed_positions(%Ash.BulkResult{errors: errors}) when errors in [nil, []], do: {:ok, []}

  defp failed_positions(%Ash.BulkResult{errors: errors}) do
    Enum.reduce_while(errors, {:ok, []}, fn error, {:ok, acc} ->
      case position_of(error) do
        nil -> {:halt, {:error, error}}
        position -> {:cont, {:ok, [{position, error_message(error)} | acc]}}
      end
    end)
    |> case do
      {:ok, failed} -> {:ok, failed |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0))}
      error -> error
    end
  end

  defp position_of(%{errors: [_ | _] = inner}), do: Enum.find_value(inner, &position_of/1)
  defp position_of(%{path: [position | _]}) when is_integer(position), do: position
  defp position_of(_), do: nil

  # Only validation errors (field, message) go back to the client; everything else (DB/internal
  # error text) becomes a generic phrase (decision #8).
  defp error_message(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.flat_map(&field_messages/1)
    |> case do
      [] -> "record could not be stored"
      messages -> messages |> Enum.uniq() |> Enum.join("; ") |> String.slice(0, 500)
    end
  end

  defp field_messages(%{errors: [_ | _] = inner}), do: Enum.flat_map(inner, &field_messages/1)

  defp field_messages(%struct{field: field, message: message} = error)
       when struct in [
              Ash.Error.Changes.InvalidAttribute,
              Ash.Error.Changes.InvalidArgument,
              Ash.Error.Query.InvalidArgument
            ] and is_binary(message),
       do: ["#{field}: #{interpolate(message, Map.get(error, :vars, []))}"]

  defp field_messages(%Ash.Error.Changes.Required{field: field}), do: ["#{field}: is required"]

  defp field_messages(%Ash.Error.Changes.InvalidChanges{fields: fields, message: message} = error)
       when is_binary(message),
       do: [
         "#{Enum.join(List.wrap(fields), ",")}: #{interpolate(message, Map.get(error, :vars, []))}"
       ]

  defp field_messages(%Ash.Error.Forbidden.Policy{}), do: ["forbidden"]
  defp field_messages(_), do: []

  defp interpolate(message, vars) do
    Enum.reduce(List.wrap(vars), message, fn
      {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value))
      _, acc -> acc
    end)
  end

  # Detect a unique violation (the MERGE of a concurrent same-id batch) -- finds it in whatever
  # shape Ash wrapped the Postgrex error.
  defp error_kind(error), do: if(unique_violation?(error), do: :unique_violation, else: :other)

  defp unique_violation?(%{errors: [_ | _] = inner}), do: Enum.any?(inner, &unique_violation?/1)
  defp unique_violation?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true
  defp unique_violation?(%Ecto.ConstraintError{type: :unique}), do: true

  defp unique_violation?(%Ash.Error.Changes.InvalidAttribute{private_vars: vars})
       when is_list(vars),
       do: vars[:constraint_type] == :unique

  defp unique_violation?(%{error: inner}) when is_map(inner), do: unique_violation?(inner)
  defp unique_violation?(_), do: false
end
