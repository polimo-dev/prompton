defmodule PromptOn.Evals.PayloadText do
  @moduledoc """
  The single choke point where a stored raw payload (`PromptOn.Observability.GenerationPayload`)
  becomes plain text for a judge prompt (ADR 0010 §2.2).

  - `input`: `%{"messages" => [%{"role" => r, "content" => c}, ...]}` becomes `"r: c"` lines joined
    by a blank line, each `c` cut to `@max_message_chars`; `%{"text" => t}` becomes `t`; a
    non-string `content` is JSON-encoded.
  - `output`: `%{"content" => c}` becomes `c`; `%{"tool_calls" => calls}` becomes the JSON of the
    calls; when both are present the JSON follows the content after a `tool_calls:` line.
  - Each side is then cut to `@max_chars` **head + tail with a marker in the middle**. This is a
    plain character cut for a prompt; it deliberately does not reuse
    `PromptOn.Observability.Ingest.Truncation`, which measures bytes against a storage policy
    budget.

  **This module must never call `Logger`.** It is the one place that holds decrypted user content
  in memory, and everything downstream (`PromptOn.Evals.Judge`,
  `PromptOn.Evals.EvaluationResult.Changes.RunJudge`, `PromptOn.Evals.Calibration`) inherits the
  same rule.
  """

  @max_chars 4_000
  @max_message_chars 1_000

  @typedoc "`{input_text, output_text, truncated?}`."
  @type extracted :: {String.t(), String.t(), boolean()}

  @doc "Characters kept per side before truncation."
  @spec max_chars() :: pos_integer()
  def max_chars, do: @max_chars

  @doc "Characters kept per chat message while flattening an input."
  @spec max_message_chars() :: pos_integer()
  def max_message_chars, do: @max_message_chars

  @doc """
  Flattens one payload into `{input_text, output_text, truncated?}`. The payload must have been
  read with `load: [:input, :output]`; an unloaded or missing side becomes an empty string.
  """
  @spec extract(map() | nil) :: extracted()
  def extract(nil), do: {"", "", false}

  def extract(payload) do
    {input, input_cut?} = payload |> Map.get(:input) |> input_text() |> truncate(@max_chars)
    {output, output_cut?} = payload |> Map.get(:output) |> output_text() |> truncate(@max_chars)

    {input, output, input_cut? or output_cut?}
  end

  @doc "The input side of a payload as plain text."
  @spec input_text(term()) :: String.t()
  def input_text(%{"messages" => messages}) when is_list(messages) do
    Enum.map_join(messages, "\n\n", &message_line/1)
  end

  def input_text(%{"text" => text}), do: stringify(text)
  def input_text(%{} = input) when map_size(input) > 0, do: encode(input)
  def input_text(_input), do: ""

  @doc "The output side of a payload as plain text."
  @spec output_text(term()) :: String.t()
  def output_text(%{} = output) do
    content = output |> Map.get("content") |> stringify()
    calls = Map.get(output, "tool_calls")

    case {content, blank_calls?(calls)} do
      {"", true} -> ""
      {content, true} -> content
      {"", false} -> "tool_calls: " <> encode(calls)
      {content, false} -> content <> "\n\ntool_calls: " <> encode(calls)
    end
  end

  def output_text(_output), do: ""

  @doc """
  Cuts `text` to `max` characters, keeping the head and the tail with a marker in between. Returns
  `{text, truncated?}`. The cut is by grapheme, so it never splits a UTF-8 codepoint.
  """
  @spec truncate(String.t(), pos_integer()) :: {String.t(), boolean()}
  def truncate(text, max) when is_binary(text) do
    length = String.length(text)

    if length <= max do
      {text, false}
    else
      head = div(max, 2)
      tail = max - head
      marker = "\n\n...[truncated #{length - max} chars]...\n\n"

      {String.slice(text, 0, head) <> marker <> String.slice(text, length - tail, tail), true}
    end
  end

  defp message_line(%{"role" => role, "content" => content}) do
    {text, _cut?} = content |> stringify() |> truncate(@max_message_chars)
    "#{role}: #{text}"
  end

  defp message_line(%{"content" => content}),
    do: message_line(%{"role" => "user", "content" => content})

  defp message_line(other), do: encode(other)

  defp blank_calls?(nil), do: true
  defp blank_calls?([]), do: true
  defp blank_calls?(calls) when is_list(calls) or is_map(calls), do: false
  defp blank_calls?(_calls), do: true

  defp stringify(nil), do: ""
  defp stringify(text) when is_binary(text), do: text
  defp stringify(other), do: encode(other)

  defp encode(term) do
    case Jason.encode(term) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(term)
    end
  end
end
