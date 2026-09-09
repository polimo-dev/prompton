defmodule PromptOnWeb.PromptEditorComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PromptOnWeb.PromptEditorComponents

  describe "message size estimates" do
    for {name, content, characters, tokens} <- [
          {"empty text", "", 0, 0},
          {"one character", "a", 1, 1},
          {"an exact byte boundary", "abcd", 4, 1},
          {"rounding up", "abcde", 5, 2},
          {"English", "Hello, world!", 13, 4},
          {"Korean", "안녕하세요", 5, 4},
          {"mixed languages", "Hi 안녕", 5, 3},
          {"emoji", "👩‍💻", 1, 3},
          {"combining marks", "e\u0301", 1, 1},
          {"whitespace", " \n\t ", 4, 1},
          {"template source", "{{ input }}", 11, 3},
          {"long content", String.duplicate("a", 100_001), 100_001, 25_001}
        ] do
      test "keeps character counts and estimates tokens for #{name}" do
        html =
          render_component(&PromptEditorComponents.message_card/1,
            index: 0,
            message: %{role: "system", content: unquote(content)},
            roles: ["system", "user", "assistant"],
            ai_patch: "/?ai=0"
          )
          |> LazyHTML.from_fragment()

        assert html |> LazyHTML.query("#message-0-stats-characters") |> LazyHTML.text() ==
                 "#{unquote(characters)} ch"

        assert html |> LazyHTML.query("#message-0-stats-tokens") |> LazyHTML.text() ==
                 "~#{unquote(tokens)} tokens"

        assert [_] =
                 html
                 |> LazyHTML.query(
                   "#message-0-stats-tokens[title*='UTF-8 bytes / 4'][title*='model and language'][title*='variable values']"
                 )
                 |> LazyHTML.to_tree()
      end
    end

    test "read-only previews show each message's own estimate" do
      html =
        render_component(&PromptEditorComponents.version_preview/1,
          number: 1,
          messages: [
            %{role: "system", content: "안녕하세요"},
            %{role: "user", content: ""}
          ],
          draft_patch: "/"
        )
        |> LazyHTML.from_fragment()

      assert html |> LazyHTML.query("#preview-message-0-stats-characters") |> LazyHTML.text() ==
               "5 ch"

      assert html |> LazyHTML.query("#preview-message-0-stats-tokens") |> LazyHTML.text() ==
               "~4 tokens"

      assert html |> LazyHTML.query("#preview-message-1-stats-tokens") |> LazyHTML.text() ==
               "~0 tokens"
    end
  end
end
