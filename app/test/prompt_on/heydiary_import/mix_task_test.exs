defmodule PromptOn.HeyDiaryImport.MixTaskTest do
  @moduledoc """
  The `mix prompton.import_heydiary` entry point: `--dry-run --yes` prints the plan report only and
  writes nothing, the `--verify` path (apply + `Verify.compare`), option validation, and the output
  of `mix prompton.export_heydiary_tables`.
  """

  # The mix task writes to the app DB as SystemActor — shared sandbox mode (async: false).
  use PromptOn.DataCase, async: false

  import ExUnit.CaptureIO
  import PromptOn.Fixtures

  alias Mix.Tasks.Prompton.{ExportHeydiaryTables, ImportHeydiary}
  alias PromptOn.Projects

  @dump_path Path.expand("../../fixtures/heydiary/dump.json", __DIR__)

  test "--dry-run --yes prints the plan tables and writes nothing" do
    output =
      capture_io(fn -> ImportHeydiary.run(["--dump", @dump_path, "--dry-run", "--yes"]) end)

    assert output =~
             "HeyDiary import plan — project heydiary (HeyDiary), environment production"

    # Context dimensions were deleted — not in the report either
    refute output =~ "dimensions:"
    assert output =~ "Models (6)"
    assert output =~ "google/gemini-3.6-flash"
    assert output =~ "Use cases (9)"
    assert output =~ "chat_response"
    assert output =~ "Deployments (9; 12 pinned prompts — one model each, no rules)"
    assert output =~ "pinned prompts"
    assert output =~ "default,ko"
    assert output =~ "[confirm]"
    assert output =~ "plan-differentiated models are now the app's job"
    assert output =~ "temperatures differ per language"
    assert output =~ "dry run — nothing written."
    refute output =~ "Imported into project"
  end

  test "option validation: --org/--user required for apply, --dump always, unknown options rejected" do
    assert_raise Mix.Error, ~r/--org SLUG or --user EMAIL is required/, fn ->
      capture_io(fn -> ImportHeydiary.run(["--dump", @dump_path, "--yes"]) end)
    end

    assert_raise Mix.Error, ~r/--dump is required/, fn ->
      capture_io(fn -> ImportHeydiary.run(["--dry-run"]) end)
    end

    assert_raise Mix.Error, ~r/cannot load dump/, fn ->
      capture_io(fn -> ImportHeydiary.run(["--dump", "/nonexistent.json", "--dry-run"]) end)
    end

    assert_raise Mix.Error, ~r/unknown options/, fn ->
      capture_io(fn -> ImportHeydiary.run(["--dump", @dump_path, "--dry-run", "--bogus"]) end)
    end
  end

  test "apply with --yes --verify imports and verifies; export_heydiary_tables prints SQL" do
    user = user_fixture()

    # Personal organizations have no slug — the mix task addresses one with `--user EMAIL`.
    org = organization_for(user)
    assert is_nil(org.slug)
    email = to_string(user.email)
    project_slug = "heydiary-mix-#{System.unique_integer([:positive])}"

    output =
      capture_io(fn ->
        ImportHeydiary.run([
          "--dump",
          @dump_path,
          "--user",
          email,
          "--project",
          project_slug,
          "--yes",
          "--verify"
        ])
      end)

    assert output =~ "--yes given, proceeding."
    assert output =~ "Imported into project #{project_slug}"
    assert output =~ "[new project]"

    assert output =~
             "models 6 · use cases 9 · prompts 12 · prompt versions 12 · deployments 9 (12 pinned prompts)"

    assert output =~ "Verify: OK"
    assert output =~ "mix prompton.export"

    {:ok, project} = Projects.get_project_by_slug(org.id, project_slug, actor: system_actor())
    assert project

    # second run without --force is refused
    assert_raise Mix.Error, ~r/already has use cases/, fn ->
      capture_io(fn ->
        ImportHeydiary.run([
          "--dump",
          @dump_path,
          "--user",
          email,
          "--project",
          project_slug,
          "--yes"
        ])
      end)
    end

    # export to stdout
    sql =
      capture_io(fn ->
        ExportHeydiaryTables.run([
          "--user",
          email,
          "--project",
          project_slug,
          "--env",
          "production"
        ])
      end)

    assert sql =~ "-- WARNING: this export is LOSSY."
    assert sql =~ "BEGIN;"
    assert sql =~ "INSERT INTO ai_models"
    assert sql =~ "'free', 'chat_response', (SELECT id FROM ai_models WHERE model ="
    assert sql =~ "COMMIT;"

    # export to a file
    out =
      Path.join(System.tmp_dir!(), "heydiary_tables_#{System.unique_integer([:positive])}.sql")

    message =
      capture_io(fn ->
        ExportHeydiaryTables.run(["--user", email, "--project", project_slug, "--out", out])
      end)

    assert message =~ "wrote #{out}"
    assert File.read!(out) == sql
    File.rm!(out)

    assert_raise Mix.Error, ~r/not found/, fn ->
      capture_io(fn -> ExportHeydiaryTables.run(["--user", email, "--project", "nope"]) end)
    end
  end
end
