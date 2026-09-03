defmodule PromptOnWeb.DSTest do
  @moduledoc """
  Design-system component smoke tests. Checks that the mockup values (color, tone, alignment)
  actually land in the markup, and that user content is escaped.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PromptOnWeb.DS
  alias PromptOnWeb.DSIcons

  doctest PromptOnWeb.DS, import: true

  describe "btn" do
    test "emits variant and size classes plus the icon" do
      html =
        render_component(&DS.btn/1,
          variant: "primary",
          size: "sm",
          icon: "plus",
          inner_block: inner("New")
        )

      assert html =~ "dsbtn-primary"
      assert html =~ "dsbtn-sm"
      assert html =~ "<svg"
      assert html =~ "New"
    end

    test "btn_link emits a link" do
      html =
        render_component(&DS.btn_link/1,
          variant: "outline",
          navigate: "/personal",
          inner_block: inner("Go")
        )

      assert html =~ ~s|href="/personal"|
      assert html =~ "dsbtn-outline"
    end
  end

  describe "badge" do
    test "uses the tone's exact rgba recipe (DESIGN-resend accent-green tint)" do
      html = render_component(&DS.badge/1, tone: :ok, inner_block: inner("ok"))

      assert html =~ "rgba(17,255,153,.08)"
      assert html =~ "var(--ok)"
    end
  end

  describe "provider_mark" do
    test "per-provider letter and tint" do
      html = render_component(&DS.provider_mark/1, provider: :anthropic)
      assert html =~ "#cc7a52"
      assert html =~ ">A<"

      html = render_component(&DS.provider_mark/1, provider: "openai")
      assert html =~ "#10a37f"
      assert html =~ ">O<"
    end

    test "an unknown provider falls back to openrouter" do
      html = render_component(&DS.provider_mark/1, provider: :nope)
      assert html =~ "#8b7cf6"
    end
  end

  describe "screen" do
    test "emits the title, subtitle and tabs (patch links)" do
      html =
        render_component(&DS.screen/1,
          title: "Use Cases",
          sub: "LLM call sites in the app",
          tabs: [
            %{id: "all", label: "All", count: 9, patch: "/personal/acme/use-cases?tab=all"},
            %{id: "chat", label: "Chat", patch: "/personal/acme/use-cases?tab=chat"}
          ],
          active_tab: "chat",
          inner_block: inner("body")
        )

      assert html =~ "Use Cases"
      assert html =~ "LLM call sites in the app"
      assert html =~ ~s|href="/personal/acme/use-cases?tab=all"|
      assert html =~ ~s|data-phx-link="patch"|
      assert html =~ "dstab tr is-active"
      assert html =~ "body"
    end
  end

  describe "table / row" do
    test "builds grid-template-columns from cols" do
      cols = [%{label: "key", w: "1.6fr"}, %{label: "calls", w: "64px", align: "right"}]

      html = render_component(&DS.table/1, cols: cols, inner_block: inner(""))
      assert html =~ "grid-template-columns:1.6fr 64px"
      assert html =~ "text-align:right"

      html =
        render_component(&DS.row/1,
          cols: cols,
          index: 1,
          navigate: "/personal/acme/use-cases/x",
          inner_block: inner("row")
        )

      assert html =~ "grid-template-columns:1.6fr 64px"
      assert html =~ "border-top:1px solid var(--line)"
      assert html =~ "dsrow-click"
      assert html =~ ~s|href="/personal/acme/use-cases/x"|
    end
  end

  describe "liquid" do
    test "wraps output/tag tokens in color and escapes the body" do
      html = render_component(&DS.liquid/1, text: ~s|{% if x %}<b>{{ name }}</b>{% endif %}|)

      assert html =~ "var(--link)"
      assert html =~ "rgba(139,124,246,.12)"
      assert html =~ "&lt;b&gt;"
      refute html =~ "<b>"
    end

    test "token split" do
      assert DS.liquid_tokens("a {{ b }} c {% d %}") == [
               {:text, "a "},
               {:output, "{{ b }}"},
               {:text, " c "},
               {:tag, "{% d %}"}
             ]
    end
  end

  describe "highlighted_editor" do
    test "the highlight layer and the textarea share the same metrics" do
      html =
        render_component(&DS.highlighted_editor/1,
          id: "sys",
          name: "prompt[system]",
          value: "Write in {{ language }}."
        )

      assert html =~ ~s|id="sys-highlight"|
      assert html =~ ~s|id="sys"|
      assert html =~ "var(--link)"
      assert html =~ "caret-color:var(--tx-0)"
      assert html =~ "-webkit-text-fill-color:transparent"
      assert html =~ "phx-hook=\"PromptOnWeb.DS.AutoGrowEditor\""

      # For the overlay to line up, both elements must use the same font, line height and
      # padding (spec code-md 13px / 1.6).
      assert html
             |> String.split("font-size:13px;line-height:1.6;padding:10px 12px")
             |> length() ==
               3
    end
  end

  describe "diff_view / line_diff" do
    test "emits add/del/eq with status-color tints" do
      html = render_component(&DS.diff_view/1, from: "a\nb\nc", to: "a\nB\nc")

      assert html =~ "rgba(17,255,153,.08)"
      assert html =~ "rgba(255,32,71,.08)"
    end

    test "LCS keeps the common lines" do
      assert DS.line_diff("a\nb\nc", "a\nx\nc") == [
               {:eq, "a"},
               {:del, "b"},
               {:add, "x"},
               {:eq, "c"}
             ]

      assert DS.line_diff("", "") == [eq: ""]
      assert DS.line_diff("a", "a\nb") == [eq: "a", add: "b"]
      assert DS.line_diff("a\nb", "a") == [eq: "a", del: "b"]
    end
  end

  describe "messages_view" do
    test "emits the role badge and the character count" do
      html =
        render_component(&DS.messages_view/1,
          messages: [%{role: :system, content: "hello"}, %{role: :user, content: "{{ x }}"}],
          highlight: true
        )

      assert html =~ "system"
      assert html =~ "rgba(139,124,246,.12)"
      assert html =~ "5 ch"
      assert html =~ "var(--accent-soft)"
    end
  end

  describe "sparkline" do
    test "turns a list of points into a polyline" do
      html = render_component(&DS.sparkline/1, data: [1, 5, 3], w: 100, h: 30)
      assert html =~ "<polyline"
      assert html =~ "<polygon"
    end

    test "draws nothing when there are too few points" do
      assert render_component(&DS.sparkline/1, data: [1]) == ""
      assert render_component(&DS.sparkline/1, data: []) == ""
    end
  end

  describe "drawer / modal" do
    test "closing is a patch" do
      html =
        render_component(&DS.drawer/1,
          on_close: "/personal/acme/releases",
          title: "release #12",
          inner_block: inner("body")
        )

      assert html =~ "&quot;patch&quot;"
      assert html =~ "&quot;href&quot;:&quot;/personal/acme/releases&quot;"
      assert html =~ "release #12"
    end
  end

  describe "formatters" do
    test "fmt_cost" do
      assert DS.fmt_cost(nil) == "—"
      assert DS.fmt_cost(0) == "$0"
      assert DS.fmt_cost(0.0006) == "$0.0006"
      assert DS.fmt_cost(2.415) == "$2.42"
      assert DS.fmt_cost(Decimal.new("0.0012")) == "$0.0012"
    end

    test "fmt_ms" do
      assert DS.fmt_ms(nil) == "—"
      assert DS.fmt_ms(240) == "240ms"
      assert DS.fmt_ms(6100) == "6.1s"
    end

    test "fmt_num" do
      assert DS.fmt_num(nil) == "—"
      assert DS.fmt_num(7) == "7"
      assert DS.fmt_num(1_284) == "1,284"
      assert DS.fmt_num(8_420_000) == "8,420,000"
      assert DS.fmt_num(-1234) == "-1,234"
    end
  end

  describe "icons" do
    test "all 64 icons from the mockup are present" do
      assert length(DSIcons.icon_names()) == 64
      assert "bolt" in DSIcons.icon_names()
      assert "chevUpDown" in DSIcons.icon_names()
    end

    test "filled icons turn stroke off" do
      html = render_component(&DSIcons.icon/1, name: "star", filled: true, size: 13)
      assert html =~ ~s|fill="currentColor"|
      assert html =~ ~s|stroke="none"|
      assert html =~ ~s|width="13"|
    end

    test "an unknown name is an empty icon" do
      html = render_component(&DSIcons.icon/1, name: "nope")
      assert html =~ "<svg"
    end
  end

  defp inner(text), do: [%{__slot__: :inner_block, inner_block: fn _, _ -> text end}]
end
