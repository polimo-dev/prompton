defmodule PromptOn.HeyDiaryImport.Dump do
  @moduledoc """
  A normalized struct for the HeyDiary `ai_tasks` / `ai_models` / `plan_ai_models` dump (JSON,
  `priv/heydiary/DUMP.md`), plus helpers that reproduce the **lookup semantics** of the HeyDiary
  resolver (`HeyDiary.AI.Tasks`) as pure functions (plan.md §12.2 steps 1 and 9).

  - `task/3` — `get_task`: the language-specific row first, else the NULL-language (common) row
    (`ORDER BY language NULLS LAST LIMIT 1`).
  - `plan_models/2` — `plan_models`: every row of the task, sorted by `sort_order, created_at, id`.
  - `available_plan_models/3` — `plan_level(p.plan) <= plan_level(user_plan)` (unknown plan =
    free).
  - `default_plan_model/4` — `plan_default_model`. The original HeyDiary SQL is
    `is_default = true LIMIT 1` with no ORDER BY, and the `Registry` loads rows in
    `created_at, id` order and picks the first `is_default` row. Here the strategy is an argument:
    `:highest_plan` (among the applicable default rows, the one with the highest plan — the same
    intent as the PromptOn rule "higher plans first") or `:insertion_order` (identical to the
    Registry). When the two differ, the Planner emits an `{:ambiguous_default, …}` warning.
  - `plan_model_by_id/2` — `plan_model_by_id`: lookup by id regardless of task or plan.

  Dump rows use the HeyDiary column names (string keys) as is; `language` NULL = common,
  `providers` is an array or null, and `temperature` may be null. Parsed results are atom-keyed
  maps.
  """

  @plan_level %{"free" => 0, "pro" => 1, "max" => 2}
  @plans ~w(free pro max)

  defstruct ai_tasks: [], ai_models: [], plan_ai_models: []

  @type task :: %{
          id: String.t() | nil,
          task_name: String.t(),
          language: String.t() | nil,
          system_prompt: String.t(),
          temperature: float() | nil,
          created_at: String.t() | nil
        }

  @type model :: %{
          id: String.t(),
          model: String.t(),
          display_name: String.t(),
          description_key: String.t() | nil,
          providers: [String.t()] | nil,
          created_at: String.t() | nil
        }

  @type plan_model :: %{
          id: String.t(),
          plan: String.t(),
          task_name: String.t(),
          ai_model_id: String.t(),
          allow_fallbacks: boolean(),
          temperature: float() | nil,
          is_default: boolean(),
          sort_order: integer(),
          created_at: String.t() | nil,
          model: String.t(),
          display_name: String.t(),
          description_key: String.t() | nil,
          providers: [String.t()] | nil
        }

  @type t :: %__MODULE__{ai_tasks: [task()], ai_models: [model()], plan_ai_models: [plan_model()]}

  @doc "The HeyDiary plan hierarchy (lowest to highest)."
  @spec plans() :: [String.t()]
  def plans, do: @plans

  @doc "Mirror of the `plan_level()` SQL function: free=0, pro=1, max=2, anything else 0."
  @spec plan_level(String.t() | nil) :: non_neg_integer()
  def plan_level(plan), do: Map.get(@plan_level, plan, 0)

  @doc "Reads a JSON file and runs `parse/1` on it."
  @spec load_file(Path.t()) :: {:ok, t()} | {:error, term()}
  def load_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body) do
      parse(map)
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:invalid_dump, Exception.message(e)}}
      {:error, reason} -> {:error, {:file, path, reason}}
    end
  end

  @doc """
  Validates and normalizes a dump map (`%{"ai_tasks" => [...], "ai_models" => [...],
  "plan_ai_models" => [...]}`; atom keys are accepted too). Returns
  `{:error, {:unknown_model, id}}` when a `plan_ai_models.ai_model_id` is not in `ai_models`.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%__MODULE__{} = dump), do: {:ok, dump}

  def parse(map) when is_map(map) do
    map = stringify(map)

    with {:ok, tasks} <- rows(map, "ai_tasks", &parse_task/1),
         {:ok, models} <- rows(map, "ai_models", &parse_model/1),
         {:ok, plan_models} <- rows(map, "plan_ai_models", &parse_plan_model/1),
         :ok <- check_task_uniqueness(tasks),
         {:ok, plan_models} <- join_models(plan_models, models) do
      {:ok,
       %__MODULE__{
         ai_tasks: Enum.sort_by(tasks, &{&1.task_name, &1.language || "", &1.created_at || ""}),
         ai_models: Enum.sort_by(models, & &1.model),
         plan_ai_models: Enum.sort_by(plan_models, &{&1.created_at || "", &1.id})
       }}
    end
  end

  def parse(_), do: {:error, {:invalid_dump, "dump must be a JSON object"}}

  # ---------------------------------------------------------------------------
  # HeyDiary lookup semantics

  @doc "The task names present in the dump (sorted)."
  @spec task_names(t()) :: [String.t()]
  def task_names(%__MODULE__{ai_tasks: tasks}),
    do: tasks |> Enum.map(& &1.task_name) |> Enum.uniq() |> Enum.sort()

  @doc "Every `ai_tasks` row of the task (rows with a language sorted first, NULL last)."
  @spec task_rows(t(), String.t()) :: [task()]
  def task_rows(%__MODULE__{ai_tasks: tasks}, task_name) do
    tasks
    |> Enum.filter(&(&1.task_name == task_name))
    |> Enum.sort_by(&{is_nil(&1.language), &1.language || ""})
  end

  @doc "The task's languages (NULL is `nil`, and comes last)."
  @spec languages(t(), String.t()) :: [String.t() | nil]
  def languages(dump, task_name), do: dump |> task_rows(task_name) |> Enum.map(& &1.language)

  @doc """
  `Tasks.get_task/2`: the language-specific row when there is one, else the NULL row, else `nil`.
  A `language` of `nil`/`""` never matches a language-specific row (HeyDiary matches only the NULL
  row when called with `""`).
  """
  @spec task(t(), String.t(), String.t() | nil) :: task() | nil
  def task(%__MODULE__{ai_tasks: tasks}, task_name, language) do
    rows = Enum.filter(tasks, &(&1.task_name == task_name))

    (is_binary(language) and language != "" and Enum.find(rows, &(&1.language == language))) ||
      Enum.find(rows, &is_nil(&1.language))
  end

  @doc "The `ai_models` row (by id)."
  @spec model(t(), String.t()) :: model() | nil
  def model(%__MODULE__{ai_models: models}, id), do: Enum.find(models, &(&1.id == id))

  @doc """
  Every row of the task in `Tasks.plan_models/2` order (`sort_order, created_at, id`), with no plan
  filter.
  """
  @spec plan_models(t(), String.t()) :: [plan_model()]
  def plan_models(%__MODULE__{plan_ai_models: rows}, task_name) do
    rows
    |> Enum.filter(&(&1.task_name == task_name))
    |> Enum.sort_by(&{&1.sort_order, &1.created_at || "", &1.id})
  end

  @doc "Rows with `plan_level(p.plan) <= plan_level(plan)` (same ordering as `plan_models/2`)."
  @spec available_plan_models(t(), String.t(), String.t()) :: [plan_model()]
  def available_plan_models(dump, plan, task_name) do
    level = plan_level(plan)
    dump |> plan_models(task_name) |> Enum.filter(&(plan_level(&1.plan) <= level))
  end

  @doc """
  `Tasks.plan_default_model/2`. `strategy`: `:highest_plan` (default) | `:insertion_order`
  (Registry: `created_at, id`).
  """
  @spec default_plan_model(t(), String.t(), String.t(), :highest_plan | :insertion_order) ::
          plan_model() | nil
  def default_plan_model(dump, plan, task_name, strategy \\ :highest_plan) do
    defaults =
      dump
      |> available_plan_models(plan, task_name)
      |> Enum.filter(& &1.is_default)

    case strategy do
      :insertion_order ->
        defaults |> Enum.sort_by(&{&1.created_at || "", &1.id}) |> List.first()

      :highest_plan ->
        defaults
        |> Enum.sort_by(&{-plan_level(&1.plan), &1.created_at || "", &1.id})
        |> List.first()
    end
  end

  @doc "`Tasks.plan_model_by_id/1` (regardless of task or plan)."
  @spec plan_model_by_id(t(), String.t()) :: plan_model() | nil
  def plan_model_by_id(%__MODULE__{plan_ai_models: rows}, id), do: Enum.find(rows, &(&1.id == id))

  # ---------------------------------------------------------------------------
  # parsing

  defp rows(map, key, parser) do
    case Map.get(map, key, []) do
      list when is_list(list) ->
        list
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
          case parser.(stringify(row)) do
            {:ok, parsed} ->
              {:cont, {:ok, [parsed | acc]}}

            {:error, message} ->
              {:halt, {:error, {:invalid_dump, "#{key}[#{index}]: #{message}"}}}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          error -> error
        end

      _ ->
        {:error, {:invalid_dump, "#{key} must be an array"}}
    end
  end

  defp parse_task(row) do
    with {:ok, task_name} <- required_string(row, "task_name"),
         {:ok, system_prompt} <- required_string(row, "system_prompt"),
         {:ok, language} <- optional_string(row, "language"),
         {:ok, temperature} <- optional_number(row, "temperature") do
      {:ok,
       %{
         id: optional_id(row, "id"),
         task_name: task_name,
         language: language,
         system_prompt: system_prompt,
         temperature: temperature,
         created_at: Map.get(row, "created_at")
       }}
    end
  end

  defp parse_model(row) do
    with {:ok, id} <- required_string(row, "id"),
         {:ok, model} <- required_string(row, "model"),
         {:ok, display_name} <- required_string(row, "display_name"),
         {:ok, description_key} <- optional_string(row, "description_key"),
         {:ok, providers} <- providers(Map.get(row, "providers")) do
      {:ok,
       %{
         id: id,
         model: model,
         display_name: display_name,
         description_key: description_key,
         providers: providers,
         created_at: Map.get(row, "created_at")
       }}
    end
  end

  defp parse_plan_model(row) do
    with {:ok, id} <- required_string(row, "id"),
         {:ok, plan} <- required_string(row, "plan"),
         {:ok, task_name} <- required_string(row, "task_name"),
         {:ok, ai_model_id} <- required_string(row, "ai_model_id"),
         {:ok, temperature} <- optional_number(row, "temperature"),
         {:ok, allow_fallbacks} <- optional_boolean(row, "allow_fallbacks", false),
         {:ok, is_default} <- optional_boolean(row, "is_default", false),
         {:ok, sort_order} <- optional_integer(row, "sort_order", 0) do
      {:ok,
       %{
         id: id,
         plan: plan,
         task_name: task_name,
         ai_model_id: ai_model_id,
         allow_fallbacks: allow_fallbacks,
         temperature: temperature,
         is_default: is_default,
         sort_order: sort_order,
         created_at: Map.get(row, "created_at")
       }}
    end
  end

  defp join_models(plan_models, models) do
    by_id = Map.new(models, &{&1.id, &1})

    Enum.reduce_while(plan_models, {:ok, []}, fn pm, {:ok, acc} ->
      case Map.fetch(by_id, pm.ai_model_id) do
        {:ok, model} ->
          joined =
            Map.merge(pm, %{
              model: model.model,
              display_name: model.display_name,
              description_key: model.description_key,
              providers: model.providers
            })

          {:cont, {:ok, [joined | acc]}}

        :error ->
          {:halt, {:error, {:unknown_model, pm.ai_model_id}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # HeyDiary UNIQUE(task_name, language) — NULLs are not distinct from each other, but there must
  # be exactly one common row per task.
  defp check_task_uniqueness(tasks) do
    duplicates =
      tasks
      |> Enum.frequencies_by(&{&1.task_name, &1.language})
      |> Enum.filter(fn {_key, n} -> n > 1 end)
      |> Enum.map(fn {{task, lang}, _} -> "#{task}/#{lang || "NULL"}" end)

    if duplicates == [],
      do: :ok,
      else: {:error, {:invalid_dump, "duplicate ai_tasks rows: " <> Enum.join(duplicates, ", ")}}
  end

  defp required_string(row, key) do
    case Map.get(row, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp optional_string(row, key) do
    case Map.get(row, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "#{key} must be a string or null"}
    end
  end

  defp optional_id(row, key) do
    case Map.get(row, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp optional_number(row, key) do
    case Map.get(row, key) do
      nil -> {:ok, nil}
      value when is_float(value) -> {:ok, value}
      value when is_integer(value) -> {:ok, value / 1}
      _ -> {:error, "#{key} must be a number or null"}
    end
  end

  defp optional_boolean(row, key, default) do
    case Map.get(row, key) do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "#{key} must be a boolean"}
    end
  end

  defp optional_integer(row, key, default) do
    case Map.get(row, key) do
      nil -> {:ok, default}
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, "#{key} must be an integer"}
    end
  end

  # The jsonb top level is an array (a list of provider names) or null. An empty array stays empty.
  defp providers(nil), do: {:ok, nil}

  defp providers(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: {:ok, list},
      else: {:error, "providers must be an array of strings"}
  end

  defp providers(_), do: {:error, "providers must be an array or null"}

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
