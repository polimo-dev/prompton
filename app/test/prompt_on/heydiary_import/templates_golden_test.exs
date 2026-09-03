defmodule PromptOn.HeyDiaryImport.TemplatesGoldenTest do
  @moduledoc """
  §12.3 golden test: whether rendering the Liquid templates of `PromptOn.HeyDiaryImport.Spec` with
  `PromptOnSDK.Template.render` is **byte-identical** to the strings the HeyDiary code assembled
  (`open_router.ex`, `search_content.ex`, `transcript_revision.ex`, `chat_response.ex
  extraction_prompt`). The HeyDiary-side assembly functions are reimplemented here verbatim.
  """

  use ExUnit.Case, async: true

  alias PromptOn.HeyDiaryImport.Spec
  alias PromptOnSDK.Template

  # --- HeyDiary original assembly (open_router.ex) ----------------------------

  defp numbered(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map_join("", fn {item, index} -> "#{index}. #{item}\n\n" end)
  end

  defp heydiary_diary_fresh(transcriptions),
    do:
      "Please write a diary entry based on these voice transcriptions:\n\n" <>
        numbered(transcriptions)

  defp heydiary_diary_incremental(existing_diary, new_transcriptions),
    do:
      "Here is the existing diary entry:\n---\n#{existing_diary}\n---\n\n" <>
        "Here are new voice transcriptions to incorporate:\n#{numbered(new_transcriptions)}\n" <>
        "Merge the new content into the existing diary naturally. Keep the existing content and style intact."

  defp heydiary_diary_with_user_content(user_content, all_transcriptions),
    do:
      "The user has written/edited their diary entry as follows:\n---\n#{user_content}\n---\n\n" <>
        "Here are all the voice transcriptions for the day:\n#{numbered(all_transcriptions)}\n" <>
        "Regenerate the diary entry. Preserve the user's manually written content and style as much as possible, while incorporating information from the voice transcriptions."

  defp heydiary_remove_content(current_diary, deleted_transcript),
    do:
      "[Current Diary]\n#{current_diary}\n\n" <>
        "[Deleted Recording Transcript]\n#{deleted_transcript}\n\n" <>
        "Remove content from the diary that originated from the deleted recording transcript. Keep all other content intact. Return the updated diary."

  defp heydiary_mood(diary_content),
    do: "Analyze this diary entry and return only the mood level (-3 to +3):\n\n#{diary_content}"

  # ai/search_content.ex
  defp heydiary_search_content(content, date, language),
    do: "[Output Language: #{language}]\nDate: #{date}\n\n#{content}"

  # workers/transcript_revision.ex build_prompt/2
  defp heydiary_transcript_revision(entities, transcript) do
    entity_lines =
      Enum.map_join(entities, "", fn {name, content} -> "- #{name}: #{content}\n" end)

    "[Named Entities]\n" <> entity_lines <> "\n[Transcript]\n" <> transcript
  end

  # workers/chat_response.ex extraction_prompt/3 (memory/message lookups turned into arguments)
  defp heydiary_extraction_prompt(language, today, existing, user_messages) do
    header = "[Output Language: #{language}]\n[Current Date: #{today}]\n\n"

    existing_block =
      if existing == [] do
        ""
      else
        "[Existing Memories - DO NOT extract these again]\n" <>
          Enum.map_join(existing, "", fn memory ->
            if memory.group_type == "named_entity" and not is_nil(memory.name) do
              "- [named_entity] #{memory.name}: #{memory.content}\n"
            else
              "- [user_info] #{memory.content}\n"
            end
          end) <> "\n[Conversation]\n"
      end

    conversation =
      Enum.map_join(user_messages, "", fn message -> "user: #{message.content}\n" end)

    header <> existing_block <> conversation
  end

  defp render!(key, vars) do
    {:ok, rendered} = Template.render(Spec.user_template(key), vars)
    rendered
  end

  @transcriptions [
    "Woke up early this morning",
    "Lunch was a sandwich, dinner was beer with friends\n(skipped the after-party)",
    "Prepare for tomorrow's meeting"
  ]

  describe "diary_generation (3 modes, one template)" do
    test "fresh == generate_diary_from_transcriptions" do
      assert render!("diary_generation", %{mode: "fresh", transcriptions: @transcriptions}) ==
               heydiary_diary_fresh(@transcriptions)
    end

    test "unknown/missing mode value falls into the fresh branch" do
      assert render!("diary_generation", %{mode: "", transcriptions: @transcriptions}) ==
               heydiary_diary_fresh(@transcriptions)
    end

    test "incremental == generate_diary_incremental" do
      existing = "This is how today went.\n\n---\nIt is not over yet."

      assert render!("diary_generation", %{
               mode: "incremental",
               transcriptions: @transcriptions,
               existing_diary: existing
             }) == heydiary_diary_incremental(existing, @transcriptions)
    end

    test "with_user_content == generate_diary_with_user_content" do
      user_content = "A diary entry I wrote myself.\nSecond line."

      assert render!("diary_generation", %{
               mode: "with_user_content",
               transcriptions: @transcriptions,
               user_content: user_content
             }) == heydiary_diary_with_user_content(user_content, @transcriptions)
    end

    test "empty transcription list keeps the exact tail (numbered/1 of [] is empty)" do
      assert render!("diary_generation", %{mode: "fresh", transcriptions: []}) ==
               heydiary_diary_fresh([])
    end
  end

  test "diary_content_removal == remove_content_from_diary" do
    assert render!("diary_content_removal", %{
             current_diary: "Diary body\nseveral lines",
             deleted_transcript: "Deleted recording transcript"
           }) ==
             heydiary_remove_content("Diary body\nseveral lines", "Deleted recording transcript")
  end

  test "mood_inference == infer_mood_from_diary" do
    assert render!("mood_inference", %{diary_content: "I felt good.\nReally."}) ==
             heydiary_mood("I felt good.\nReally.")
  end

  test "diary_search_content == SearchContent.generate" do
    assert render!("diary_search_content", %{language: "ko", date: "2026-08-18", content: "Body"}) ==
             heydiary_search_content("Body", "2026-08-18", "ko")
  end

  describe "transcript_revision == TranscriptRevision.build_prompt" do
    test "with entities" do
      entities = [{"Minsu", "college friend"}, {"Acme Corp", "the company I work at"}]

      vars = %{
        entities: Enum.map(entities, fn {n, c} -> %{name: n, content: c} end),
        transcript: "Met Minsu at Acme today"
      }

      assert render!("transcript_revision", vars) ==
               heydiary_transcript_revision(entities, "Met Minsu at Acme today")
    end

    test "without entities (app skips the call, but the bytes still match)" do
      assert render!("transcript_revision", %{entities: [], transcript: "t"}) ==
               heydiary_transcript_revision([], "t")
    end
  end

  describe "memory_extraction == ChatResponse.extraction_prompt" do
    @messages [
      %{role: "user", content: "I have not been sleeping well lately"},
      %{role: "user", content: "Because of work"}
    ]

    test "without existing memories — no [Conversation] header (Go behaviour preserved)" do
      assert render!("memory_extraction", %{
               language: "ko",
               today: "2026-08-18",
               existing_memories: [],
               conversation: @messages
             }) == heydiary_extraction_prompt("ko", "2026-08-18", [], @messages)
    end

    test "with existing memories — named_entity needs a name, otherwise user_info" do
      existing = [
        %{group_type: "named_entity", name: "Minsu", content: "college friend"},
        %{group_type: "named_entity", name: nil, content: "entity without a name"},
        %{group_type: "user_info", name: nil, content: "likes coffee"}
      ]

      assert render!("memory_extraction", %{
               language: "en",
               today: "2026-08-18",
               existing_memories: existing,
               conversation: @messages
             }) == heydiary_extraction_prompt("en", "2026-08-18", existing, @messages)
    end

    test "empty conversation" do
      assert render!("memory_extraction", %{
               language: "ko",
               today: "2026-08-18",
               existing_memories: [],
               conversation: []
             }) == heydiary_extraction_prompt("ko", "2026-08-18", [], [])
    end
  end

  test "every user template passes the P0 lint and declares only whitelisted tags/filters" do
    for key <- Spec.templated_use_case_keys() do
      assert :ok == Template.lint(Spec.user_template(key)), "lint failed for #{key}"
    end
  end

  test "detected variables of each template are covered by the use case input_schema" do
    for key <- Spec.templated_use_case_keys() do
      declared = Spec.use_case(key).input_schema |> Enum.map(& &1.name) |> Enum.sort()
      detected = Template.variables(Spec.user_template(key))
      assert detected -- declared == [], "#{key}: #{inspect(detected -- declared)} not declared"
    end
  end

  describe "escape_literal/1" do
    test "system prompt without liquid markers is unchanged" do
      assert {:ok, "plain text"} = Spec.escape_literal("plain text")
    end

    test "literal {{ and {% are escaped and render back byte-identical" do
      source = "keep {{date}} and {% now %} and {{- x -}} untouched, also }} %} alone"
      assert {:ok, escaped} = Spec.escape_literal(source)
      assert escaped != source
      assert {:ok, ^source} = Template.render(escaped, %{})
    end
  end
end
