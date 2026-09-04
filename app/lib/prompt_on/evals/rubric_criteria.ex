defmodule PromptOn.Evals.RubricCriteria do
  @moduledoc """
  The body of a `PromptOn.Evals.Rubric`, embedded (ADR 0010 §2.3).

  It is **flat on purpose**: `level_1` .. `level_5` rather than a map keyed `"1".."5"`, because a
  map is miserable in a Phoenix form and in a diff.

  - `summary` — what a good answer is, in one to three sentences.
  - `must_never` — things that force a score of 1 or 2 no matter how good the rest is.
  - `level_1` .. `level_5` — one or two concrete sentences each; 5 is the best.

  `from_json/1` is the parser for a judge answer, `to_json/1` the shape the revise prompt echoes
  back, and `to_prompt/1` the plain-text block the scoring prompt embeds.
  """

  use Ash.Resource, data_layer: :embedded

  @raw_string [allow_empty?: true, trim?: false]

  # The rubric body is embedded into the user message of **every** judge call, so a pasted megabyte
  # would be multiplied by a run's 1,000 items on the organization's own key. These are the caps.
  @summary_max 2_000
  @level_max 1_000
  @must_never_items 20
  @must_never_item_max 300

  @level_constraints @raw_string ++ [max_length: @level_max]

  @levels [:level_1, :level_2, :level_3, :level_4, :level_5]

  attributes do
    attribute :summary, :string do
      description "What a good answer is, one to three sentences."
      allow_nil? false
      public? true
      constraints @raw_string ++ [max_length: @summary_max]
    end

    attribute :must_never, {:array, :string} do
      description "Things that force a score of 1 or 2. May be empty."
      allow_nil? false
      public? true
      default []
      constraints max_length: @must_never_items, items: [max_length: @must_never_item_max]
    end

    attribute :level_1, :string, allow_nil?: false, public?: true, constraints: @level_constraints
    attribute :level_2, :string, allow_nil?: false, public?: true, constraints: @level_constraints
    attribute :level_3, :string, allow_nil?: false, public?: true, constraints: @level_constraints
    attribute :level_4, :string, allow_nil?: false, public?: true, constraints: @level_constraints
    attribute :level_5, :string, allow_nil?: false, public?: true, constraints: @level_constraints
  end

  @doc "The five level attribute names, 1 to 5."
  @spec levels() :: [atom()]
  def levels, do: @levels

  @doc """
  Parses the judge's JSON shape
  `%{"summary" => _, "must_never" => [_], "levels" => %{"1" => _, ... "5" => _}}`.

  Rejects a blank summary, a missing or blank level, and a `must_never` that is not a list of
  strings.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, :invalid_shape}
  def from_json(%{} = json) do
    with {:ok, summary} <- text(Map.get(json, "summary")),
         {:ok, must_never} <- must_never(Map.get(json, "must_never")),
         {:ok, levels} <- levels(Map.get(json, "levels")) do
      {:ok, struct(__MODULE__, [summary: summary, must_never: must_never] ++ levels)}
    end
  end

  def from_json(_json), do: {:error, :invalid_shape}

  @doc "The same JSON shape, for the revise prompt and for round-tripping."
  @spec to_json(t() | map()) :: map()
  def to_json(criteria) do
    %{
      "summary" => Map.get(criteria, :summary) || "",
      "must_never" => Map.get(criteria, :must_never) || [],
      "levels" =>
        @levels
        |> Enum.with_index(1)
        |> Map.new(fn {field, n} -> {Integer.to_string(n), Map.get(criteria, field) || ""} end)
    }
  end

  @doc """
  The plain-text rubric block the scoring prompt embeds. The `must never` section is omitted
  entirely when the list is empty — an empty bullet list invites the model to invent one.

  Every field is truncated to its attribute's cap a second time here: the attribute constraints stop
  an oversized rubric being written, and this stops one that was written before the caps existed
  from being multiplied across a whole run.
  """
  @spec to_prompt(t() | map()) :: String.t()
  def to_prompt(criteria) do
    [
      "summary: " <> cap(Map.get(criteria, :summary), @summary_max),
      must_never_block(Map.get(criteria, :must_never) || []),
      levels_block(criteria)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp must_never_block([]), do: ""

  defp must_never_block(items) do
    "must never:\n" <>
      (items
       |> Enum.take(@must_never_items)
       |> Enum.map_join("\n", &("- " <> cap(&1, @must_never_item_max))))
  end

  defp levels_block(criteria) do
    @levels
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {field, n} ->
      "#{n} = #{cap(Map.get(criteria, field), @level_max)}"
    end)
  end

  defp cap(nil, _max), do: ""
  defp cap(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp cap(value, max), do: value |> to_string() |> String.slice(0, max)

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_shape}
      _trimmed -> {:ok, value}
    end
  end

  defp text(_value), do: {:error, :invalid_shape}

  defp must_never(nil), do: {:ok, []}

  defp must_never(items) when is_list(items) do
    if Enum.all?(items, &is_binary/1), do: {:ok, items}, else: {:error, :invalid_shape}
  end

  defp must_never(_items), do: {:error, :invalid_shape}

  defp levels(%{} = levels) do
    @levels
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {field, n}, {:ok, acc} ->
      case text(Map.get(levels, Integer.to_string(n))) do
        {:ok, value} -> {:cont, {:ok, [{field, value} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp levels(_levels), do: {:error, :invalid_shape}
end
