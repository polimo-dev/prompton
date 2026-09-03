defmodule PromptOn.Observability.Ingest.Truncation do
  @moduledoc """
  Applies the raw-content size caps (plan.md §5.7, §7.5; contract decision #4). Every cap is
  proportional to `PayloadPolicy.max_bytes`:

  | Target | Cap | Unit of measure |
  |---|---|---|
  | One message's `content` (string) | `max_bytes / 8` | **bytes of the content string** (`byte_size/1`) |
  | One message's `content` (non-string structure) | `max_bytes / 8` | JSON-encoded bytes |
  | Input total, the `messages` list | `max_bytes` | JSON-encoded bytes (`byte_size(Jason.encode!(messages))`) |
  | Input `text` (string) | `max_bytes` | string bytes |
  | Output `content` (string) | `max_bytes / 4` | string bytes |
  | Output `tool_calls` | `max_bytes / 4` | JSON-encoded bytes |
  | `variables` | `max_bytes` | JSON-encoded bytes |

  Rule: **a string value is measured by the bytes of that string**; a **structured value** such as a
  list or map **by its JSON-encoded bytes** (`json_size/1` = `byte_size(Jason.encode!(value))`).
  Strings keep their head and tail and are cut in the middle (an `…[truncated N bytes]…` marker,
  UTF-8 boundaries preserved), and the result is at or under the cap. When the `messages` total
  exceeds the cap, the first message (system) and the trailing messages are kept and the middle is
  replaced by one marker message
  (`{"role":"system","content":"…[N messages truncated]…","truncated":true}`) -- the budget is set
  so the JSON bytes of the final list, marker included, stay at or under the cap. A structured
  value over its cap is replaced wholesale by a placeholder: `variables` →
  `{"truncated": true, "bytes": n}`, `tool_calls` → `[]` + `"tool_calls_truncated_bytes": n`,
  non-string content → an `"…[truncated n bytes]…"` string. Any truncation sets `truncated? true`.
  Minimum caps: message/output never go below 64 bytes (`limits/1`).

  The SDK applies the same rules at enqueue time using the snapshot's `max_bytes` (§7.5) and the
  server ingest re-validates.
  """

  @marker_reserve 48

  @type limits :: %{message: pos_integer(), input: pos_integer(), output: pos_integer()}

  @doc "Policy `max_bytes` → the three caps."
  @spec limits(pos_integer()) :: limits()
  def limits(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    %{message: max(div(max_bytes, 8), 64), input: max_bytes, output: max(div(max_bytes, 4), 64)}
  end

  @doc """
  Applies the caps to the §6.4 `input`/`output` maps. Returns `{input, output, truncated?}` --
  `truncated?` is server truncation or the `input.truncated`/`output.truncated` flag sent by the
  SDK.
  """
  @spec apply(map() | nil, map() | nil, pos_integer()) :: {map() | nil, map() | nil, boolean()}
  def apply(input, output, max_bytes) do
    limits = limits(max_bytes)
    {input, in_truncated?} = truncate_input(input, limits)
    {output, out_truncated?} = truncate_output(output, limits)
    {input, output, in_truncated? or out_truncated?}
  end

  # ---------------------------------------------------------------------------
  # input

  defp truncate_input(nil, _limits), do: {nil, false}

  defp truncate_input(%{} = input, limits) do
    flagged? = input["truncated"] == true
    {input, t1} = input |> Map.delete("truncated") |> truncate_input_body(limits)
    {input, t2} = truncate_variables(input, limits)
    {input, flagged? or t1 or t2}
  end

  defp truncate_input(other, _limits), do: {other, false}

  defp truncate_input_body(%{"messages" => messages} = input, limits) when is_list(messages) do
    {messages, t} = truncate_messages(messages, limits)
    {Map.put(input, "messages", messages), t}
  end

  defp truncate_input_body(%{"text" => text} = input, limits) when is_binary(text) do
    {text, t} = middle_if_needed(text, limits.input)
    {Map.put(input, "text", text), t}
  end

  defp truncate_input_body(input, _limits), do: {input, false}

  defp truncate_variables(%{"variables" => vars} = input, limits) when is_map(vars) do
    case json_size(vars) do
      n when n > limits.input ->
        {Map.put(input, "variables", %{"truncated" => true, "bytes" => n}), true}

      _ ->
        {input, false}
    end
  end

  defp truncate_variables(input, _limits), do: {input, false}

  defp truncate_messages(messages, limits) do
    {messages, per_message?} =
      Enum.map_reduce(messages, false, fn
        %{"content" => content} = message, acc when is_binary(content) ->
          {content, t} = middle_if_needed(content, limits.message)
          {Map.put(message, "content", content), acc or t}

        %{"content" => content} = message, acc when not is_nil(content) ->
          case json_size(content) do
            n when n > limits.message ->
              {Map.put(message, "content", marker(n)), true}

            _ ->
              {message, acc}
          end

        message, acc ->
          {message, acc}
      end)

    if json_size(messages) > limits.input do
      {drop_middle_messages(messages, limits.input), true}
    else
      {messages, per_message?}
    end
  end

  # Keep the first message (usually system) and, from the back, as many as fit the budget; one
  # marker message goes in between. The budget is reserved up front using the marker message at
  # its largest (the wording when everything is dropped) so the final JSON never exceeds the cap.
  defp drop_middle_messages([first | rest], budget) do
    marker_message = %{
      "role" => "system",
      "content" => messages_marker(length(rest)),
      "truncated" => true
    }

    base = json_size([first, marker_message])

    {kept_tail, _} =
      rest
      |> Enum.reverse()
      |> Enum.reduce_while({[], base}, fn message, {kept, used} ->
        size = json_size(message) + 1

        if used + size <= budget,
          do: {:cont, {[message | kept], used + size}},
          else: {:halt, {kept, used}}
      end)

    dropped = length(rest) - length(kept_tail)
    marker_message = Map.put(marker_message, "content", messages_marker(dropped))
    [first, marker_message | kept_tail]
  end

  defp drop_middle_messages([], _budget), do: []

  defp messages_marker(count), do: "…[#{count} messages truncated]…"

  # ---------------------------------------------------------------------------
  # output

  defp truncate_output(nil, _limits), do: {nil, false}

  defp truncate_output(%{} = output, limits) do
    flagged? = output["truncated"] == true
    {output, t1} = output |> Map.delete("truncated") |> truncate_output_content(limits)
    {output, t2} = truncate_tool_calls(output, limits)
    {output, flagged? or t1 or t2}
  end

  defp truncate_output(other, _limits), do: {other, false}

  defp truncate_output_content(%{"content" => content} = output, limits)
       when is_binary(content) do
    {content, t} = middle_if_needed(content, limits.output)
    {Map.put(output, "content", content), t}
  end

  defp truncate_output_content(output, _limits), do: {output, false}

  defp truncate_tool_calls(%{"tool_calls" => [_ | _] = calls} = output, limits) do
    case json_size(calls) do
      n when n > limits.output ->
        {output |> Map.put("tool_calls", []) |> Map.put("tool_calls_truncated_bytes", n), true}

      _ ->
        {output, false}
    end
  end

  defp truncate_tool_calls(output, _limits), do: {output, false}

  # ---------------------------------------------------------------------------
  # String truncation (UTF-8 safe)

  @doc "Keeps only the first `max_bytes` bytes (UTF-8 boundary preserved)."
  @spec head(binary(), non_neg_integer()) :: binary()
  def head(string, max_bytes) when byte_size(string) <= max_bytes, do: string

  def head(string, max_bytes) do
    string |> binary_part(0, max_bytes) |> drop_trailing_partial()
  end

  @doc "Keeps only the last `max_bytes` bytes (UTF-8 boundary preserved)."
  @spec tail(binary(), non_neg_integer()) :: binary()
  def tail(string, max_bytes) when byte_size(string) <= max_bytes, do: string

  def tail(string, max_bytes) do
    string
    |> binary_part(byte_size(string) - max_bytes, max_bytes)
    |> drop_leading_continuation()
  end

  @doc """
  Over `max_bytes`, keeps the head and tail and replaces the middle with `…[truncated N bytes]…`.
  The result is at most `max_bytes`.
  """
  @spec middle(binary(), pos_integer()) :: binary()
  def middle(string, max_bytes) when byte_size(string) <= max_bytes, do: string

  def middle(string, max_bytes) when max_bytes <= @marker_reserve + 16,
    do: head(string, max_bytes)

  def middle(string, max_bytes) do
    keep = max_bytes - @marker_reserve
    head_len = div(keep, 2)
    head = head(string, head_len)
    tail = tail(string, keep - head_len)
    removed = byte_size(string) - byte_size(head) - byte_size(tail)
    head <> marker(removed) <> tail
  end

  defp middle_if_needed(string, max_bytes) do
    if byte_size(string) > max_bytes, do: {middle(string, max_bytes), true}, else: {string, false}
  end

  defp marker(bytes), do: "…[truncated #{bytes} bytes]…"

  defp drop_trailing_partial(bin) do
    if String.valid?(bin) do
      bin
    else
      case bin do
        "" -> ""
        _ -> bin |> binary_part(0, byte_size(bin) - 1) |> drop_trailing_partial()
      end
    end
  end

  defp drop_leading_continuation(<<b, rest::binary>>) when b >= 0x80 and b < 0xC0,
    do: drop_leading_continuation(rest)

  defp drop_leading_continuation(bin), do: bin

  @doc "JSON-encoded byte count (the `inspect` size when it cannot be encoded)."
  @spec json_size(term()) :: non_neg_integer()
  def json_size(term) do
    case Jason.encode(term) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> byte_size(inspect(term))
    end
  end
end
