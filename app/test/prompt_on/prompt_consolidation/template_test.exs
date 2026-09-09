defmodule PromptOn.PromptConsolidation.TemplateTest do
  use ExUnit.Case, async: true

  alias PromptOn.PromptConsolidation.Template, as: Merge
  alias PromptOnSDK.Template

  test "language branches preserve exact content and default when the selector is absent" do
    variants = %{
      "default" => version("안녕 {{ name }}\n"),
      "en" => version("Hello {{ name }}\n")
    }

    merged = Merge.merge!(variants, Merge.strategy(Map.keys(variants)))

    for {name, selector} <- [
          {"default", %{}},
          {"default", %{"language" => "ko"}},
          {"en", %{"language" => "en"}}
        ] do
      vars = Map.put(selector, "name", "Ada")
      assert render(merged, vars) == render(variants[name], vars)
    end
  end

  test "mode and language are independent and common message slots are not duplicated" do
    variants = %{
      "default" => version("한국어", "fresh {{ text }}"),
      "fresh_en" => version("English", "fresh {{ text }}"),
      "incremental_ko" => version("한국어", "update {{ previous }}"),
      "incremental_en" => version("English", "update {{ previous }}"),
      "with_user_content_ko" => version("한국어", "edit {{ user_content }}"),
      "with_user_content_en" => version("English", "edit {{ user_content }}")
    }

    strategy = Merge.strategy(Map.keys(variants))
    merged = Merge.merge!(variants, strategy)

    for {name, selectors} <- Merge.selections(strategy) do
      vars =
        Map.merge(selectors, %{"text" => "new", "previous" => "old", "user_content" => "mine"})

      assert render(merged, vars) == render(variants[name], vars)
    end

    assert render(merged, %{"language" => "en", "text" => "new"}) ==
             render(variants["fresh_en"], %{"text" => "new"})

    [system, user] = merged.messages
    refute system.content =~ "mode"
    refute user.content =~ "language"
    assert {:ok, _} = render(merged, %{"mode" => "incremental", "previous" => "old"})
  end

  test "tone uses a variable, raw template markers remain literal" do
    variants = %{
      "default" => %{version("literal {{ name }} {% if x %}") | engine: :raw},
      "harsh" => version("Direct {{ name }}")
    }

    merged = Merge.merge!(variants, Merge.strategy(Map.keys(variants)))
    assert render(merged, %{}) == render(variants["default"], %{})

    assert render(merged, %{"tone" => "harsh", "name" => "Ada"}) ==
             render(variants["harsh"], %{"name" => "Ada"})
  end

  test "different message shapes are refused instead of padded or merged across roles" do
    variants = %{"default" => version("system"), "en" => version("system", "user")}

    assert_raise ArgumentError, ~r/message shape/, fn ->
      Merge.merge!(variants, Merge.strategy(Map.keys(variants)))
    end
  end

  test "a named empathetic tone stays distinct from the original default" do
    variants = %{
      "default" => version("Original"),
      "empathetic" => version("Gentle"),
      "harsh" => version("Direct")
    }

    strategy = Merge.strategy(Map.keys(variants))
    merged = Merge.merge!(variants, strategy)

    for {name, variables} <- Merge.selections(strategy) do
      assert render(merged, variables) == render(variants[name], variables)
    end
  end

  defp version(system, user \\ nil) do
    messages = [%{role: "system", content: system, name: nil}]

    messages =
      if user, do: messages ++ [%{role: "user", content: user, name: nil}], else: messages

    %{engine: :liquid, messages: messages}
  end

  defp render(version, vars),
    do: Template.render_messages(version.messages, vars, engine: version.engine)
end
