defmodule PromptOnWeb.PromptEditorLive do
  @moduledoc """
  **Use case hub** (`/{org_slug}/{project_slug}/use-cases/:key/prompt`), the product's central
  screen.

  Everything you do with one use case lives here. It is **one column** from top to bottom, and the
  order is the user journey:

  1. **Models**: pick several with the search picker (`?models=1`). One search box scans the project
     catalog and the OpenRouter public list together (`?msort=` sorts by price, newest, or context),
     and a catalog model is registered via `Catalog.register_model` the moment it is picked. A
     project model whose stored pricing is empty is filled on screen with the values of the same
     `(openrouter, model_id)` when the catalog arrives, and those values are saved as well
     (`backfill_pricing/1`), so a model registered before pricing storage existed does not stay `—`
     forever. BYOK keys are **organization-owned** (2026-09-01), so the picker does not accept them;
     without one, only a notice pointing to `/{org}/settings?tab=providers` is shown.
  2. **Prompt**: message editing plus variable declarations. **There is no save button**; every edit
     flows into the auto-saved draft (`Prompt.draft`).
  3. **Arena**: one send goes out to every selected model, and the conversation accumulates in the
     **persistent history** on the `(use case × model)` axis (`PromptOn.Prompts.ArenaMessage`). It
     is still there after leaving and coming back.
  4. **Deploy** (`?deploy=1`): pick an environment, a version, and a model, and commit a deployment
     revision (= a **pin**).
  5. **Deployments tab** (`?tab=deployments`): what this environment pins, history, rollback, and
     **Integration** (curl snippet plus integration instructions for coding AIs).

  Neither Playground nor Deployments is a separate menu; they live inside the use case.

  ## The tabs (2026-09-01)

  Items 1 and 2 are the **Editor** tab; item 3 is the **Arena** tab. Writing a prompt and pitting
  models against each other are each too tall vertically to share one screen. The model row
  (`arena_bar`) is the arena's header, so it moves with the arena. The model picker (`?models=1`) is
  a modal stacked **on top of** the tab parameter, so whichever tab it is opened from, it closes
  back to that tab (`editor_path/2` carries `?tab=` on every patch).

  ## The URL holds the state (CLAUDE.md zero-downtime deployment rules)

  | Parameter | Meaning |
  |---|---|
  | `?tab=editor\\|arena\\|deployments` | Tab (default editor; unknown values are editor too) |
  | `?prompt=<name>` | Name of the prompt being edited (missing or unknown name = default prompt) |
  | `?v=<number>` | **Read-only preview** of that version (absent = draft editing, the default) |
  | `?versions=1` | The version list drawer is open |
  | `?diff=<number>` | Diff mode comparing this version with the selected version |
  | `?models=1` | The model search picker is open |
  | `?msort=relevance\\|cheapest\\|newest\\|context` | Picker sort (default relevance; unknown values too) |
  | `?deploy=1` | The Deploy modal is open |
  | `?ai=<message-index>` | The AI draft modal for that message is open |
  | `?new_prompt=1` | The "new prompt" modal is open |
  | `?var=<name>` | That declared variable row is expanded |
  | `?full=1` | The arena is open as a **full-screen overlay** (Arena tab only) |
  | `?env=<slug>` `?rev=<n>` `?confirm=<id>` | Deployments tab state (environment, revision viewed, rollback confirm) |
  (On the Deployments tab, `?deploy=1` rides along with these parameters too, so opening and closing
  the modal keeps the environment being viewed.)

  Selection, diff, drawers, and modals are all `push_patch`. A textarea being edited survives a
  remount because `phx-change="validate"` **writes the draft to the DB** on every input (we do not
  rely on form recovery).

  **The arena input box and variable values are not put in the URL** (assigns only): they are not
  something to share or return to, and they are not URL-sized. The conversation itself, on the other
  hand, is now a **table** rather than a session, so a remount restores it as is.

  ## Arena: persistent history

  - Columns are `use_case.arena_model_ids` **exactly** (only the selected models, in the selected
    order). The chip's x only hides the column; the history stays in the table, and picking the same
    model again in the picker brings the column back **with its past conversation**, because the
    history is always read for the whole use case at once. The picker marks rows that are not
    selected but have history with "has history" to announce that fact in advance.
  - Sending writes one `:user` row per model (each cell is an independent conversation) and spawns
    one `start_async` per model. The request messages = *the rendered current buffer* ++ *that
    cell's last 30 turns* ++ *the new user turn* (`EditorTestRun.context_turns/2`).
  - The response is written as an `:assistant` row; a failure is kept too, with `status: :error`
    (what happened is the record). `prompt_version_number` is that number **only when the draft
    equals the latest commit**; if the draft has been edited it is `nil` (a draft is not a version,
    so there is no number to point at).
  - `kind :text` is one-shot, so it accumulates **only `:assistant` rows** and puts that run's
    variables in `params` (`%{"variables" => …}`). The screen shows only the last output per cell.
  - Editing the prompt does not clear the history (it is a log, not a session); a quiet one-liner
    merely announces that "the next turns go out with the new prompt". The only things that delete
    are the per-cell clear and the global Clear history.

  ## The draft auto-saves; Deploy mints versions (ADR 0007 revision 2026-09-01)

  The editor has **one verb: Deploy**. There is no "unsaved" state, no Save button, and no commit
  message field.

  - **Auto-save**: every `validate` writes the buffer via `Prompts.save_prompt_draft/3`
    (`:save_draft`). Unchanged content is not written (inputs already arrive batched by
    `phx-debounce`). Adding/removing messages and AI replacement work the same way.
  - **Preview**: `?v=<n>` is that version's **read-only** screen. Its only write action is "Restore
    this version to draft", and even that only overwrites the draft without creating a version. That
    is why switching prompts or versions has no confirmation dialog: there is nothing to discard.
  - **Deploy**: choosing "Current draft" in the modal mints v(N+1) via
    `Prompts.commit_prompt_version/2` **only if** the draft differs from the latest commit (with the
    optional commit message, or `"Deployed to <env>"` when blank); if they are the same, that
    version is reused. Choosing a past version mints nothing. Then **one pin** is committed to that
    environment (ADR 0007 revision 2026-09-01): a map pinning the chosen model plus **every prompt**
    of this use case to its own latest committed version (only the prompt currently being edited
    gets the version chosen in the modal). There are no rules, conditions, targets, or weights; the
    only selection axis at request time is the prompt name. The modal lists exactly what it will
    pin.
  """
  use PromptOnWeb, :live_view

  import PromptOnWeb.DeploymentsComponents
  import PromptOnWeb.PromptEditorComponents

  alias PromptOn.Accounts
  alias PromptOn.Catalog
  alias PromptOn.Deployments
  alias PromptOn.Deployments.Deployment
  alias PromptOn.Prompts
  alias PromptOn.Prompts.Prompt
  alias PromptOn.Prompts.PromptVersion
  alias PromptOnSDK.Params
  alias PromptOnSDK.Template
  alias PromptOnWeb.EditorTestRun
  alias PromptOnWeb.ErrorText
  alias PromptOnWeb.EvalsComponents
  alias PromptOnWeb.IntegrationComponents
  alias PromptOnWeb.ProviderCatalog

  @ai_model "anthropic/claude-sonnet-4"
  @chat_roles ~w(system user assistant)
  @text_roles ~w(text)
  @draft_option "draft"
  @prompt_changed_notice "Prompt changed — the next turns use the new prompt (history is kept)."
  @picker_limit 50
  @model_sorts ~w(relevance cheapest newest context)

  @sort_labels %{
    "relevance" => "Relevance",
    "cheapest" => "Cheapest",
    "newest" => "Newest",
    "context" => "Context"
  }
  @tabs ~w(editor arena deployments evals)

  @tab_labels %{
    "editor" => "Editor",
    "arena" => "Arena",
    "deployments" => "Deployments",
    "evals" => "Evals"
  }

  # Only the default tab (editor) leaves the URL empty; the other tabs must ride along on every
  # patch link.
  @sticky_tabs ~w(arena deployments evals)

  # The Evals tab's own query parameters (ADR 0010 §5.2). They are handed to
  # `PromptOnWeb.EvalsPanel` as one map; the panel, not this module, decides what they mean.
  @eval_params ~w(set rubric revise edit_rubric evaluate run env)

  @var_types ~w(string number boolean list map)

  @tag_regex ~r/\{%\s*(\w+)/
  @for_regex ~r/\{%\s*for\s+(\w+)\s+in\s+([\w.]+)/

  # ---------------------------------------------------------------------------
  # Mount and params

  @impl Phoenix.LiveView
  def mount(%{"key" => key}, _session, socket) do
    case load_use_case(socket, key) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Use case not found: #{key}")
         |> push_navigate(
           to: ~p"/#{socket.assigns.org_slug}/#{socket.assigns.project.slug}/use-cases"
         )}

      use_case ->
        {:ok,
         socket
         |> assign(
           use_case: use_case,
           tab: hd(@tabs),
           prompts: [],
           prompt: nil,
           form: to_form(%{}, as: :editor),
           page_title: "#{use_case.key} · #{socket.assigns.project.slug}",
           selected: nil,
           selected_number: nil,
           diff_number: nil,
           versions_open?: false,
           versions: [],
           messages: [],
           engine: :liquid,
           lint_error: nil,
           deployments: nil,
           version_numbers: %{},
           models: [],
           model_index: %{},
           model_catalog: [],
           catalog_prices: %{},
           catalog_state: nil,
           picker_open?: false,
           model_sort: hd(@model_sorts),
           model_query: "",
           model_picks: [],
           provider_key: nil,
           arena_models: [],
           arena_history: %{},
           arena_running: %{},
           arena_vars: %{},
           arena_input: "",
           arena_notice: nil,
           arena_full?: false,
           deploy?: false,
           deploy_env_id: nil,
           deploy_model_id: nil,
           deploy_version_id: nil,
           deploy_message: "",
           new_prompt?: false,
           prompt_name: "",
           prompt_description: "",
           var_types: @var_types,
           expanded_var: nil,
           new_variable: "",
           dep_env: nil,
           dep_key: nil,
           dep_history: [],
           dep_live: nil,
           dep_revision: nil,
           dep_confirm: nil,
           dep_scores: %{},
           eval_params: %{},
           env_slug: nil,
           prompt_versions: nil,
           version_index: %{}
         )
         |> assign_ai_closed()
         |> load_prompts()
         |> load_models()
         |> load_provider_key()
         |> load_arena()
         |> assign_detection()}
    end
  end

  # Pick the prompt being edited **first**: `?v`/`?diff` must be checked against that prompt's
  # version list.
  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:tab, tab_param(params))
     |> apply_prompt(params["prompt"])
     |> apply_selection(params["v"])
     |> ensure_deployments()
     |> apply_diff(params["diff"])
     |> apply_flag(:versions_open?, params["versions"])
     |> apply_flag(:arena_full?, params["full"])
     |> apply_ai(params["ai"])
     |> apply_new_prompt(params["new_prompt"])
     |> apply_variable(params["var"])
     |> apply_picker(params["models"], params["msort"])
     |> apply_deploy(params["deploy"])
     |> apply_env_slug(params)
     |> apply_deployments_tab(params)
     |> apply_evals_tab(params)}
  end

  # `?env=` belongs to the Deployments tab, and the Evals tab reuses it (ADR 0010 §5.2). Resolving
  # it on **every** tab is what makes switching between the two keep the environment you were
  # looking at; an absent or unknown slug stays nil, so the Editor and Arena tabs keep clean URLs.
  defp apply_env_slug(socket, %{"env" => slug}) when is_binary(slug) do
    case Enum.find(socket.assigns.envs, &(&1.slug == slug)) do
      nil -> assign(socket, :env_slug, nil)
      env -> assign(socket, :env_slug, env.slug)
    end
  end

  defp apply_env_slug(socket, _params), do: assign(socket, :env_slug, nil)

  # The Evals tab keeps its whole state in one map; the panel is a LiveComponent, so it reads them
  # in `update/2` (the panel is only rendered while the tab is open, so nothing is loaded until
  # then).
  defp apply_evals_tab(socket, params),
    do: assign(socket, :eval_params, Map.take(params, @eval_params))

  defp tab_param(%{"tab" => tab}) when tab in @tabs, do: tab
  defp tab_param(_params), do: hd(@tabs)

  defp apply_flag(socket, key, raw) when is_binary(raw) and raw != "",
    do: assign(socket, key, true)

  defp apply_flag(socket, key, _raw), do: assign(socket, key, false)

  defp load_use_case(socket, key) do
    project = socket.assigns.project

    case Prompts.get_use_case_by_key(key,
           tenant: project.id,
           actor: socket.assigns.current_user
         ) do
      {:ok, use_case} -> use_case
      {:error, _error} -> nil
    end
  end

  # The default prompt is `"default"`, else the first prompt (`nil` when there is none at all, as
  # with an embedding use case).
  defp default_prompt(prompts) when is_list(prompts),
    do: Enum.find(prompts, &(&1.name == "default")) || List.first(prompts)

  defp default_prompt(_prompts), do: nil

  # The list holds only unarchived prompts, with the default prompt first and the rest by name.
  defp load_prompts(socket) do
    opts = Keyword.put(scope(socket), :load, [:version_count])

    prompts =
      case Prompts.list_prompts(socket.assigns.use_case.id, opts) do
        {:ok, list} -> Enum.sort_by(list, &{&1.name != "default", &1.name})
        {:error, _error} -> []
      end

    assign(socket, prompts: prompts, prompt_versions: nil)
  end

  # `?prompt=` selects the prompt being edited. When the target changes, the version list,
  # selection, diff, AI modal, and edit buffer are all reset: numbering runs separately per prompt,
  # so `?v=2` means a different version. Each prompt has its own draft, so the buffer restarts from
  # that prompt's draft.
  defp apply_prompt(socket, raw) do
    prompts = socket.assigns.prompts
    target = find_prompt(prompts, raw) || default_prompt(prompts)

    if current_prompt_id(target) == current_prompt_id(socket.assigns.prompt) do
      socket
    else
      socket
      |> assign(prompt: target, selected: nil, selected_number: nil, diff_number: nil)
      |> assign_ai_closed()
      |> load_versions()
      |> load_draft()
      |> maybe_start_catalog()
      |> assign_page_title()
    end
  end

  defp find_prompt(prompts, name) when is_binary(name),
    do: Enum.find(prompts, &(&1.name == name))

  defp find_prompt(_prompts, _name), do: nil

  # The name check runs **before** the action: an identity violation surfaces as
  # `use_case_id: has already been taken`, which cannot say "ko already exists". The action is still
  # the last gate (races).
  defp open_prompt(_socket, "", _description),
    do: {:error, ErrorText.message(invalid_name("is required"))}

  defp open_prompt(socket, name, description) do
    if Enum.any?(socket.assigns.prompts, &(&1.name == name)) do
      {:error, ErrorText.message(invalid_name("has already been taken"))}
    else
      attrs = %{
        use_case_id: socket.assigns.use_case.id,
        name: name,
        description: description
      }

      case Prompts.open_prompt(attrs, scope(socket)) do
        {:ok, prompt} -> {:ok, prompt}
        {:error, error} -> {:error, ErrorText.message(error)}
      end
    end
  end

  defp invalid_name(message),
    do: Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: message)

  defp current_prompt_id(%{id: id}), do: id
  defp current_prompt_id(_prompt), do: nil

  # The name goes into the title only for non-default prompts: with several browser tabs open, it
  # must be visible which language each one has open.
  defp assign_page_title(socket) do
    %{use_case: use_case, prompt: prompt, project: project} = socket.assigns

    suffix =
      case prompt do
        %{name: name} when name != "default" -> " (#{name})"
        _other -> ""
      end

    assign(socket, :page_title, "#{use_case.key}#{suffix} · #{project.slug}")
  end

  defp load_versions(socket), do: assign(socket, :versions, list_versions(socket))

  defp list_versions(%{assigns: %{prompt: nil}}), do: []

  defp list_versions(socket) do
    case Prompts.list_prompt_versions(socket.assigns.prompt.id, scope(socket)) do
      {:ok, versions} -> Enum.sort_by(versions, & &1.number, :desc)
      {:error, _error} -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Live deployments (one row per environment: its highest revision)

  # The editor tab asks only two things about deployments: "is this version running somewhere" (the
  # `live` marker in the version list) and "what is each environment's current revision number" (the
  # Deploy modal). One row per environment answers both.
  defp ensure_deployments(%{assigns: %{deployments: nil}} = socket), do: load_deployments(socket)
  defp ensure_deployments(socket), do: socket

  defp load_deployments(socket) do
    opts = scope(socket)
    use_case_id = socket.assigns.use_case.id

    current =
      Map.new(socket.assigns.envs, fn env ->
        case Deployments.current_deployment(use_case_id, env.id, opts) do
          {:ok, deployment} -> {env.id, deployment}
          {:error, _error} -> {env.id, nil}
        end
      end)

    socket |> assign(:deployments, current) |> assign_version_numbers()
  end

  # The version a deployment points at may belong to another prompt (default deployed while
  # `?prompt=ko` is open). Numbers already in the current list are used first and only unknown ids
  # are fetched one by one; the cache survives switching prompts.
  defp assign_version_numbers(socket) do
    known =
      socket.assigns.versions
      |> Map.new(&{&1.id, &1.number})
      |> Map.merge(socket.assigns.version_numbers)

    numbers =
      socket
      |> deployed_version_ids()
      |> Enum.reduce(known, fn id, acc ->
        if Map.has_key?(acc, id), do: acc, else: fetch_version_number(socket, acc, id)
      end)

    assign(socket, :version_numbers, numbers)
  end

  defp deployed_version_ids(socket) do
    socket.assigns.deployments
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&Deployment.prompt_version_ids/1)
    |> Enum.uniq()
  end

  defp fetch_version_number(socket, acc, id) do
    case Prompts.get_prompt_version(id, scope(socket)) do
      {:ok, %{number: number}} -> Map.put(acc, id, number)
      _other -> acc
    end
  end

  # Environments whose live deployment points at this version (the `live` marker in the version
  # list).
  defp live_env_map(assigns) do
    Enum.reduce(assigns.envs, %{}, fn env, acc ->
      case Map.get(assigns.deployments || %{}, env.id) do
        nil ->
          acc

        deployment ->
          Enum.reduce(Deployment.prompt_version_ids(deployment), acc, fn id, inner ->
            Map.update(inner, id, [env.slug], &(&1 ++ [env.slug]))
          end)
      end
    end)
  end

  # `?v=` is a **read-only preview** (ADR 0007 revision): the buffer is always the draft, and this
  # selection never touches it. A missing or unknown number means draft editing (the default state).
  defp apply_selection(socket, raw) do
    number = parse_int(raw)
    version = number && Enum.find(socket.assigns.versions, &(&1.number == number))

    assign(socket, selected: version, selected_number: version && version.number)
  end

  defp apply_diff(socket, raw) do
    number = parse_int(raw)

    valid? =
      number != nil and number != socket.assigns.selected_number and
        Enum.any?(socket.assigns.versions, &(&1.number == number))

    assign(socket, :diff_number, if(valid?, do: number, else: nil))
  end

  # The upper-bound (message count) check is deferred to **render time**. Right after a remount,
  # `handle_params` sees only the saved version's messages; the "added but not yet saved" messages
  # that form recovery (`validate`) will revive are not there yet.
  defp apply_ai(socket, raw) do
    index = parse_int(raw, 0)

    cond do
      is_nil(index) -> assign_ai_closed(socket)
      index == socket.assigns.ai_index -> socket
      true -> socket |> assign(:ai_index, index) |> assign_ai_reset()
    end
  end

  # The modal inputs (name, description) are not put in the URL: they are a form being typed, not
  # state to share.
  defp apply_new_prompt(socket, raw) when is_binary(raw) and raw != "" do
    if socket.assigns.new_prompt?,
      do: socket,
      else: assign(socket, new_prompt?: true, prompt_name: "", prompt_description: "")
  end

  defp apply_new_prompt(socket, _raw), do: assign(socket, :new_prompt?, false)

  # Only the expanded variable row is held by the URL: form recovery can restore description/example
  # only while that row is alive.
  defp apply_variable(socket, raw) when is_binary(raw) and raw != "",
    do: assign(socket, :expanded_var, raw)

  defp apply_variable(socket, _raw), do: assign(socket, :expanded_var, nil)

  # For the picker, the URL holds **the fact that it is open, and the sort**; the query and the
  # checkboxes are a form being typed, so they live in assigns. They are cleared on every open (a
  # half-picked list left over from last time makes it unclear what gets added).
  defp apply_picker(socket, raw, sort) when is_binary(raw) and raw != "" do
    socket =
      if socket.assigns.picker_open?,
        do: socket,
        else: assign(socket, model_query: "", model_picks: [])

    socket
    |> assign(picker_open?: true, model_sort: sort_param(sort))
    |> maybe_start_catalog()
  end

  # Closing resets the sort to the default too: the closing patch drops `?msort` along with
  # `?models`.
  defp apply_picker(socket, _raw, _sort),
    do: assign(socket, picker_open?: false, model_sort: hd(@model_sorts))

  # Unknown values mean the default sort (a hand-edited URL must not break the screen).
  defp sort_param(sort) when sort in @model_sorts, do: sort
  defp sort_param(_sort), do: hd(@model_sorts)

  # For the Deploy modal too, the URL holds only the fact that it is open. The defaults are
  # production + **the current draft** + the arena's first model. The modal lists exactly "what will
  # be pinned", so the latest version per prompt is read here.
  defp apply_deploy(socket, raw) when is_binary(raw) and raw != "" do
    if socket.assigns.deploy? do
      socket
    else
      socket
      |> assign(
        deploy?: true,
        deploy_env_id: default_env_id(socket),
        deploy_model_id: default_deploy_model_id(socket),
        deploy_version_id: default_deploy_version_id(socket),
        deploy_message: ""
      )
      |> ensure_prompt_versions()
    end
  end

  defp apply_deploy(socket, _raw), do: assign(socket, :deploy?, false)

  defp default_env_id(socket) do
    envs = socket.assigns.envs
    env = Enum.find(envs, &(&1.slug == "production")) || List.first(envs)
    env && env.id
  end

  # What you want to deploy is the model you just pitted: the arena's first model, else the
  # catalog's first.
  defp default_deploy_model_id(socket) do
    model =
      List.first(socket.assigns.arena_models) || List.first(deploy_model_order(socket.assigns))

    model && model.id
  end

  # What gets deployed is the draft on screen right now; redeploying a past version must be chosen
  # in the select.
  defp default_deploy_version_id(socket) do
    if socket.assigns.prompt, do: @draft_option, else: nil
  end

  # The Deploy modal's model list = **every active model of this project** (models that have been
  # pitted in the arena come first, with an `arena` badge; the rest are by display name, the order
  # `load_models/1` already reads them in). A model not yet run in the arena must be deployable
  # too: the arena is a place to choose, not a gate.
  #
  # An arena chip can also point at an archived model (`model_index` is the full list), so models
  # missing from the active list are dropped: no row that can be chosen but `deploy_model/2`
  # rejects.
  defp deploy_model_order(assigns) do
    active_ids = MapSet.new(assigns.models, & &1.id)
    arena = Enum.filter(assigns.arena_models, &MapSet.member?(active_ids, &1.id))
    arena_ids = MapSet.new(arena, & &1.id)

    arena ++ Enum.reject(assigns.models, &MapSet.member?(arena_ids, &1.id))
  end

  defp assign_ai_closed(socket) do
    socket |> assign(:ai_index, nil) |> assign_ai_reset()
  end

  defp assign_ai_reset(socket) do
    assign(socket, ai_stage: :intro, ai_instruction: "", ai_result: nil, ai_error: nil)
  end

  defp parse_int(raw, min \\ 1)
  defp parse_int(nil, _min), do: nil

  defp parse_int(raw, min) when is_binary(raw) do
    case Integer.parse(raw) do
      {number, ""} when number >= min -> number
      _other -> nil
    end
  end

  defp parse_int(_raw, _min), do: nil

  # ---------------------------------------------------------------------------
  # Edit buffer = the auto-saved draft

  # The effective draft: the saved draft if there is one, else **the latest version's content** (an
  # empty document if there is no version either). `engine` follows the same order: commit and
  # arena render must use the same engine.
  defp load_draft(socket) do
    use_case = socket.assigns.use_case
    latest = List.first(socket.assigns.versions)

    {engine, messages} =
      case Prompt.draft_content(socket.assigns.prompt) do
        nil -> {(latest && latest.engine) || :liquid, version_messages(use_case, latest)}
        draft -> {draft.engine, draft_messages(use_case, draft)}
      end

    socket
    |> assign(messages: messages, engine: engine, lint_error: nil)
    |> assign_detection()
  end

  # A draft has the same shape as a version, so the per-kind extraction rule is the same.
  defp draft_messages(%{kind: :text}, draft),
    do: [%{role: "text", content: draft.text_template || ""}]

  defp draft_messages(_use_case, %{messages: []}), do: [%{role: "system", content: ""}]
  defp draft_messages(_use_case, %{messages: messages}), do: messages

  # The `?v=` preview is read-only: an event arriving late, after a patch removed the form, must not
  # overwrite the draft.
  defp put_buffer(%{assigns: %{selected: version}} = socket, _messages) when not is_nil(version),
    do: socket

  # A buffer change does not clear the conversation: the arena is a table, not a session. It does
  # announce that a different prompt goes out from the next turn on (only when there is
  # accumulated conversation).
  #
  # Unchanged content does nothing: `validate` also arrives via form recovery, and rewriting the
  # same value is just a DB round trip.
  defp put_buffer(socket, messages) do
    if messages == socket.assigns.messages do
      socket
    else
      socket
      |> assign(:messages, messages)
      |> maybe_notice()
      |> assign_detection()
      |> write_draft()
    end
  end

  defp maybe_notice(socket) do
    if any_history?(socket.assigns),
      do: assign(socket, :arena_notice, @prompt_changed_notice),
      else: socket
  end

  # Auto-save. With no prompt (embedding) there is nowhere to write; if equal to the saved draft,
  # nothing is written.
  defp write_draft(%{assigns: %{prompt: nil}} = socket), do: socket

  defp write_draft(socket) do
    draft = draft_attrs(socket.assigns)

    if draft == socket.assigns.prompt.draft do
      socket
    else
      case Prompts.save_prompt_draft(socket.assigns.prompt, %{draft: draft}, scope(socket)) do
        {:ok, prompt} -> put_draft(socket, prompt.draft)
        {:error, error} -> put_flash(socket, :error, ErrorText.message(error))
      end
    end
  end

  defp draft_attrs(assigns) do
    attrs = content_attrs(assigns.use_case, assigns.messages)

    Prompt.draft_map(
      assigns.engine,
      Map.get(attrs, :messages, []),
      Map.get(attrs, :text_template)
    )
  end

  # The prompts in the list carry an aggregate (`version_count`); instead of re-reading, only the
  # draft field is swapped.
  defp put_draft(socket, draft) do
    id = socket.assigns.prompt.id

    prompts =
      Enum.map(socket.assigns.prompts, fn prompt ->
        if prompt.id == id, do: %{prompt | draft: draft}, else: prompt
      end)

    assign(socket, prompt: %{socket.assigns.prompt | draft: draft}, prompts: prompts)
  end

  @doc false
  @spec version_messages(map(), map() | nil) :: [%{role: String.t(), content: String.t()}]
  def version_messages(%{kind: :text}, version),
    do: [%{role: "text", content: (version && version.text_template) || ""}]

  def version_messages(_use_case, nil), do: [%{role: "system", content: ""}]

  def version_messages(_use_case, %{messages: []}), do: [%{role: "system", content: ""}]

  def version_messages(_use_case, %{messages: messages}),
    do: Enum.map(messages, &%{role: to_string(&1.role), content: &1.content || ""})

  defp roles(%{kind: :text}), do: @text_roles
  defp roles(_use_case), do: @chat_roles

  # ---------------------------------------------------------------------------
  # Variable detection (for display; the stored value is built by `Changes.ComputeDerived` with
  # the same code)

  defp assign_detection(socket) do
    messages = socket.assigns.messages
    text = Enum.map_join(messages, "\n", & &1.content)

    bindings =
      @for_regex |> Regex.scan(text) |> Enum.map(fn [_all, binding | _] -> binding end)

    vars =
      messages
      |> Enum.flat_map(&Template.variables(&1.content))
      |> Enum.reject(&(&1 in bindings))
      |> Enum.uniq()
      |> Enum.sort()

    tags = @tag_regex |> Regex.scan(text) |> Enum.map(fn [_all, tag] -> tag end) |> Enum.uniq()

    declared = declared_variables(socket)
    declared_names = Enum.map(declared, & &1.name)

    unused =
      declared
      |> Enum.filter(&(&1.required? and &1.name not in vars))
      |> Enum.map(& &1.name)

    assign(socket,
      detected: %{vars: vars, tags: tags, bindings: Enum.uniq(bindings)},
      declared: declared,
      undeclared: Enum.reject(vars, &(&1 in declared_names)),
      unused: unused
    )
  end

  defp declared_variables(socket) do
    case socket.assigns.use_case.input_schema do
      schema when is_list(schema) -> schema
      _other -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Variable declarations (writes `UseCase.input_schema`, replacing the whole array)

  defp write_schema(socket, schema) do
    case Prompts.set_use_case_input_schema(
           socket.assigns.use_case,
           %{input_schema: schema},
           scope(socket)
         ) do
      {:ok, use_case} ->
        {:ok, socket |> assign(:use_case, use_case) |> assign_detection()}

      {:error, error} ->
        {:error, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  defp declare_variables(socket, names) do
    declared = socket.assigns.declared
    known = MapSet.new(declared, & &1.name)

    additions =
      names
      |> Enum.uniq()
      |> Enum.reject(&(&1 in known))
      |> Enum.map(&%{name: &1, type: :string, required?: false})

    if additions == [] do
      socket
    else
      unwrap(write_schema(socket, schema_maps(declared) ++ additions))
    end
  end

  defp schema_maps(declared), do: Enum.map(declared, &variable_map/1)

  defp variable_map(variable) do
    %{
      name: variable.name,
      type: variable.type,
      required?: variable.required?,
      description: variable.description,
      example: variable.example
    }
  end

  # A collapsed row has no description/example inputs at all, so a missing key means "not sent",
  # not "cleared", and falls back to the current value (otherwise changing just the type would wipe
  # the description).
  defp variable_params(current, params) do
    %{
      name: current.name,
      type: variable_type(Map.get(params, "type"), current.type),
      required?: variable_required?(Map.get(params, "required?"), current.required?),
      description: variable_text(Map.get(params, "description"), current.description),
      example: variable_text(Map.get(params, "example"), current.example)
    }
  end

  defp variable_type(raw, fallback) when is_binary(raw) do
    if raw in @var_types, do: String.to_existing_atom(raw), else: fallback
  end

  defp variable_type(_raw, fallback), do: fallback

  defp variable_required?(nil, fallback), do: fallback
  defp variable_required?(raw, _fallback), do: raw in ["true", "on"]

  defp variable_text(nil, fallback), do: fallback
  defp variable_text(raw, _fallback) when is_binary(raw), do: blank_to_nil(String.trim(raw))

  defp unwrap({_status, socket}), do: socket

  defp add_variable(socket, "") do
    {:error, put_flash(socket, :error, ErrorText.message(invalid_variable("is required")))}
  end

  defp add_variable(socket, name) do
    declared = socket.assigns.declared

    if Enum.any?(declared, &(&1.name == name)) do
      {:error,
       put_flash(socket, :error, ErrorText.message(invalid_variable("is already declared")))}
    else
      write_schema(
        socket,
        schema_maps(declared) ++ [%{name: name, type: :string, required?: false}]
      )
    end
  end

  defp invalid_variable(message),
    do: Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: message)

  # ---------------------------------------------------------------------------
  # Models (catalog, key, picker)

  defp load_models(socket) do
    opts = scope(socket)

    all =
      case Catalog.list_all_models(opts) do
        {:ok, models} -> models
        {:error, _error} -> []
      end

    active =
      case Catalog.list_models(opts) do
        {:ok, models} -> Enum.sort_by(models, &{&1.display_name, &1.model_id})
        {:error, _error} -> []
      end

    assign(socket, models: active, model_index: Map.new(all, &{&1.id, &1}))
  end

  # BYOK keys are **organization-owned** (2026-09-01): we ask the project's organization, not the
  # project. Only the display value (`secret_hint`) is used here, so the secret is never loaded.
  defp load_provider_key(socket) do
    organization_id = socket.assigns.project.organization_id

    case Accounts.active_provider_key(organization_id, :openrouter,
           actor: socket.assigns.current_user
         ) do
      {:ok, %{} = key} -> assign(socket, :provider_key, key)
      _other -> assign(socket, :provider_key, nil)
    end
  end

  # Listing needs no auth, so the catalog can be filled **before** a key is added
  # (`ProviderCatalog`). Not started during the static render: a task run from a disconnected mount
  # leaves only a request that never reaches the screen.
  defp maybe_start_catalog(socket) do
    if connected?(socket) and socket.assigns.catalog_state == nil,
      do: start_catalog(socket),
      else: socket
  end

  defp start_catalog(socket) do
    socket
    |> assign(:catalog_state, :loading)
    |> start_async(:model_catalog, fn -> ProviderCatalog.list_openrouter_models() end)
  end

  # OpenRouter list pricing as `(model_id → pricing in stored form)`. Entries with unknown pricing
  # (`%{}`) are kept as is: the screen's `Map.get/3` treats "absent" and "unknown" the same.
  defp catalog_price_index(catalog) do
    Map.new(catalog, &{&1.model_id, catalog_pricing(Map.get(&1, :pricing))})
  end

  # For a project model, **the stored pricing wins**. If the stored value has no rates at all, the
  # screen alone is filled with the catalog value of the same `(openrouter, model_id)`: models
  # registered before pricing storage existed and models that came in via the import path had
  # `pricing: %{}` and stayed `—` forever (saving is `backfill_pricing/1`).
  defp model_pricing(index, %{provider: :openrouter, model_id: model_id, pricing: pricing}) do
    if rates(pricing) == {nil, nil}, do: Map.get(index, model_id) || pricing, else: pricing
  end

  defp model_pricing(_index, %{pricing: pricing}), do: pricing

  # While the catalog is here, **actually fill in the empty pricing**: the screen fallback is only
  # true while the catalog is around, and only a saved value lets `Model.estimate_cost/3` fill
  # ingest costs too. Written as the current user, not the system actor (the policy checks project
  # membership). Failures are swallowed: pricing is auxiliary, and `—` beats a picker that will not
  # open.
  defp backfill_pricing(socket) do
    index = socket.assigns.catalog_prices

    filled =
      socket.assigns.models
      |> Enum.filter(&missing_rates?/1)
      |> Enum.map(&{&1, Map.get(index, &1.model_id, %{})})
      |> Enum.reject(fn {_model, pricing} -> pricing == %{} end)
      |> Enum.reduce(0, fn {model, pricing}, acc ->
        case Catalog.set_model_pricing(model, %{pricing: pricing}, scope(socket)) do
          {:ok, _model} -> acc + 1
          {:error, _error} -> acc
        end
      end)

    if filled > 0, do: socket |> load_models() |> assign_arena_models(), else: socket
  rescue
    _error -> socket
  end

  defp missing_rates?(%{provider: :openrouter, pricing: pricing}),
    do: rates(pricing) == {nil, nil}

  defp missing_rates?(_model), do: false

  # Models already in the catalog are removed from the OpenRouter group: the same
  # `(provider, model_id)` exists only once, so showing it twice makes "register" a choice that
  # does nothing.
  defp catalog_entries(assigns) do
    registered =
      assigns.models
      |> Enum.filter(&(&1.provider == :openrouter))
      |> MapSet.new(& &1.model_id)

    assigns.model_catalog
    |> Enum.reject(&MapSet.member?(registered, &1.model_id))
    |> Enum.sort_by(& &1.display_name)
  end

  # Picker results. The query matches name and id together. Besides the display values, each row
  # also carries the **sort keys** (`input_per_m`, `output_per_m`, `context_length`, `created`).
  defp picker_matches(assigns) do
    query = assigns.model_query |> to_string() |> String.trim() |> String.downcase()
    arena_ids = MapSet.new(assigns.arena_models, & &1.id)
    history_ids = history_model_ids(assigns)
    picks = assigns.model_picks

    project =
      Enum.map(assigns.models, fn model ->
        pricing = model_pricing(assigns.catalog_prices, model)
        {input, output} = rates(pricing)
        selected? = MapSet.member?(arena_ids, model.id)

        %{
          value: model.id,
          dom_id: safe_dom_id(model.id),
          name: model.display_name,
          model_id: model.model_id,
          price: price_label(pricing),
          source: :project,
          selected?: selected?,
          # A model not selected but with a conversation left: picking it again brings that
          # conversation back.
          history?: not selected? and MapSet.member?(history_ids, model.id),
          checked?: model.id in picks,
          input_per_m: input,
          output_per_m: output,
          context_length: model.context_length,
          # The listing time exists only in the provider list, so a project model is "unknown"
          # (last under Newest).
          created: nil
        }
      end)

    catalog =
      assigns
      |> catalog_entries()
      |> Enum.map(fn entry ->
        value = "catalog:" <> entry.model_id
        {input, output} = rates(Map.get(entry, :pricing))

        %{
          value: value,
          dom_id: safe_dom_id(entry.model_id),
          name: entry.display_name,
          model_id: entry.model_id,
          price: price_label(Map.get(entry, :pricing)),
          source: :catalog,
          selected?: false,
          # Not even registered yet, so it cannot have history.
          history?: false,
          checked?: value in picks,
          input_per_m: input,
          output_per_m: output,
          context_length: Map.get(entry, :context_length),
          created: Map.get(entry, :created)
        }
      end)

    (project ++ catalog)
    |> Enum.filter(&matches?(&1, query))
    |> sort_rows(assigns.model_sort)
  end

  # Pricing is read with **the same rule** as the screen, whether from a project model (string keys)
  # or the catalog (atom keys): values `price_label/1` shows as `—` (negative, non-numeric) must be
  # "unknown" for sorting too.
  defp rates(pricing) do
    pricing = Params.stringify_keys(pricing)
    {price_rate(pricing["input_per_m"]), price_rate(pricing["output_per_m"])}
  end

  # Relevance is the grouped order used so far (project catalog first, then OpenRouter). The other
  # three **interleave** both sources into one list: sorting by price while keeping the sources
  # apart makes the comparison a lie. `Enum.sort_by` is stable, so rows with equal values keep
  # their Relevance order.
  defp sort_rows(rows, "cheapest"),
    do: Enum.sort_by(rows, &{ascending(&1.input_per_m), ascending(&1.output_per_m)})

  defp sort_rows(rows, "newest"), do: Enum.sort_by(rows, &descending(&1.created))
  defp sort_rows(rows, "context"), do: Enum.sort_by(rows, &descending(&1.context_length))
  defp sort_rows(rows, _relevance), do: rows

  # Unknown values go **last, always**: the key's leading element (0/1) pushes `nil` behind the
  # numbers.
  defp ascending(nil), do: {1, 0}
  defp ascending(value), do: {0, value}

  defp descending(nil), do: {1, 0}
  defp descending(value), do: {0, -value}

  # The sort is held by the URL too: the segments are patch links, not events. The default
  # (relevance) omits the parameter entirely to keep the URL clean (`editor_path/2` drops nil
  # values).
  defp picker_sort_options(assigns) do
    Enum.map(@model_sorts, fn sort ->
      %{
        value: sort,
        label: @sort_labels[sort],
        active?: assigns.model_sort == sort,
        patch:
          editor_path(assigns,
            v: assigns.selected_number,
            models: 1,
            msort: if(sort != hd(@model_sorts), do: sort)
          )
      }
    end)
  end

  defp matches?(_row, ""), do: true

  defp matches?(row, query) do
    String.contains?(String.downcase(row.name), query) or
      String.contains?(String.downcase(row.model_id), query)
  end

  defp safe_dom_id(value),
    do: value |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")

  # ---------------------------------------------------------------------------
  # Arena (persistent history)

  defp load_arena(socket) do
    history =
      case Prompts.arena_messages_for_use_case(socket.assigns.use_case.id, scope(socket)) do
        {:ok, messages} -> Enum.group_by(messages, & &1.model_id, &arena_row/1)
        {:error, _error} -> %{}
      end

    socket |> assign(:arena_history, history) |> assign_arena_models()
  end

  defp arena_row(message) do
    %{
      key: message.id,
      role: message.role,
      content: message.content,
      status: message.status,
      error: message.error_message,
      version: message.prompt_version_number,
      at: message.inserted_at,
      latency_ms: message.latency_ms,
      cost_usd: message.cost_usd,
      input_tokens: message.input_tokens,
      output_tokens: message.output_tokens
    }
  end

  # Columns = **the selected models, exactly** (`arena_model_ids`, in selected order). If a column
  # stood merely because history exists, the chip's x would be a button that does nothing:
  # removing hides it, picking again brings it back (with its history). The history itself holds
  # the whole use case in `arena_history`, so it is neither cleared nor re-read.
  defp assign_arena_models(socket) do
    index = socket.assigns.model_index

    models =
      (socket.assigns.use_case.arena_model_ids || [])
      |> Enum.map(&Map.get(index, &1))
      |> Enum.reject(&is_nil/1)

    assign(socket, :arena_models, models)
  end

  # Models with at least one history row (including models removed from the columns; the history
  # is read for the whole use case).
  defp history_model_ids(assigns) do
    for {id, rows} <- assigns.arena_history, rows != [], into: MapSet.new(), do: id
  end

  defp any_history?(assigns),
    do: Enum.any?(assigns.arena_history, fn {_id, rows} -> rows != [] end)

  defp arena_variable_rows(assigns) do
    Enum.map(assigns.declared, fn variable ->
      %{
        name: variable.name,
        type: variable.type,
        required?: variable.required?,
        value: Map.get(assigns.arena_vars, variable.name, "")
      }
    end)
  end

  defp arena_missing(assigns),
    do: EditorTestRun.missing_required(assigns.declared, assigns.arena_vars)

  # `kind :text` is one-shot, so each cell shows **only the last output** (the history still
  # accumulates).
  defp arena_columns(assigns) do
    Enum.map(assigns.arena_models, fn model ->
      rows = Map.get(assigns.arena_history, model.id, [])

      %{
        id: model.id,
        label: model.display_name,
        model_id: model.model_id,
        price: known_price(model_pricing(assigns.catalog_prices, model)),
        rows: visible_rows(assigns.use_case.kind, rows),
        running?: Map.has_key?(assigns.arena_running, model.id)
      }
    end)
  end

  # The pricing in an arena column header appears **only when known**: the cell is narrow, so a
  # `—` line is noise (the place to check unknown pricing is the picker).
  defp known_price(pricing) do
    case price_label(pricing) do
      "—" -> nil
      label -> label
    end
  end

  defp visible_rows(:text, rows) do
    case Enum.reverse(rows) do
      [last | _rest] -> [last]
      [] -> []
    end
  end

  defp visible_rows(_kind, rows), do: rows

  defp arena_running?(assigns), do: assigns.arena_running != %{}

  defp arena_blocker(assigns) do
    cond do
      assigns.arena_models == [] ->
        "Add a model to run this prompt."

      arena_missing(assigns) != [] ->
        "Fill in required variables: #{Enum.join(arena_missing(assigns), ", ")}"

      is_nil(assigns.provider_key) ->
        "No provider key — add one in Organization settings."

      true ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Events: prompt

  # The single door every edit event passes through: swap the buffer and write it as the draft
  # right there (there is no save button).
  @impl Phoenix.LiveView
  def handle_event("validate", %{"editor" => editor}, socket) do
    {:noreply, put_buffer(socket, decode_messages(editor["messages"], socket.assigns.messages))}
  end

  def handle_event("add_message", _params, socket) do
    {:noreply, put_buffer(socket, socket.assigns.messages ++ [%{role: "user", content: ""}])}
  end

  def handle_event("remove_message", %{"index" => raw}, socket) do
    index = parse_int(raw, 0)
    messages = socket.assigns.messages

    if index && length(messages) > 1 do
      {:noreply, put_buffer(socket, List.delete_at(messages, index))}
    else
      {:noreply, socket}
    end
  end

  # The preview's only write action: **overwrite the draft** with that version's content and return
  # to draft editing. No new version is born (only Deploy creates versions).
  def handle_event("restore_version", _params, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      version ->
        socket =
          socket
          |> assign(
            selected: nil,
            selected_number: nil,
            messages: version_messages(socket.assigns.use_case, version),
            engine: version.engine,
            lint_error: nil
          )
          |> maybe_notice()
          |> assign_detection()
          |> write_draft()

        {:noreply,
         socket
         |> put_flash(:info, "Restored v#{version.number} to the draft.")
         |> push_patch(to: editor_path(socket.assigns, []))}
    end
  end

  def handle_event("prompt_change", %{"prompt" => params}, socket) do
    {:noreply,
     assign(socket,
       prompt_name: Map.get(params, "name", socket.assigns.prompt_name),
       prompt_description: Map.get(params, "description", socket.assigns.prompt_description)
     )}
  end

  # On rejection, only a flash is shown and the modal stays (`?new_prompt=1` remains in the URL).
  def handle_event("create_prompt", %{"prompt" => params}, socket) do
    name = String.trim(Map.get(params, "name") || "")
    description = blank_to_nil(Map.get(params, "description") || "")

    case open_prompt(socket, name, description) do
      {:ok, prompt} ->
        socket = socket |> load_prompts() |> assign(prompt_name: "", prompt_description: "")

        {:noreply,
         socket
         |> put_flash(:info, "Prompt #{prompt.name} created — write its first version.")
         |> push_patch(to: editor_path(socket.assigns, prompt: prompt.name))}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(
           prompt_name: Map.get(params, "name") || "",
           prompt_description: Map.get(params, "description") || ""
         )
         |> put_flash(:error, message)}
    end
  end

  # One click = one declaration. It starts as type `string`, optional.
  def handle_event("declare_variable", %{"name" => name}, socket) do
    {:noreply, declare_variables(socket, [name])}
  end

  def handle_event("declare_all_variables", _params, socket) do
    {:noreply, declare_variables(socket, socket.assigns.undeclared)}
  end

  def handle_event("variable_change", %{"variable" => params}, socket) do
    declared = socket.assigns.declared
    name = Map.get(params, "name")

    case Enum.find(declared, &(&1.name == name)) do
      nil ->
        {:noreply, socket}

      current ->
        updated = variable_params(current, params)

        if updated == variable_map(current) do
          {:noreply, socket}
        else
          schema = Enum.map(declared, &if(&1.name == name, do: updated, else: variable_map(&1)))
          {:noreply, unwrap(write_schema(socket, schema))}
        end
    end
  end

  def handle_event("remove_variable", %{"name" => name}, socket) do
    declared = socket.assigns.declared

    if Enum.any?(declared, &(&1.name == name)) do
      schema = declared |> Enum.reject(&(&1.name == name)) |> schema_maps()
      {:noreply, unwrap(write_schema(socket, schema))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_variable_change", %{"variable" => params}, socket) do
    {:noreply, assign(socket, :new_variable, Map.get(params, "name") || "")}
  end

  def handle_event("add_variable", %{"variable" => params}, socket) do
    name = String.trim(Map.get(params, "name") || "")

    case add_variable(socket, name) do
      {:ok, socket} ->
        {:noreply,
         socket
         |> assign(:new_variable, "")
         |> put_flash(:info, "Declared #{name}")}

      {:error, socket} ->
        {:noreply, assign(socket, :new_variable, name)}
    end
  end

  # ---------------------------------------------------------------------------
  # Events: model picker

  def handle_event("model_search", params, socket) do
    {:noreply, assign(socket, :model_query, get_in(params, ["picker", "q"]) || "")}
  end

  def handle_event("toggle_model_pick", %{"pick" => value}, socket) do
    picks = socket.assigns.model_picks

    picks = if value in picks, do: List.delete(picks, value), else: picks ++ [value]

    {:noreply, assign(socket, :model_picks, picks)}
  end

  def handle_event("retry_model_catalog", _params, socket) do
    {:noreply, start_catalog(socket)}
  end

  # A model picked from the catalog (`catalog:<model-id>`) is registered in the project catalog
  # **the moment it is added**: deferring it would leave the Deploy modal unable to point at "the
  # model in the arena".
  def handle_event("add_models", _params, socket) do
    {:noreply, add_picked_models(socket)}
  end

  def handle_event("remove_arena_model", %{"model" => id}, socket) do
    pinned = Enum.reject(socket.assigns.use_case.arena_model_ids || [], &(&1 == id))

    case Prompts.set_use_case_arena_models(
           socket.assigns.use_case,
           %{arena_model_ids: pinned},
           scope(socket)
         ) do
      {:ok, use_case} ->
        {:noreply, socket |> assign(:use_case, use_case) |> assign_arena_models()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  # ---------------------------------------------------------------------------
  # Events: arena

  def handle_event("arena_vars_change", params, socket) do
    {:noreply, update(socket, :arena_vars, &Map.merge(&1, params["vars"] || %{}))}
  end

  def handle_event("arena_input_change", params, socket) do
    {:noreply, assign(socket, :arena_input, get_in(params, ["send", "input"]) || "")}
  end

  def handle_event("arena_send", params, socket) do
    input = String.trim(get_in(params, ["send", "input"]) || socket.assigns.arena_input || "")

    case ensure_runnable(socket) do
      :ok -> {:noreply, dispatch_arena(socket, input)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("clear_column", %{"model" => id}, socket) do
    case Prompts.clear_arena(socket.assigns.use_case.id, %{model_id: id}, scope(socket)) do
      %Ash.BulkResult{status: :success} ->
        {:noreply,
         socket
         |> update(:arena_history, &Map.delete(&1, id))
         |> assign(:arena_notice, nil)
         |> assign_arena_models()}

      _other ->
        {:noreply, put_flash(socket, :error, "Could not clear this column.")}
    end
  end

  def handle_event("clear_arena", _params, socket) do
    case Prompts.clear_arena(socket.assigns.use_case.id, scope(socket)) do
      %Ash.BulkResult{status: :success} ->
        {:noreply,
         socket
         |> assign(arena_history: %{}, arena_notice: nil)
         |> assign_arena_models()
         |> put_flash(:info, "Arena history cleared.")}

      _other ->
        {:noreply, put_flash(socket, :error, "Could not clear the history.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Events: Deploy

  def handle_event("deploy_change", params, socket) do
    deploy = Map.get(params, "deploy", %{})

    {:noreply,
     assign(socket,
       deploy_env_id: Map.get(deploy, "environment") || socket.assigns.deploy_env_id,
       deploy_model_id: Map.get(deploy, "model") || socket.assigns.deploy_model_id,
       deploy_version_id: Map.get(deploy, "version") || socket.assigns.deploy_version_id,
       deploy_message: Map.get(deploy, "message") || socket.assigns.deploy_message
     )}
  end

  # The screen's **only write verb**. If needed, a version is born (minted) here, and a revision is
  # committed right after.
  def handle_event("deploy", params, socket) do
    deploy = Map.get(params, "deploy", %{})
    env_id = Map.get(deploy, "environment") || socket.assigns.deploy_env_id
    model_id = Map.get(deploy, "model") || socket.assigns.deploy_model_id
    version_id = Map.get(deploy, "version") || socket.assigns.deploy_version_id
    message = Map.get(deploy, "message") || socket.assigns.deploy_message

    with {:ok, env} <- deploy_environment(socket, env_id),
         {:ok, model} <- deploy_model(socket, model_id),
         {:ok, socket, version, minted?} <- deploy_version(socket, version_id, env, message),
         {:ok, deployment} <- commit_deployment(socket, env, model, version && version.id) do
      socket =
        socket
        |> assign(:prompt_versions, nil)
        |> load_deployments()
        |> load_dep_history(true)
        |> put_flash(:info, deploy_flash(if(minted?, do: version), deployment, env))

      {:noreply, push_patch(socket, to: after_deploy_path(socket.assigns))}
    else
      {:error, {:lint, message}} ->
        {:noreply, socket |> assign(:lint_error, message) |> put_flash(:error, message)}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, ErrorText.message(error))}
    end
  end

  # ---------------------------------------------------------------------------
  # Events: AI draft

  def handle_event("ai_change", %{"ai" => %{"instruction" => instruction}}, socket) do
    {:noreply, assign(socket, :ai_instruction, instruction)}
  end

  def handle_event("ai_suggest", %{"text" => text}, socket) do
    {:noreply, assign(socket, :ai_instruction, text)}
  end

  def handle_event("ai_generate", _params, socket) do
    case is_integer(socket.assigns.ai_index) &&
           Enum.at(socket.assigns.messages, socket.assigns.ai_index) do
      message when not is_map(message) ->
        {:noreply, socket}

      message ->
        request = ai_request(socket.assigns, message)
        organization_id = socket.assigns.project.organization_id

        {:noreply,
         socket
         |> assign(ai_stage: :running, ai_result: nil, ai_error: nil)
         |> start_async({:ai_draft, socket.assigns.ai_index}, fn ->
           PromptOn.LLM.complete(request, organization_id: organization_id)
         end)}
    end
  end

  def handle_event("ai_replace", _params, socket) do
    %{ai_index: index, ai_result: result, messages: messages} = socket.assigns

    if is_integer(index) and is_binary(result) do
      messages = List.update_at(messages, index, &Map.put(&1, :content, result))

      socket = put_buffer(socket, messages)

      {:noreply,
       socket
       |> put_flash(:info, "Message replaced with AI draft")
       |> push_patch(to: editor_path(socket.assigns, v: socket.assigns.selected_number))}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Events: Deployments tab (rollback)

  def handle_event("rollback", %{"id" => id}, socket) do
    source = Enum.find(socket.assigns.dep_history, &(&1.id == id))

    case Deployments.rollback_deployment(id, %{}, scope(socket)) do
      {:ok, deployment} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Rolled back to #{num(source && source.revision)} — now #{num(deployment.revision)}"
         )
         |> load_deployments()
         |> load_dep_history(true)
         |> push_patch(to: dep_path(socket.assigns, %{"confirm" => nil, "rev" => nil}))}

      {:error, error} ->
        {:noreply,
         socket
         |> put_flash(:error, ErrorText.message(error))
         |> push_patch(to: dep_path(socket.assigns, %{"confirm" => nil}))}
    end
  end

  # ---------------------------------------------------------------------------
  # Messages

  # The Evals tab polls its own runs while a batch is in flight (ADR 0010 §5.3). The timer lives in
  # the LiveView process, so the tick lands here and is handed straight back to the component.
  @impl Phoenix.LiveView
  def handle_info({:evals_refresh, id}, socket) do
    send_update(PromptOnWeb.EvalsPanel, id: id, refresh: :runs)
    {:noreply, socket}
  end

  # The Evals panel is a LiveComponent, and a component's flash only reaches this tray when it also
  # navigates. It therefore hands its messages over instead of putting them itself.
  def handle_info({:evals_flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  # ---------------------------------------------------------------------------
  # Async

  # The task key carries **which message the draft is for**: moving to another message's modal
  # while generating would let the earlier result arrive late and attach to the wrong message. A
  # result that is not for the message currently open is discarded.
  @impl Phoenix.LiveView
  def handle_async({:ai_draft, index}, result, socket) do
    if index == socket.assigns.ai_index do
      {:noreply, apply_ai_result(socket, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:arena, model_id}, {:ok, result}, socket) do
    record_arena_run(result)
    {:noreply, socket |> append_assistant(model_id, result) |> finish_run(model_id)}
  end

  def handle_async({:arena, model_id}, {:exit, reason}, socket) do
    result = %{status: :error, message: "Run was interrupted: #{inspect(reason)}"}
    {:noreply, socket |> append_assistant(model_id, result) |> finish_run(model_id)}
  end

  # A catalog lookup failure ends as one line in the picker plus Retry: the arena runs on project
  # models alone.
  def handle_async(:model_catalog, {:ok, {:ok, models}}, socket) do
    socket =
      socket
      |> assign(
        model_catalog: models,
        catalog_prices: catalog_price_index(models),
        catalog_state: :loaded
      )
      |> backfill_pricing()

    {:noreply, socket}
  end

  def handle_async(:model_catalog, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, :catalog_state, {:error, reason})}
  end

  def handle_async(:model_catalog, {:exit, reason}, socket) do
    {:noreply, assign(socket, :catalog_state, {:error, "request stopped (#{inspect(reason)})"})}
  end

  defp apply_ai_result(socket, {:ok, {:ok, %{content: content}}})
       when is_binary(content) and content != "" do
    assign(socket, ai_stage: :done, ai_result: String.trim(content))
  end

  defp apply_ai_result(socket, {:ok, {:ok, _outcome}}) do
    assign(socket, ai_stage: :error, ai_error: "The model returned an empty response.")
  end

  defp apply_ai_result(socket, {:ok, {:error, :no_provider_key}}) do
    assign(socket, ai_stage: :no_key, ai_error: nil)
  end

  defp apply_ai_result(socket, {:ok, {:error, reason}}) do
    assign(socket, ai_stage: :error, ai_error: "Model call failed: #{inspect(reason)}")
  end

  defp apply_ai_result(socket, {:exit, reason}) do
    assign(socket, ai_stage: :error, ai_error: "Model call was interrupted: #{inspect(reason)}")
  end

  defp decode_messages(params, current) when is_map(params) do
    params
    |> Enum.map(fn {index, fields} -> {parse_int(index, 0), fields} end)
    |> Enum.reject(fn {index, _fields} -> is_nil(index) end)
    |> Enum.sort_by(fn {index, _fields} -> index end)
    |> Enum.map(fn {index, fields} ->
      fallback = Enum.at(current, index) || %{role: "user", content: ""}

      %{
        role: Map.get(fields, "role") || fallback.role,
        content: Map.get(fields, "content") || fallback.content
      }
    end)
    |> case do
      [] -> current
      messages -> messages
    end
  end

  defp decode_messages(_params, current), do: current

  # ---------------------------------------------------------------------------
  # Version minting (only Deploy calls it)

  # Is the draft equal to the latest commit? If so, that version; if not (or with no version),
  # `nil`. This one function answers three places: whether to mint, the Deploy modal's draft
  # label, and the arena's version number.
  defp clean_version(assigns) do
    case List.first(assigns.versions) do
      nil -> nil
      latest -> if latest.content_sha256 == draft_hash(assigns), do: latest, else: nil
    end
  end

  # Hashed with **the same code** as the saved version (`Changes.ComputeDerived` uses this function
  # too).
  defp draft_hash(assigns) do
    attrs = content_attrs(assigns.use_case, assigns.messages)

    PromptVersion.content_hash(
      assigns.engine,
      Map.get(attrs, :messages, []),
      Map.get(attrs, :text_template)
    )
  end

  defp mint_version(socket, message) do
    attrs =
      socket.assigns.use_case
      |> content_attrs(socket.assigns.messages)
      |> Map.merge(%{
        prompt_id: socket.assigns.prompt.id,
        engine: socket.assigns.engine,
        commit_message: message
      })

    case Prompts.commit_prompt_version(attrs, scope(socket)) do
      {:ok, version} ->
        {:ok, socket |> load_versions() |> assign_version_numbers(), version, true}

      {:error, error} ->
        {:error, {:lint, ErrorText.message(error)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Deploy = (mint if needed →) commit a revision

  defp deploy_environment(socket, id) do
    case Enum.find(socket.assigns.envs, &(&1.id == id)) do
      nil -> {:error, "Pick an environment to deploy to."}
      env -> {:ok, env}
    end
  end

  defp deploy_model(socket, id) do
    case Enum.find(socket.assigns.models, &(&1.id == id)) do
      nil -> {:error, "Pick a model to deploy."}
      model -> {:ok, model}
    end
  end

  # An embedding use case's target has no prompt version (model only); `Committable` requires it
  # that way.
  defp deploy_version(%{assigns: %{use_case: %{kind: :embedding}}} = socket, _id, _env, _message),
    do: {:ok, socket, nil, false}

  # "Current draft": v(N+1) is minted **only when** the draft differs from the latest commit.
  # Otherwise that version is reused (no two versions with the same content). A blank commit
  # message simply records the deployment.
  defp deploy_version(%{assigns: %{prompt: nil}}, @draft_option, _env, _message),
    do: {:error, "This use case has no prompt to deploy."}

  defp deploy_version(socket, @draft_option, env, message) do
    case clean_version(socket.assigns) do
      nil -> mint_version(socket, blank_to_nil(message) || "Deployed to #{env.slug}")
      version -> {:ok, socket, version, false}
    end
  end

  defp deploy_version(socket, id, _env, _message) do
    case Enum.find(socket.assigns.versions, &(&1.id == id)) do
      nil -> {:error, "Pick a version to deploy."}
      version -> {:ok, socket, version, false}
    end
  end

  # Deploying from the Deployments tab stays on that tab (the environment being viewed too):
  # someone who came to see the revision just committed is not pushed to the Editor tab. `rev` is
  # dropped so the new live revision is picked up.
  defp after_deploy_path(%{tab: "deployments"} = assigns),
    do: dep_path(assigns, %{"rev" => nil, "deploy" => nil, "confirm" => nil})

  defp after_deploy_path(assigns), do: editor_path(assigns, v: assigns.selected_number)

  # The links that open and close the Deploy modal know the tab too: opened from the Deployments
  # tab, the **environment** being viewed must be kept, or "looking at staging, deployed to
  # production" accidents happen (`editor_path` does not carry `env`).
  defp deploy_open_path(%{tab: "deployments"} = assigns),
    do: dep_path(assigns, %{"deploy" => "1"})

  defp deploy_open_path(assigns),
    do: editor_path(assigns, v: assigns.selected_number, deploy: 1)

  defp deploy_close_path(%{tab: "deployments"} = assigns),
    do: dep_path(assigns, %{"deploy" => nil})

  defp deploy_close_path(assigns), do: editor_path(assigns, v: assigns.selected_number)

  # After minting, both facts go in one line: what was born, and what was deployed where.
  defp deploy_flash(nil, deployment, env),
    do: "Deployed revision ##{deployment.revision} to #{env.slug}."

  defp deploy_flash(version, deployment, env),
    do: "v#{version.number} created — deployed revision ##{deployment.revision} to #{env.slug}."

  # A revision is **one pin** (ADR 0007 revision 2026-09-01): one chosen model plus a map pinning
  # this use case's prompts by name. Deploy pins **every committed prompt**: only the prompt being
  # edited gets the version chosen in the modal (or just minted); the rest get their own latest
  # version. A prompt with no version at all has nothing to pin and is left out (a request for
  # that name is a 404, which is how a missed deployment surfaces).
  defp commit_deployment(socket, env, model, version_id) do
    Deployments.commit_deployment(
      %{
        use_case_id: socket.assigns.use_case.id,
        environment_id: env.id,
        model_id: model.id,
        prompt_pins: deploy_pins(socket.assigns, version_id)
      },
      scope(socket)
    )
  end

  @doc false
  # Name → version id. `current_version_id` is the version to pin for the prompt being edited
  # (including a minting result).
  @spec deploy_pins(map(), Ash.UUID.t() | nil) :: %{String.t() => Ash.UUID.t()}
  def deploy_pins(%{use_case: %{kind: :embedding}}, _current_version_id), do: %{}

  def deploy_pins(assigns, current_version_id) do
    current_id = current_prompt_id(assigns.prompt)

    assigns.prompts
    |> Enum.map(fn prompt ->
      version_id =
        if prompt.id == current_id,
          do: current_version_id,
          else: latest_version_id(assigns, prompt)

      {prompt.name, version_id}
    end)
    |> Enum.reject(fn {_name, version_id} -> is_nil(version_id) end)
    |> Map.new()
  end

  defp latest_version_id(assigns, prompt) do
    case assigns.prompt_versions |> Kernel.||(%{}) |> Map.get(prompt.id) do
      [%{id: id} | _rest] -> id
      _none -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Arena runs

  defp ensure_runnable(socket) do
    case arena_blocker(socket.assigns) do
      nil -> if arena_running?(socket.assigns), do: {:error, "Still running — wait."}, else: :ok
      message -> {:error, message}
    end
  end

  defp dispatch_arena(socket, input) do
    if socket.assigns.use_case.kind == :chat and input == "" do
      put_flash(socket, :error, "Write a message to send.")
    else
      variables = EditorTestRun.cast_variables(socket.assigns.declared, socket.assigns.arena_vars)
      socket = assign(socket, arena_notice: nil, arena_input: "")

      Enum.reduce(
        socket.assigns.arena_models,
        socket,
        &start_arena_column(&2, &1, variables, input)
      )
    end
  end

  # One cell = one model. The request is *the rendered buffer* ++ *that cell's last 30 turns* ++
  # *the new user turn*, so cells never mix. The user turn is kept as **one row per model** (each
  # column is an independent conversation, so it can be cleared separately).
  defp start_arena_column(socket, model, variables, input) do
    chat? = socket.assigns.use_case.kind == :chat
    prior = EditorTestRun.context_turns(Map.get(socket.assigns.arena_history, model.id, []))
    turns = if chat?, do: prior ++ [%{role: "user", content: input}], else: []

    # The version is stamped **only when the draft is literally equal** to the latest commit: an
    # edited draft has no version to point at.
    version = clean_version(socket.assigns)
    number = version && version.number
    params = if chat?, do: %{}, else: %{"variables" => stringify(variables)}

    socket =
      if chat? do
        append_arena(socket, model.id, %{
          role: :user,
          content: input,
          author_id: author_id(socket)
        })
      else
        socket
      end

    context = %{
      project: socket.assigns.project,
      use_case: socket.assigns.use_case,
      model: model,
      buffer: socket.assigns.messages,
      engine: socket.assigns.engine,
      prompt_version_id: version && version.id,
      variables: variables,
      turns: turns
    }

    socket
    |> update(:arena_running, &Map.put(&1, model.id, %{version_number: number, params: params}))
    |> start_async({:arena, model.id}, fn -> EditorTestRun.run(context) end)
  end

  defp author_id(socket) do
    case socket.assigns.current_user do
      %{id: id} -> id
      _other -> nil
    end
  end

  # The variable map goes into jsonb, so keys are fixed as strings (atom keys come back as strings
  # anyway).
  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(other), do: other

  defp append_assistant(socket, model_id, result) do
    meta = Map.get(socket.assigns.arena_running, model_id, %{})

    attrs =
      %{
        role: :assistant,
        prompt_version_number: Map.get(meta, :version_number),
        params: Map.get(meta, :params) || %{},
        author_id: author_id(socket)
      }
      |> Map.merge(assistant_outcome(result))

    append_arena(socket, model_id, attrs)
  end

  defp assistant_outcome(%{status: :ok, outcome: outcome}) do
    %{
      content: outcome.content || "",
      status: :ok,
      latency_ms: outcome.latency_ms,
      input_tokens: outcome.usage[:input_tokens],
      output_tokens: outcome.usage[:output_tokens],
      cost_usd: decimal(outcome.cost_usd)
    }
  end

  defp assistant_outcome(%{status: :error} = result) do
    %{content: "", status: :error, error_message: result.message}
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)

  # The history is an append-only table: what cannot be written is not shown on screen either (no
  # pretending).
  defp append_arena(socket, model_id, attrs) do
    attrs =
      Map.merge(attrs, %{use_case_id: socket.assigns.use_case.id, model_id: model_id})

    case Prompts.append_arena_message(attrs, scope(socket)) do
      {:ok, message} ->
        update(socket, :arena_history, fn history ->
          Map.update(history, model_id, [arena_row(message)], &(&1 ++ [arena_row(message)]))
        end)

      {:error, error} ->
        put_flash(socket, :error, ErrorText.message(error))
    end
  end

  defp finish_run(socket, model_id),
    do: update(socket, :arena_running, &Map.delete(&1, model_id))

  # Recording uses the **dispatch-time context** (`EditorTestRun.run/1` carries it in the result):
  # rebuilding it from the assigns after completion would lose the (already billed) call of a user
  # who edited the buffer mid-run.
  defp record_arena_run(%{context: context} = result) when is_map(context),
    do: EditorTestRun.record(context, result)

  defp record_arena_run(_result), do: :ok

  # ---------------------------------------------------------------------------
  # Adding models (picker submit)

  defp add_picked_models(socket) do
    {socket, models, errors} =
      Enum.reduce(socket.assigns.model_picks, {socket, [], []}, fn pick, {socket, acc, errors} ->
        case resolve_pick(socket, pick) do
          {:ok, model} -> {socket, acc ++ [model], errors}
          {:error, message} -> {socket, acc, errors ++ [message]}
        end
      end)

    socket = if errors == [], do: socket, else: put_flash(socket, :error, Enum.join(errors, " "))

    if models == [] do
      socket
    else
      pin_models(socket, models)
    end
  end

  defp pin_models(socket, models) do
    ids =
      (socket.assigns.arena_models ++ models)
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    case Prompts.set_use_case_arena_models(
           socket.assigns.use_case,
           %{arena_model_ids: ids},
           scope(socket)
         ) do
      {:ok, use_case} ->
        socket
        |> assign(:use_case, use_case)
        |> load_models()
        |> assign_arena_models()
        |> assign(:model_picks, [])
        |> put_flash(:info, "Added #{length(models)} model(s) to the arena.")
        |> push_patch(to: editor_path(socket.assigns, v: socket.assigns.selected_number))

      {:error, error} ->
        put_flash(socket, :error, ErrorText.message(error))
    end
  end

  defp resolve_pick(socket, "catalog:" <> model_id) do
    case Enum.find(socket.assigns.model_catalog, &(&1.model_id == model_id)) do
      nil -> {:error, "#{model_id} is no longer in the openrouter catalog."}
      entry -> register_catalog_model(socket, entry)
    end
  end

  defp resolve_pick(socket, id) do
    case Enum.find(socket.assigns.models, &(&1.id == id)) do
      nil -> {:error, "That model is no longer available."}
      model -> {:ok, model}
    end
  end

  # A model picked from the catalog enters the project catalog right here (same fields as the
  # `models_live` import).
  defp register_catalog_model(socket, entry) do
    attrs = %{
      provider: :openrouter,
      model_id: entry.model_id,
      display_name: entry.display_name,
      context_length: entry.context_length,
      capabilities: entry.capabilities,
      pricing: catalog_pricing(Map.get(entry, :pricing))
    }

    case Catalog.register_model(attrs, scope(socket)) do
      {:ok, model} -> {:ok, model}
      {:error, error} -> registered_model(socket, entry.model_id, error)
    end
  rescue
    # If the same `(project, provider, model_id)` already exists, that model is used as is.
    _error -> registered_model(socket, entry.model_id, nil)
  end

  # The pricing OpenRouter reported is planted as is, so `Model.estimate_cost/3` fills ingest costs
  # from the moment of registration. An unknown side **gets no key** (`Validations.Pricing` allows
  # partial pricing, and a missing key means "unknown", not 0).
  defp catalog_pricing(pricing) when is_map(pricing) do
    rates =
      %{}
      |> put_rate("input_per_m", Map.get(pricing, :input_per_m))
      |> put_rate("output_per_m", Map.get(pricing, :output_per_m))

    if rates == %{}, do: %{}, else: Map.merge(rates, %{"currency" => "USD", "unit" => "token"})
  end

  defp catalog_pricing(_pricing), do: %{}

  defp put_rate(rates, key, rate) when is_number(rate) and rate >= 0,
    do: Map.put(rates, key, rate)

  defp put_rate(rates, _key, _rate), do: rates

  defp registered_model(socket, model_id, error) do
    case Catalog.get_model_by_provider_model(:openrouter, model_id, scope(socket)) do
      {:ok, %Catalog.Model{} = model} -> {:ok, model}
      _other -> {:error, (error && ErrorText.message(error)) || "Could not register #{model_id}."}
    end
  end

  defp content_attrs(%{kind: :text}, messages) do
    content =
      case messages do
        [%{content: content} | _rest] -> content
        _other -> ""
      end

    %{messages: [], text_template: content}
  end

  defp content_attrs(_use_case, messages) do
    %{messages: Enum.map(messages, &%{role: &1.role, content: &1.content})}
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp blank_to_nil(value), do: value

  # ---------------------------------------------------------------------------
  # Deployments tab (this use case's rules, history, rollback)

  defp apply_deployments_tab(%{assigns: %{tab: "deployments"}} = socket, params) do
    socket
    |> assign(dep_env: dep_env_param(socket, params), dep_confirm: params["confirm"])
    |> ensure_prompt_versions()
    |> load_dep_history()
    |> assign_dep_revision(params["rev"])
    |> load_dep_scores()
  end

  defp apply_deployments_tab(socket, _params), do: assign(socket, :dep_confirm, nil)

  # The evaluated average of every revision on screen, in **one** query (ADR 0010 §2.7): the score
  # is a relationship, never a column on `Deployment`, so `PromptOn.Deployments` does not learn
  # that `PromptOn.Evals` exists. A revision nobody evaluated is simply missing from the map, and
  # the badge then renders nothing.
  defp load_dep_scores(socket) do
    ids = Enum.map(socket.assigns.dep_history, & &1.id)
    assign(socket, :dep_scores, PromptOn.Evals.scores_for_deployments(ids, scope(socket)))
  end

  defp dep_env_param(socket, %{"env" => slug}),
    do: Enum.find(socket.assigns.envs, &(&1.slug == slug)) || default_dep_env(socket)

  defp dep_env_param(socket, _params), do: default_dep_env(socket)

  defp default_dep_env(socket) do
    Enum.find(socket.assigns.envs, &(&1.slug == "production")) || List.first(socket.assigns.envs)
  end

  defp load_dep_history(socket, force? \\ false)

  defp load_dep_history(%{assigns: %{dep_env: nil}} = socket, _force?),
    do: assign(socket, dep_history: [], dep_live: nil, dep_key: nil)

  defp load_dep_history(socket, force?) do
    key = {socket.assigns.use_case.id, socket.assigns.dep_env.id}

    if not force? and socket.assigns.dep_key == key do
      socket
    else
      history =
        case Deployments.deployment_history(
               socket.assigns.use_case.id,
               socket.assigns.dep_env.id,
               scope(socket)
             ) do
          {:ok, list} -> list
          {:error, _error} -> []
        end

      socket
      |> assign(dep_history: history, dep_live: List.first(history), dep_key: key)
      |> assign_indexes(history)
    end
  end

  # The committed version list (newest first) for each prompt of this use case. Two places use it:
  # pin labels (`version_index`) and **what Deploy will pin** (every prompt's latest version). Not
  # a hot path, so it is read once when needed.
  defp ensure_prompt_versions(%{assigns: %{prompt_versions: nil}} = socket),
    do: load_prompt_versions(socket)

  defp ensure_prompt_versions(socket), do: socket

  defp load_prompt_versions(socket) do
    opts = scope(socket)

    versions =
      Map.new(socket.assigns.prompts, fn prompt ->
        case Prompts.list_prompt_versions(prompt.id, opts) do
          {:ok, list} -> {prompt.id, Enum.sort_by(list, & &1.number, :desc)}
          {:error, _error} -> {prompt.id, []}
        end
      end)

    socket
    |> assign(:prompt_versions, versions)
    |> assign(:version_index, merge_version_index(socket, versions))
  end

  defp merge_version_index(socket, versions) do
    names = Map.new(socket.assigns.prompts, &{&1.id, &1.name})

    entries =
      versions
      |> Enum.flat_map(fn {_prompt_id, list} -> list end)
      |> Map.new(fn version ->
        {version.id,
         %{
           id: version.id,
           number: version.number,
           prompt_id: version.prompt_id,
           prompt_name: Map.get(names, version.prompt_id, "?")
         }}
      end)

    Map.merge(socket.assigns.version_index, entries)
  end

  # The version a past revision points at may belong to another prompt of this use case (or an
  # archived one); only ids missing from the list are fetched one by one.
  defp assign_indexes(socket, deployments) do
    ids =
      deployments
      |> Enum.flat_map(&Deployment.prompt_version_ids/1)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(socket.assigns.version_index, &1))

    index =
      Enum.reduce(ids, socket.assigns.version_index, fn id, acc ->
        case Prompts.get_prompt_version(id, Keyword.put(scope(socket), :load, [:prompt])) do
          {:ok, version} ->
            Map.put(acc, id, %{
              id: version.id,
              number: version.number,
              prompt_id: version.prompt_id,
              prompt_name: (version.prompt && version.prompt.name) || "?"
            })

          _other ->
            acc
        end
      end)

    assign(socket, :version_index, index)
  end

  defp assign_dep_revision(socket, raw) do
    assign(socket, :dep_revision, pick_revision(socket.assigns.dep_history, raw))
  end

  defp pick_revision([], _raw), do: nil

  defp pick_revision([live | _rest] = history, raw) do
    case parse_int(raw) do
      nil -> live
      number -> Enum.find(history, &(&1.revision == number)) || live
    end
  end

  defp committer_label(%{committed_by: nil}, _user), do: "—"
  defp committer_label(%{committed_by: id}, %{id: id} = user), do: to_string(user.email)
  defp committer_label(%{committed_by: id}, _user), do: String.slice(to_string(id), 0, 8)

  defp live_revision?(%{id: id}, %{id: id}), do: true
  defp live_revision?(_deployment, _live), do: false

  defp next_revision(%{dep_live: %{revision: revision}}), do: revision + 1
  defp next_revision(_assigns), do: 1

  # ---------------------------------------------------------------------------
  # AI draft meta prompt

  defp ai_request(assigns, message) do
    %{
      model: @ai_model,
      messages: [
        %{role: "system", content: ai_system_prompt()},
        %{role: "user", content: ai_user_prompt(assigns, message)}
      ],
      params: %{},
      provider_options: %{}
    }
  end

  defp ai_system_prompt do
    """
    You are a prompt-engineering assistant. You rewrite exactly ONE message of a Liquid prompt template.

    Rules:
    1. Keep every Liquid variable and tag the message already uses ({{ var }}, {% if %}, {% for %}) unless the \
    instruction explicitly asks to change them. Never introduce a variable that is not declared.
    2. Only these Liquid tags are allowed: for, if, unless, assign, break, continue. Only these filters: \
    size, join, default. Whitespace control ({%- , -%}, {{- , -}}) is forbidden.
    3. Keep the message in the language it is written in unless told otherwise.
    4. Output ONLY the new message text. No markdown fences, no role label, no commentary.
    """
  end

  defp ai_user_prompt(assigns, message) do
    """
    use case: #{assigns.use_case.key} (kind: #{assigns.use_case.kind})

    declared variables:
    #{declared_lines(assigns.declared)}

    current #{message.role} message:
    ---
    #{message.content}
    ---

    instruction: #{blank_to_nil(assigns.ai_instruction) || "(none — improve it overall)"}
    """
  end

  defp declared_lines([]), do: "(none)"

  defp declared_lines(declared) do
    Enum.map_join(declared, "\n", fn variable ->
      required = if variable.required?, do: " (required)", else: ""
      "- #{variable.name}: #{variable.type}#{required}"
    end)
  end

  # ---------------------------------------------------------------------------
  # Paths and scope

  defp scope(%{assigns: assigns}),
    do: [tenant: assigns.project.id, actor: assigns.current_user]

  # The selected prompt and **the current tab** ride along on every editor link: if either is
  # missing, clicking that link snaps back to the default prompt (or the Editor tab). At the
  # default value the URL is kept clean. A caller's explicit `tab:`/`prompt:` wins
  # (`Keyword.put_new`).
  defp editor_path(assigns, params) do
    query =
      params
      |> Keyword.put_new(:tab, tab_param_value(assigns))
      |> Keyword.put_new(:prompt, prompt_param(assigns))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/#{assigns.org_slug}/#{assigns.project.slug}/use-cases/#{assigns.use_case.key}/prompt?#{query}"
  end

  defp tab_param_value(%{tab: tab}) when tab in @sticky_tabs, do: tab
  defp tab_param_value(_assigns), do: nil

  defp prompt_param(%{prompt: %{name: name}}) when name != "default", do: name
  defp prompt_param(_assigns), do: nil

  # Deployments tab links. The query is built as a list in **fixed order** (so one screen state
  # never becomes two strings).
  defp dep_path(assigns, overrides) do
    overrides = Map.new(overrides)

    query =
      [
        {"tab", "deployments"},
        {"env", (assigns.dep_env && assigns.dep_env.slug) || assigns.env_slug},
        {"rev", assigns.dep_revision && to_string(assigns.dep_revision.revision)},
        {"deploy", if(assigns.deploy?, do: "1")},
        {"confirm", assigns.dep_confirm}
      ]
      |> Enum.map(fn {key, value} -> {key, Map.get(overrides, key, value)} end)
      |> Enum.reject(fn {_key, value} -> value in [nil, "", false] end)

    ~p"/#{assigns.org_slug}/#{assigns.project.slug}/use-cases/#{assigns.use_case.key}/prompt?#{query}"
  end

  # ---------------------------------------------------------------------------
  # Render

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:roles, roles(assigns.use_case))
      |> assign(:sub, header_sub(assigns))
      |> assign(:draft_patch, editor_path(assigns, []))
      |> assign(:prompt_rows, prompt_rows(assigns))
      |> assign(
        :new_prompt_patch,
        editor_path(assigns, v: assigns.selected_number, new_prompt: 1)
      )
      |> assign(:live_versions, live_env_map(assigns))
      |> then(&assign(&1, :version_rows, version_rows(&1)))
      |> assign(:message_rows, message_rows(assigns))
      |> assign(:close_patch, editor_path(assigns, v: assigns.selected_number))
      |> assign(:picker_patch, editor_path(assigns, v: assigns.selected_number, models: 1))
      |> assign(:arena_full_patch, editor_path(assigns, v: assigns.selected_number, full: 1))
      |> assign(:arena_exit_patch, editor_path(assigns, v: assigns.selected_number))
      |> assign(:diff_target, diff_target(assigns))
      |> assign(:declared_rows, declared_rows(assigns))
      |> assign(:tab_rows, tab_rows(assigns))
      |> assign(:runnable?, assigns.use_case.kind != :embedding and assigns.prompt != nil)
      |> assign(:editable?, assigns.prompt != nil and assigns.use_case.kind != :embedding)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      org_slug={@org_slug}
      project={@project}
      projects={@projects}
      organization={@organization}
      organizations={@organizations}
      nav={:usecases}
    >
      <DS.screen
        id="use-case-hub"
        title={@use_case.key}
        title_mono
        sub={@sub}
        tabs={@tab_rows}
        active_tab={@tab}
        max_w={900}
      >
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <:crumb
          label={@project.slug}
          navigate={~p"/#{@org_slug}/#{@project.slug}/use-cases"}
        />
        <:crumb label={@use_case.key} />
        <:actions>
          <DS.badge id="kind-badge" tone={:neutral} mono>{@use_case.kind}</DS.badge>
          <DS.badge
            :if={@editable? and @selected == nil and @tab == "editor"}
            id="draft-badge"
            tone={:neutral}
            mono
            title="Every edit is saved automatically"
          >
            Editing draft
          </DS.badge>
          <DS.badge
            :if={@editable? and @selected != nil and @tab == "editor"}
            id="preview-badge"
            tone={:accent}
            mono
          >
            Viewing v{@selected_number}
          </DS.badge>
          <DS.btn_link
            :if={@use_case.kind != :embedding and @tab == "editor"}
            id="open-versions"
            size="sm"
            variant="ghost"
            icon="layers"
            patch={editor_path(assigns, v: @selected_number, versions: 1)}
          >
            {if @selected_number, do: "v#{@selected_number}", else: "History"}
          </DS.btn_link>
          <DS.btn_link
            id="open-deploy"
            variant="primary"
            icon="flag"
            patch={deploy_open_path(assigns)}
          >
            Deploy
          </DS.btn_link>
        </:actions>

        <div :if={@tab == "editor"} style="display:flex;flex-direction:column;gap:16px;min-width:0;">
          <.prompt_switcher :if={@prompts != []} rows={@prompt_rows} new_patch={@new_prompt_patch} />

          <DS.empty
            :if={@prompt == nil and @use_case.kind != :embedding}
            id="prompt-editor-empty"
            icon="code"
            title="No prompt"
            sub={"This #{@use_case.kind} use case has no prompt versions."}
          />

          <div
            :if={@use_case.kind == :embedding}
            id="embedding-note"
            style="font-size:13px;color:var(--tx-3);"
          >
            Embedding use cases have no prompt — pick a model and deploy it.
          </div>

          <div :if={@prompt} style="display:flex;flex-direction:column;gap:10px;min-width:0;">
            <%= cond do %>
              <% @diff_target -> %>
                <.diff_column
                  from_messages={version_messages(@use_case, @diff_target)}
                  to_messages={(@selected && version_messages(@use_case, @selected)) || @messages}
                  from_number={@diff_target.number}
                  to_label={if @selected_number, do: "v#{@selected_number}", else: "draft"}
                  close_patch={@close_patch}
                />
              <% @selected -> %>
                <.version_preview
                  number={@selected_number}
                  messages={version_messages(@use_case, @selected)}
                  commit_message={@selected.commit_message}
                  draft_patch={@draft_patch}
                />
              <% true -> %>
                <.schema_banner :if={@lint_error} id="lint-error" tone={:err} icon="alert">
                  {@lint_error}
                </.schema_banner>
                <.form
                  for={@form}
                  id="prompt-editor-form"
                  phx-change="validate"
                  style="display:flex;flex-direction:column;gap:10px;min-width:0;"
                >
                  <.message_card
                    :for={row <- @message_rows}
                    index={row.index}
                    message={row}
                    roles={@roles}
                    removable?={row.removable?}
                    ai_patch={row.ai_patch}
                  />
                  <DS.btn
                    :if={@use_case.kind != :text}
                    id="add-message"
                    variant="outline"
                    icon="plus"
                    type="button"
                    phx-click="add_message"
                    style="align-self:flex-start;"
                  >
                    Add message
                  </DS.btn>
                </.form>

                <.variables_card
                  detected={@detected}
                  rows={@declared_rows}
                  undeclared={@undeclared}
                  unused={@unused}
                  types={@var_types}
                  new_name={@new_variable}
                />
            <% end %>
          </div>
        </div>

        <div
          :if={@tab == "arena"}
          id="arena-tab"
          style="display:flex;flex-direction:column;gap:16px;min-width:0;"
        >
          <.arena_bar models={arena_model_rows(assigns)} add_patch={@picker_patch} />

          <div
            :if={@use_case.kind == :embedding}
            id="arena-embedding-note"
            style="font-size:13px;color:var(--tx-3);"
          >
            Embedding use cases have nothing to run — the models picked here are what Deploy
            chooses from.
          </div>

          <.arena
            :if={@runnable?}
            kind={@use_case.kind}
            columns={arena_columns(assigns)}
            add_patch={@picker_patch}
            variables={arena_variable_rows(assigns)}
            variables_open?={arena_missing(assigns) != []}
            input={@arena_input}
            running?={arena_running?(assigns)}
            blocked={arena_blocker(assigns)}
            notice={@arena_notice}
            any_history?={any_history?(assigns)}
            title={@use_case.key}
            full?={@arena_full?}
            full_patch={@arena_full_patch}
            exit_patch={@arena_exit_patch}
          />
        </div>

        <.deployments_tab :if={@tab == "deployments"} {assigns} />

        <.live_component
          :if={@tab == "evals"}
          module={PromptOnWeb.EvalsPanel}
          id="evals-panel"
          org_slug={@org_slug}
          project={@project}
          organization={@organization}
          use_case={@use_case}
          envs={@envs}
          current_user={@current_user}
          deployments={@deployments || %{}}
          params={@eval_params}
        />
      </DS.screen>

      <.versions_drawer
        :if={@versions_open? and @use_case.kind != :embedding}
        rows={@version_rows}
        draft_patch={@draft_patch}
        draft_selected?={@selected == nil}
        close_patch={@close_patch}
      />

      <.model_picker_modal
        :if={@picker_open?}
        query={@model_query}
        rows={picker_rows(assigns)}
        picks={@model_picks}
        sort_options={picker_sort_options(assigns)}
        catalog_state={@catalog_state}
        provider_key={@provider_key}
        truncated={picker_truncated(assigns)}
        close_patch={@close_patch}
        providers_path={~p"/#{@org_slug}/settings?#{[tab: "providers"]}"}
      />

      <.deploy_modal
        :if={@deploy?}
        envs={deploy_env_rows(assigns)}
        models={deploy_model_rows(assigns)}
        version_options={deploy_version_options(assigns)}
        version_value={@deploy_version_id}
        version_required?={@use_case.kind != :embedding}
        default_params={@use_case.default_params}
        pins={deploy_pin_rows(assigns)}
        deployments_patch={dep_path(assigns, %{})}
        message={@deploy_message}
        minting?={deploy_minting?(assigns)}
        close_patch={deploy_close_path(assigns)}
      />

      <.ai_draft_modal
        :if={@prompt && @selected == nil && ai_message(@messages, @ai_index)}
        stage={@ai_stage}
        role={ai_role(@messages, @ai_index)}
        current={ai_content(@messages, @ai_index)}
        instruction={@ai_instruction}
        result={@ai_result}
        error={@ai_error}
        close_patch={@close_patch}
        providers_path={~p"/#{@org_slug}/settings?#{[tab: "providers"]}"}
      />

      <.new_prompt_modal
        :if={@new_prompt?}
        name={@prompt_name}
        description={@prompt_description}
        close_patch={@close_patch}
      />

      <.rollback_modal :if={@tab == "deployments" and @dep_confirm} {assigns} />
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Deployments tab (render)

  defp deployments_tab(assigns) do
    assigns = assign(assigns, :integration, integration_spec(assigns))

    ~H"""
    <div id="deployments-tab" style="display:flex;flex-direction:column;gap:14px;min-width:0;">
      <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;">
        <span class="mono-label">Environment</span>
        <DS.seg
          id="dep-env-seg"
          value={@dep_env && @dep_env.slug}
          options={
            Enum.map(
              @envs,
              &%{
                value: &1.slug,
                label: &1.slug,
                patch: dep_path(assigns, %{"env" => &1.slug, "rev" => nil})
              }
            )
          }
        />
        <div style="margin-left:auto;">
          <DS.btn_link
            id="deploy-from-deployments"
            size="sm"
            variant="solid"
            icon="flag"
            patch={deploy_open_path(assigns)}
          >
            Deploy
          </DS.btn_link>
        </div>
      </div>

      <DS.empty
        :if={is_nil(@dep_revision)}
        id="no-deployment"
        icon="flag"
        title="Nothing deployed here"
        sub="Deploy pins one model and every committed prompt of this use case — it goes live the moment it is committed."
      >
        <:action>
          <DS.btn_link
            id="empty-deploy"
            variant="primary"
            icon="flag"
            patch={deploy_open_path(assigns)}
          >
            Deploy
          </DS.btn_link>
        </:action>
      </DS.empty>

      <.pin_card
        :if={@dep_revision}
        deployment={@dep_revision}
        model_index={@model_index}
        version_index={@version_index}
        live?={live_revision?(@dep_revision, @dep_live)}
        committer={committer_label(@dep_revision, @current_user)}
      >
        <:score_badge>
          <EvalsComponents.score_badge
            id="pin-score"
            run={Map.get(@dep_scores, @dep_revision.id)}
          />
        </:score_badge>
      </.pin_card>

      <div id="history" style="display:flex;flex-direction:column;gap:7px;">
        <span class="mono-label">Revisions</span>
        <div :if={@dep_history == []} style="font-size:13px;color:var(--tx-3);padding:4px 2px;">
          No revision yet.
        </div>
        <.revision_row
          :for={deployment <- @dep_history}
          deployment={deployment}
          model_index={@model_index}
          live?={live_revision?(deployment, @dep_live)}
          selected?={@dep_revision && deployment.id == @dep_revision.id}
          committer={committer_label(deployment, @current_user)}
          select_patch={dep_path(assigns, %{"rev" => to_string(deployment.revision)})}
          rollback_patch={
            if(not live_revision?(deployment, @dep_live),
              do: dep_path(assigns, %{"confirm" => deployment.id})
            )
          }
        >
          <:score_badge>
            <EvalsComponents.score_badge
              id={"revision-#{deployment.revision}-score"}
              run={Map.get(@dep_scores, deployment.id)}
            />
          </:score_badge>
        </.revision_row>
      </div>

      <IntegrationComponents.integration_section
        spec={@integration}
        api_keys_path={~p"/#{@org_slug}/#{@project.slug}/api-keys"}
      />
    </div>
    """
  end

  defp rollback_modal(assigns) do
    assigns =
      assign(assigns, :source, Enum.find(assigns.dep_history, &(&1.id == assigns.dep_confirm)))

    ~H"""
    <DS.modal
      :if={@source}
      id="rollback-modal"
      on_close={dep_path(assigns, %{"confirm" => nil})}
      title="Rollback"
      icon="rerun"
    >
      <div style="font-size:14px;color:var(--tx-1);line-height:1.6;">
        <DS.kv label="environment">
          {@dep_env.name}<DSIcons.icon :if={@dep_env.protected?} name="lock" size={10} />
        </DS.kv>
        <DS.kv label="source">{num(@source.revision)}</DS.kv>
        <DS.kv label="new revision">{num(next_revision(assigns))}</DS.kv>
        <p style="margin-top:10px;color:var(--warn);font-size:13px;">
          Revisions are immutable — rolling back commits that revision's pin (its model and prompt
          versions) as a new revision, and it goes live immediately.
        </p>
      </div>
      <:footer>
        <DS.btn_link variant="ghost" patch={dep_path(assigns, %{"confirm" => nil})}>
          Cancel
        </DS.btn_link>
        <DS.btn
          id="confirm-rollback"
          variant="primary"
          icon="rerun"
          style="margin-left:auto;"
          phx-click="rollback"
          phx-value-id={@source.id}
        >
          Rollback
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end

  # ---------------------------------------------------------------------------
  # Render helpers

  # The tab rows. Only Editor carries `?v=`: the version preview is prompt editing screen state.
  # Deployments has its own parameters (`env`/`rev`/`edit`), so `dep_path/2` builds it.
  defp tab_rows(assigns) do
    [
      %{
        id: "editor",
        label: @tab_labels["editor"],
        patch: editor_path(assigns, tab: nil, v: assigns.selected_number)
      },
      %{id: "arena", label: @tab_labels["arena"], patch: editor_path(assigns, tab: "arena")},
      %{id: "deployments", label: @tab_labels["deployments"], patch: dep_path(assigns, %{})},
      %{id: "evals", label: @tab_labels["evals"], patch: evals_path(assigns)}
    ]
  end

  # The Evals tab link. It carries `?env=` when the URL named one, so coming from the Deployments
  # tab lands on the same environment (ADR 0010 §5.2).
  defp evals_path(assigns) do
    query =
      Enum.reject([{"tab", "evals"}, {"env", assigns.env_slug}], fn {_key, value} ->
        is_nil(value)
      end)

    ~p"/#{assigns.org_slug}/#{assigns.project.slug}/use-cases/#{assigns.use_case.key}/prompt?#{query}"
  end

  # The header sub says only "how many of what exist, and what is running now".
  defp header_sub(assigns) do
    versions =
      case assigns.versions do
        [] -> "no version yet"
        [latest | _rest] = list -> "#{length(list)} versions · latest v#{latest.number}"
      end

    [versions | live_summary(assigns)] |> Enum.join(" · ")
  end

  defp live_summary(assigns) do
    assigns.envs
    |> Enum.flat_map(fn env ->
      case Map.get(assigns.deployments || %{}, env.id) do
        nil -> []
        deployment -> ["#{env.slug} ##{deployment.revision}"]
      end
    end)
    |> case do
      [] -> []
      parts -> ["live " <> Enum.join(parts, " · ")]
    end
  end

  defp arena_model_rows(assigns) do
    Enum.map(assigns.arena_models, fn model ->
      %{id: model.id, name: model.display_name, model_id: model.model_id}
    end)
  end

  defp picker_rows(assigns), do: assigns |> picker_matches() |> Enum.take(@picker_limit)

  defp picker_truncated(assigns) do
    case length(picker_matches(assigns)) - @picker_limit do
      n when n > 0 -> n
      _other -> 0
    end
  end

  defp deploy_env_rows(assigns) do
    Enum.map(assigns.envs, fn env ->
      %{
        id: env.id,
        slug: env.slug,
        name: env.name,
        checked?: env.id == assigns.deploy_env_id,
        revision: revision_of(assigns.deployments, env.id)
      }
    end)
  end

  defp revision_of(deployments, env_id) do
    case Map.get(deployments || %{}, env_id) do
      nil -> nil
      deployment -> deployment.revision
    end
  end

  defp deploy_model_rows(assigns) do
    arena = MapSet.new(assigns.arena_models, & &1.id)

    assigns
    |> deploy_model_order()
    |> Enum.map(fn model ->
      %{
        id: model.id,
        label: "#{model.display_name} · #{model.model_id}",
        arena?: MapSet.member?(arena, model.id),
        checked?: model.id == assigns.deploy_model_id
      }
    end)
  end

  # First comes **the current draft** (the default selection): choosing it makes Deploy mint the
  # next number on the spot. Below it are the already committed versions, for redeploying a past
  # version (no minting, no commit message).
  defp deploy_version_options(assigns) do
    committed =
      Enum.map(assigns.versions, fn version ->
        {"v#{version.number}#{version_note(version)}", version.id}
      end)

    if assigns.prompt,
      do: [{draft_option_label(assigns), @draft_option} | committed],
      else: committed
  end

  # When the draft equals the latest commit, no new number is promised: Deploy then reuses that
  # version as is.
  defp draft_option_label(assigns) do
    case clean_version(assigns) do
      nil -> "Current draft (will become v#{next_version_number(assigns)})"
      version -> "Current draft (same as v#{version.number})"
    end
  end

  defp next_version_number(assigns) do
    case List.first(assigns.versions) do
      nil -> 1
      latest -> latest.number + 1
    end
  end

  # The commit message field is shown only when this Deploy will actually create a version.
  defp deploy_minting?(assigns) do
    assigns.use_case.kind != :embedding and assigns.prompt != nil and
      assigns.deploy_version_id == @draft_option and clean_version(assigns) == nil
  end

  defp version_note(%{commit_message: message}) when is_binary(message) and message != "",
    do: " — " <> String.slice(message, 0, 40)

  defp version_note(_version), do: ""

  # "What this deployment will pin", as listed by the Deploy modal: every prompt of this use case.
  # The prompt being edited gets the version chosen in the modal (or the next number to be
  # minted); the rest get their own latest commit. A prompt with no version at all is plainly
  # shown as not pinned.
  defp deploy_pin_rows(%{use_case: %{kind: :embedding}}), do: []

  defp deploy_pin_rows(assigns) do
    current_id = current_prompt_id(assigns.prompt)

    Enum.map(assigns.prompts, fn prompt ->
      %{
        name: prompt.name,
        version: pin_version_label(assigns, prompt, prompt.id == current_id),
        current?: prompt.id == current_id
      }
    end)
  end

  defp pin_version_label(assigns, _prompt, true) do
    cond do
      assigns.deploy_version_id != @draft_option ->
        case Enum.find(assigns.versions, &(&1.id == assigns.deploy_version_id)) do
          nil -> nil
          version -> "v#{version.number}"
        end

      deploy_minting?(assigns) ->
        "v#{next_version_number(assigns)} (new)"

      true ->
        case clean_version(assigns) do
          nil -> nil
          version -> "v#{version.number}"
        end
    end
  end

  defp pin_version_label(assigns, prompt, false) do
    case assigns.prompt_versions |> Kernel.||(%{}) |> Map.get(prompt.id) do
      [%{number: number} | _rest] -> "v#{number}"
      _none -> nil
    end
  end

  # Ingredients for the Integration section: host, this use case, the selected environment, the
  # prompt names the deployment pins, and the variable schema.
  defp integration_spec(assigns) do
    %{
      host: integration_host(),
      use_case_key: assigns.use_case.key,
      kind: assigns.use_case.kind,
      environment: (assigns.dep_env && assigns.dep_env.slug) || "production",
      prompts: assigns.dep_revision |> pin_rows(assigns.version_index) |> Enum.map(& &1.name),
      variables: List.wrap(assigns.use_case.input_schema)
    }
  end

  # `PromptOnWeb.Endpoint.url/0` returns the deployed environment's `PHX_HOST` as is
  # (localhost:4000 in dev).
  defp integration_host, do: String.trim_trailing(PromptOnWeb.Endpoint.url(), "/")

  # The expand toggle is a patch (`?var=`): if already expanded, it becomes the collapse link.
  defp declared_rows(assigns) do
    Enum.map(assigns.declared, fn variable ->
      expanded? = assigns.expanded_var == variable.name

      %{
        name: variable.name,
        type: variable.type,
        required?: variable.required?,
        description: variable.description || "",
        example: variable.example || "",
        expanded?: expanded?,
        toggle_patch:
          editor_path(assigns,
            v: assigns.selected_number,
            diff: assigns.diff_number,
            var: if(expanded?, do: nil, else: variable.name)
          )
      }
    end)
  end

  # A switch link carries only `?prompt=`: `?v`/`?diff`/`?ai` mean something different per prompt
  # and must not move along.
  defp prompt_rows(assigns) do
    current = current_prompt_id(assigns.prompt)

    assigns.prompts
    |> Enum.with_index()
    |> Enum.map(fn {prompt, index} ->
      %{
        id: prompt_dom_id(prompt.name, index),
        name: prompt.name,
        count: version_count(prompt),
        active?: prompt.id == current,
        patch: editor_path(assigns, prompt: switch_param(prompt))
      }
    end)
  end

  defp switch_param(%{name: "default"}), do: nil
  defp switch_param(%{name: name}), do: name

  # A prompt name is a free-form string and cannot go straight into a DOM id; if only unusable
  # characters remain, it falls back to the index.
  defp prompt_dom_id(name, index) do
    case String.replace(name, ~r/[^A-Za-z0-9_-]+/, "-") do
      safe when safe in ["", "-"] -> "prompt-#{index}"
      safe -> "prompt-#{safe}"
    end
  end

  defp version_count(%{version_count: count}) when is_integer(count), do: count
  defp version_count(_prompt), do: nil

  # No badges: number, message, time, and a `live` marker only on versions a live deployment
  # points at.
  defp version_rows(assigns) do
    Enum.map(assigns.versions, fn version ->
      %{
        number: version.number,
        live_in: Map.get(assigns.live_versions, version.id, []),
        commit_message: version.commit_message,
        inserted_at: version.inserted_at,
        selected?: version.number == assigns.selected_number,
        patch: editor_path(assigns, v: version.number, versions: 1),
        diff_patch: editor_path(assigns, v: assigns.selected_number, diff: version.number),
        diff_title: "Diff v#{version.number} → #{assigns.selected_number || "draft"}"
      }
    end)
  end

  defp message_rows(assigns) do
    removable? = length(assigns.messages) > 1 and assigns.use_case.kind != :text

    assigns.messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} ->
      %{
        index: index,
        role: message.role,
        content: message.content,
        removable?: removable?,
        ai_patch: editor_path(assigns, v: assigns.selected_number, ai: index)
      }
    end)
  end

  defp diff_target(%{diff_number: nil}), do: nil

  defp diff_target(assigns),
    do: Enum.find(assigns.versions, &(&1.number == assigns.diff_number))

  # The modal opens **only when that message actually exists** (`?ai=` is a URL contract, so the
  # value can run ahead).
  defp ai_message(_messages, nil), do: nil
  defp ai_message(messages, index), do: Enum.at(messages, index)

  defp ai_role(messages, index) do
    case Enum.at(messages, index) do
      %{role: role} -> role
      _other -> "message"
    end
  end

  defp ai_content(messages, index) do
    case Enum.at(messages, index) do
      %{content: content} -> content
      _other -> ""
    end
  end
end
