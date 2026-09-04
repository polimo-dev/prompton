defmodule PromptOn.Evals.PayloadTextTest do
  use ExUnit.Case, async: true

  alias PromptOn.Evals.PayloadText

  doctest PromptOn.Evals.PayloadText

  describe "input_text/1" do
    test "flattens a chat input into role: content lines" do
      input = %{
        "messages" => [
          %{"role" => "system", "content" => "You are helpful."},
          %{"role" => "user", "content" => "hello"}
        ]
      }

      assert PayloadText.input_text(input) == "system: You are helpful.\n\nuser: hello"
    end

    test "takes a text input as it is" do
      assert PayloadText.input_text(%{"text" => "diary, day, mood"}) == "diary, day, mood"
    end

    test "JSON-encodes a non-string message content" do
      input = %{"messages" => [%{"role" => "user", "content" => [%{"type" => "image"}]}]}

      assert PayloadText.input_text(input) == ~s|user: [{"type":"image"}]|
    end

    test "cuts each message to the per-message budget" do
      long = String.duplicate("a", PayloadText.max_message_chars() + 500)
      text = PayloadText.input_text(%{"messages" => [%{"role" => "user", "content" => long}]})

      assert text =~ "truncated 500 chars"
      assert String.length(text) < String.length(long)
    end

    test "an empty or unknown input is an empty string" do
      assert PayloadText.input_text(%{}) == ""
      assert PayloadText.input_text(nil) == ""
    end
  end

  describe "output_text/1" do
    test "content only" do
      assert PayloadText.output_text(%{"content" => "Hi there!"}) == "Hi there!"
    end

    test "tool calls only" do
      output = %{"content" => nil, "tool_calls" => [%{"name" => "search"}]}

      assert PayloadText.output_text(output) == ~s|tool_calls: [{"name":"search"}]|
    end

    test "content and tool calls together" do
      output = %{"content" => "looking it up", "tool_calls" => [%{"name" => "search"}]}

      assert PayloadText.output_text(output) ==
               ~s|looking it up\n\ntool_calls: [{"name":"search"}]|
    end

    test "an empty tool_calls list is not rendered" do
      assert PayloadText.output_text(%{"content" => "Hi", "tool_calls" => []}) == "Hi"
    end
  end

  describe "truncate/2" do
    test "leaves short text alone" do
      assert PayloadText.truncate("short", 100) == {"short", false}
    end

    test "keeps the head and the tail with a marker between them" do
      text = String.duplicate("x", 60) <> String.duplicate("y", 60)
      {cut, truncated?} = PayloadText.truncate(text, 100)

      assert truncated?
      assert cut =~ "...[truncated 20 chars]..."
      assert String.starts_with?(cut, String.duplicate("x", 50))
      assert String.ends_with?(cut, String.duplicate("y", 50))
    end

    test "never splits a UTF-8 codepoint" do
      text = String.duplicate("e\u0301éñ", 300)
      {cut, true} = PayloadText.truncate(text, 100)

      assert String.valid?(cut)
      assert cut =~ "é"
    end
  end

  describe "extract/1" do
    test "returns both sides and whether either was cut" do
      payload = %{
        input: %{"messages" => [%{"role" => "user", "content" => "hi"}]},
        output: %{"content" => "hello"}
      }

      assert PayloadText.extract(payload) == {"user: hi", "hello", false}
    end

    test "flags truncation when a side is over budget" do
      long = String.duplicate("z", PayloadText.max_chars() + 10)
      payload = %{input: %{"text" => long}, output: %{"content" => "ok"}}

      assert {_input, "ok", true} = PayloadText.extract(payload)
    end

    test "a missing payload is two empty strings" do
      assert PayloadText.extract(nil) == {"", "", false}
    end
  end
end
