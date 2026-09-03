# HeyDiary AI settings dump (`mix prompton.import_heydiary --dump`)

A single JSON file holding the three tables `ai_tasks` / `ai_models` / `plan_ai_models` **with
their column names as is** (plan.md §12.2 step 1):

```jsonc
{
  "ai_tasks":       [{"id", "task_name", "language" /* null = common */, "system_prompt", "temperature" /* null allowed */, "created_at", "updated_at"}],
  "ai_models":      [{"id", "model", "display_name", "description_key", "providers" /* array of strings or null */, "created_at", "updated_at"}],
  "plan_ai_models": [{"id", "plan", "task_name", "ai_model_id", "allow_fallbacks", "temperature", "is_default", "sort_order", "created_at", "updated_at"}]
}
```

`plan_ai_models.id` is **preserved as is** as the chat_response option id, so it must be included.
`created_at` is used to reproduce the ordering of the HeyDiary Registry (`sort_order, created_at,
id`).

## Producing it (HeyDiary DB)

Write the JSON straight to a file with `psql -At` (no alignment, tuples only). Do not use
`\copy … TO`: it is the COPY text format, which escapes `\n` and `\` and corrupts the JSON.

```sh
psql "$HEYDIARY_DATABASE_URL" -At -c "
SELECT json_build_object(
  'ai_tasks',       (SELECT coalesce(json_agg(t ORDER BY t.task_name, t.language NULLS LAST), '[]'::json) FROM ai_tasks t),
  'ai_models',      (SELECT coalesce(json_agg(m ORDER BY m.model), '[]'::json) FROM ai_models m),
  'plan_ai_models', (SELECT coalesce(json_agg(p ORDER BY p.created_at, p.id), '[]'::json) FROM plan_ai_models p)
)" > heydiary_dump.json
```

Check:

```sh
jq '{tasks: (.ai_tasks|length), models: (.ai_models|length), plan_models: (.plan_ai_models|length)}' heydiary_dump.json
```

## Using it

```sh
cd server
mix prompton.import_heydiary --dump heydiary_dump.json --org <org slug> --dry-run          # plan only
mix prompton.import_heydiary --dump heydiary_dump.json --org <org slug> --verify           # apply + §12.2 step 9 verification
mix prompton.export_heydiary_tables --org <org slug> --project heydiary --env production --out heydiary_tables.sql   # reverse (rollback)
```

Test fixture: `test/fixtures/heydiary/dump.json` (same format).
