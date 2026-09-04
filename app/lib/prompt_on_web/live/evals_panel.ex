defmodule PromptOnWeb.EvalsPanel do
  @moduledoc """
  The **Evals tab** of the use case hub (`?tab=evals`, ADR 0010 §5).

  One `Phoenix.LiveComponent` rather than more code in `PromptOnWeb.PromptEditorLive`: that file is
  already three thousand lines and this flow adds a dozen events and about twenty assigns. Events
  target `@myself`, and `push_patch/2` works from a component, so the hub's URL-state rule is
  unchanged.

  ## The loop, top to bottom

  1. **Sample 10 logs** — `CalibrationSet.:sample` freezes ten real monitoring logs of this use
     case (only ones whose payload is still stored).
  2. **Score them 1-5** — a star click writes immediately (`CalibrationSample.:score`). There is no
     Save button here, exactly as there is none in the prompt editor.
  3. **Draft rubric with AI** — `PromptOn.Evals.Calibration.draft/2` writes the rubric that
     explains those scores and immediately scores the same ten samples with it.
  4. **Agreement** — the human's score beside the AI's, plus mean absolute error, within ±1 and
     exact. Every number comes from aggregates on `Rubric`; nothing is computed twice.
  5. **Revise** (with an optional note) or **Edit manually** — both mint a new immutable rubric
     version.
  6. **Evaluate…** — `EvaluationRun.:start` scores up to 1,000 recent logs of one deployment
     revision × environment in the background, and the average lands on that revision's badge.

  ## URL state (ADR 0010 §5.2)

  `?set=` `?rubric=` `?revise=1` `?edit_rubric=1` `?evaluate=1` `?run=` plus the Deployments tab's
  own `?env=`, which this tab **reuses** so that switching tabs keeps the environment you were
  looking at. A `?set=`/`?rubric=`/`?run=` value that does not exist falls back to the default
  instead of breaking the screen — a hand-edited URL is a normal thing to happen.

  The three things that are *not* in the URL are the stars being clicked, the revision note being
  typed and the manual rubric form: forms in progress, not state worth sharing.

  ## Progress polling

  While a run is queued or running the panel asks the parent to send it `{:evals_refresh, id}`
  every two seconds (`PromptOnWeb.PromptEditorLive` forwards it with `send_update/2`). PubSub was
  the alternative and was rejected: it would need broadcast plumbing per tenant, and re-reading one
  indexed row every two seconds is cheaper than that.

  ## Provider key

  Every AI call here is BYOK on the organization's own OpenRouter key
  (`PromptOn.Evals.Judge.available?/1`). Without one, the AI buttons are disabled with the arena's
  own copy and the same link to `/{org}/settings?tab=providers` — sampling and manual scoring still
  work, because they call no model.
  """
  use PromptOnWeb, :live_component

  import PromptOnWeb.EvalsComponents

  alias PromptOn.Entitlements
  alias PromptOn.Evals
  alias PromptOn.Evals.Calibration
  alias PromptOn.Evals.Judge
  alias PromptOn.Evals.RubricCriteria
  alias PromptOn.Evals.Sampler
  alias PromptOnWeb.EditorTestRun
  alias PromptOnWeb.ErrorText

  @sample_size 10
  @candidate_window 200
  @poll_ms 2_000

  # ADR 0010 §3: a thousand items on `openai/gpt-4o-mini` costs about sixty cents.
  @cost_per_item 0.0006

  @doc false
  @spec sample_size() :: pos_integer()
  def sample_size, do: @sample_size

  @doc """
  The estimated judge cost of a run, in dollars.

      iex> PromptOnWeb.EvalsPanel.cost_estimate(1000)
      0.6
  """
  @spec cost_estimate(non_neg_integer()) :: float()
  def cost_estimate(count), do: Float.round(count * @cost_per_item, 4)

  # ---------------------------------------------------------------------------
  # Update

  @impl Phoenix.LiveComponent
  def update(%{refresh: :runs}, socket) do
    {:ok,
     socket
     |> assign(:poll_ref, nil)
     |> load_runs()
     |> refresh_selected_run()
     |> arm_poll()}
  end

  def update(assigns, socket) do
    socket = socket |> ensure_defaults() |> assign(assigns)

    socket =
      if socket.assigns.loaded_use_case_id == socket.assigns.use_case.id,
        do: socket,
        else: load_all(socket)

    {:ok, socket |> apply_params() |> arm_poll()}
  end

  defp ensure_defaults(%{assigns: %{loaded_use_case_id: _id}} = socket), do: socket

  defp ensure_defaults(socket) do
    assign(socket,
      loaded_use_case_id: nil,
      sets: [],
      set: nil,
      samples: [],
      rubrics: [],
      rubric: nil,
      scores: [],
      runs: [],
      run: nil,
      worst: [],
      judge?: false,
      eligible_count: 0,
      eligible_ok?: true,
      evaluate_key: nil,
      evaluate_count: 0,
      evaluate_countable?: true,
      stage: :idle,
      revise_note: "",
      rubric_form: nil,
      poll_ref: nil,
      revise?: false,
      edit_rubric?: false,
      evaluate?: false,
      env: nil,
      env_pinned?: false
    )
  end

  defp load_all(socket) do
    socket
    |> assign(:loaded_use_case_id, socket.assigns.use_case.id)
    |> assign(:judge?, Judge.available?(socket.assigns.organization.id))
    |> count_eligible()
    |> load_sets()
    |> load_rubrics()
    |> load_runs()
  end

  # ---------------------------------------------------------------------------
  # Loading

  defp scope(socket),
    do: [tenant: socket.assigns.project.id, actor: socket.assigns.current_user]

  # `Sampler.count_eligible/2` says whether the number is trustworthy. "0 because the query failed"
  # and "0 because there are none" get different copy — the second is actionable, the first is not.
  defp count_eligible(socket) do
    {count, ok?} =
      Sampler.count_eligible(socket.assigns.use_case,
        limit: @candidate_window,
        tenant: socket.assigns.project.id,
        actor: socket.assigns.current_user
      )

    assign(socket, eligible_count: count, eligible_ok?: ok?)
  end

  defp load_sets(socket) do
    sets =
      case Evals.list_calibration_sets(socket.assigns.use_case.id, scope(socket)) do
        {:ok, sets} -> sets
        {:error, _error} -> []
      end

    assign(socket, :sets, sets)
  end

  defp load_samples(%{assigns: %{set: nil}} = socket), do: assign(socket, :samples, [])

  defp load_samples(socket) do
    samples =
      case Evals.list_calibration_samples(
             socket.assigns.set.id,
             scope(socket) ++ [load: [:input_text, :output_text]]
           ) do
        {:ok, samples} -> samples
        {:error, _error} -> []
      end

    assign(socket, :samples, samples)
  end

  @rubric_loads [
    :scored_count,
    :within_one_count,
    :exact_count,
    :unparsable_count,
    :mean_absolute_error,
    :within_one_ratio,
    :exact_ratio
  ]

  defp load_rubrics(socket) do
    rubrics =
      case Evals.list_rubrics(
             socket.assigns.use_case.id,
             scope(socket) ++ [load: @rubric_loads]
           ) do
        {:ok, rubrics} -> rubrics
        {:error, _error} -> []
      end

    assign(socket, :rubrics, rubrics)
  end

  defp load_scores(%{assigns: %{rubric: nil}} = socket), do: assign(socket, :scores, [])

  defp load_scores(socket) do
    scores =
      case Evals.list_calibration_scores(
             socket.assigns.rubric.id,
             scope(socket) ++ [load: [:rationale]]
           ) do
        {:ok, scores} -> scores
        {:error, _error} -> []
      end

    assign(socket, :scores, scores)
  end

  defp load_runs(socket) do
    runs =
      case Evals.list_evaluation_runs(
             socket.assigns.use_case.id,
             scope(socket) ++ [load: [:environment], page: [limit: 20]]
           ) do
        {:ok, %{results: results}} -> results
        {:ok, results} when is_list(results) -> results
        {:error, _error} -> []
      end

    assign(socket, :runs, runs)
  end

  defp load_worst(%{assigns: %{run: nil}} = socket), do: assign(socket, :worst, [])

  defp load_worst(socket) do
    worst =
      case Evals.worst_evaluation_results(
             socket.assigns.run.id,
             scope(socket) ++ [load: [:rationale]]
           ) do
        {:ok, items} -> items
        {:error, _error} -> []
      end

    assign(socket, :worst, worst)
  end

  # The drawer must follow a run it is watching, not the copy that was in the list when it opened.
  defp refresh_selected_run(%{assigns: %{run: nil}} = socket), do: socket

  defp refresh_selected_run(socket) do
    case Enum.find(socket.assigns.runs, &(&1.id == socket.assigns.run.id)) do
      nil -> socket
      run -> socket |> assign(:run, run) |> load_worst()
    end
  end

  # ---------------------------------------------------------------------------
  # URL parameters

  defp apply_params(socket) do
    params = socket.assigns[:params] || %{}

    socket
    |> assign(:revise?, flag(params["revise"]))
    |> assign(:edit_rubric?, flag(params["edit_rubric"]))
    |> assign(:evaluate?, flag(params["evaluate"]))
    |> select_env(params["env"])
    |> select_set(params["set"])
    |> select_rubric(params["rubric"])
    |> select_run(params["run"])
    |> ensure_rubric_form()
    |> assign_evaluate_target()
  end

  defp flag(raw), do: is_binary(raw) and raw != ""

  # The environment shown in the Evaluate modal. An unknown or missing slug falls back to
  # production (then the first environment), exactly as the Deployments tab does. `env_pinned?`
  # records whether the URL actually named one: only then do this tab's links carry `?env=`, so the
  # Editor and Arena tabs keep their clean URLs.
  defp select_env(socket, raw) do
    envs = socket.assigns.envs
    named = Enum.find(envs, &(&1.slug == raw))
    env = named || Enum.find(envs, &(&1.slug == "production")) || List.first(envs)

    assign(socket, env: env, env_pinned?: named != nil)
  end

  defp select_set(socket, raw) do
    set = Enum.find(socket.assigns.sets, &(&1.id == raw)) || default_set(socket.assigns.sets)

    if id_of(set) == id_of(socket.assigns.set) do
      socket
    else
      socket |> assign(:set, set) |> load_samples()
    end
  end

  defp default_set(sets), do: Enum.find(sets, &is_nil(&1.archived_at)) || List.first(sets)

  defp select_rubric(socket, raw) do
    number = parse_int(raw)

    rubric =
      Enum.find(socket.assigns.rubrics, &(&1.number == number)) ||
        List.first(socket.assigns.rubrics)

    if id_of(rubric) == id_of(socket.assigns.rubric) do
      socket
    else
      socket |> assign(:rubric, rubric) |> load_scores()
    end
  end

  # An unknown `?run=` closes the drawer; it never raises.
  defp select_run(socket, raw) do
    run = is_binary(raw) and raw != "" and Enum.find(socket.assigns.runs, &(&1.id == raw))
    run = if run, do: run, else: nil

    if id_of(run) == id_of(socket.assigns.run) do
      socket
    else
      socket |> assign(:run, run) |> load_worst()
    end
  end

  defp id_of(nil), do: nil
  defp id_of(%{id: id}), do: id

  defp parse_int(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end

  defp parse_int(_raw), do: nil

  defp ensure_rubric_form(%{assigns: %{edit_rubric?: false}} = socket),
    do: assign(socket, :rubric_form, nil)

  defp ensure_rubric_form(%{assigns: %{rubric_form: form}} = socket) when not is_nil(form),
    do: socket

  defp ensure_rubric_form(socket),
    do: assign(socket, :rubric_form, rubric_form(criteria_params(socket.assigns.rubric)))

  defp rubric_form(params), do: to_form(params, as: :rubric)

  defp criteria_params(nil) do
    Map.new(RubricCriteria.levels(), &{to_string(&1), ""})
    |> Map.merge(%{"summary" => "", "must_never" => ""})
  end

  defp criteria_params(%{criteria: criteria}) do
    RubricCriteria.levels()
    |> Map.new(&{to_string(&1), Map.get(criteria, &1) || ""})
    |> Map.merge(%{
      "summary" => criteria.summary || "",
      "must_never" => Enum.join(criteria.must_never || [], "\n")
    })
  end

  # The eligible-log count of the Evaluate modal's target. Cached on the target so the two-second
  # poll does not re-run the query while the modal sits open.
  defp assign_evaluate_target(%{assigns: %{evaluate?: false}} = socket), do: socket

  defp assign_evaluate_target(socket) do
    deployment = live_deployment(socket.assigns)
    key = {id_of(socket.assigns.env), id_of(deployment)}

    if socket.assigns.evaluate_key == key do
      socket
    else
      {count, ok?} =
        if deployment do
          Sampler.count_eligible(socket.assigns.use_case,
            limit: Entitlements.limit(socket.assigns.organization, :evaluation_sample_limit),
            deployment_id: deployment.id,
            environment_id: socket.assigns.env.id,
            tenant: socket.assigns.project.id,
            actor: socket.assigns.current_user
          )
        else
          {0, true}
        end

      assign(socket,
        evaluate_key: key,
        evaluate_count: count,
        evaluate_countable?: ok?
      )
    end
  end

  defp live_deployment(%{env: nil}), do: nil
  defp live_deployment(assigns), do: Map.get(assigns.deployments || %{}, assigns.env.id)

  # ---------------------------------------------------------------------------
  # Polling

  defp arm_poll(socket) do
    cond do
      not connected?(socket) -> socket
      socket.assigns.poll_ref != nil -> socket
      not Enum.any?(socket.assigns.runs, &(&1.status in [:queued, :running])) -> socket
      true -> assign(socket, :poll_ref, schedule_poll(socket.assigns.id))
    end
  end

  defp schedule_poll(id), do: Process.send_after(self(), {:evals_refresh, id}, @poll_ms)

  # ---------------------------------------------------------------------------
  # Events

  @impl Phoenix.LiveComponent
  def handle_event("sample", _params, socket) do
    case Evals.sample_calibration_set(
           %{use_case_id: socket.assigns.use_case.id, sample_size: @sample_size},
           scope(socket)
         ) do
      {:ok, set} ->
        {:noreply,
         socket
         |> load_sets()
         |> assign(set: set)
         |> load_samples()
         |> push_patch(to: evals_path(socket.assigns, %{"set" => set.id, "rubric" => nil}))}

      {:error, error} ->
        {:noreply, flash(socket, :error, ErrorText.message(error))}
    end
  end

  def handle_event("score_sample", %{"sample" => id, "star" => star}, socket) do
    with %{} = sample <- find_sample(socket, id),
         {:ok, _scored} <-
           Evals.score_calibration_sample(
             sample,
             %{user_score: parse_int(star)},
             scope(socket)
           ) do
      {:noreply, load_samples(socket)}
    else
      nil -> {:noreply, socket}
      {:error, error} -> {:noreply, flash(socket, :error, ErrorText.message(error))}
    end
  end

  def handle_event("note_sample", %{"sample" => id, "value" => value}, socket) do
    with %{user_score: score} = sample when not is_nil(score) <- find_sample(socket, id),
         true <- (sample.user_note || "") != value,
         {:ok, _scored} <-
           Evals.score_calibration_sample(
             sample,
             %{user_score: score, user_note: blank_to_nil(value)},
             scope(socket)
           ) do
      {:noreply, load_samples(socket)}
    else
      {:error, error} -> {:noreply, flash(socket, :error, ErrorText.message(error))}
      _unchanged -> {:noreply, socket}
    end
  end

  def handle_event("draft", _params, socket) do
    case guard_draft(socket) do
      {:error, message} ->
        {:noreply, flash(socket, :error, message)}

      :ok ->
        set = socket.assigns.set
        opts = scope(socket)

        {:noreply,
         socket
         |> assign(:stage, :running)
         |> start_async(:draft, fn -> Calibration.draft(set, opts) end)}
    end
  end

  def handle_event("revise_change", %{"revise" => %{"note" => note}}, socket),
    do: {:noreply, assign(socket, :revise_note, note)}

  def handle_event("revise", params, socket) do
    note = get_in(params, ["revise", "note"]) || socket.assigns.revise_note

    case guard_rubric(socket) do
      {:error, message} ->
        {:noreply, flash(socket, :error, message)}

      :ok ->
        rubric = socket.assigns.rubric
        opts = scope(socket) ++ [note: blank_to_nil(note)]

        {:noreply,
         socket
         |> assign(stage: :running, revise_note: note)
         |> start_async(:revise, fn -> Calibration.revise(rubric, opts) end)}
    end
  end

  def handle_event("rescore", _params, socket) do
    case guard_rubric(socket) do
      {:error, message} ->
        {:noreply, flash(socket, :error, message)}

      :ok ->
        rubric = socket.assigns.rubric
        opts = scope(socket)

        {:noreply,
         socket
         |> assign(:stage, :running)
         |> start_async(:rescore, fn -> Calibration.score_set(rubric, opts) end)}
    end
  end

  def handle_event("rubric_change", %{"rubric" => params}, socket),
    do: {:noreply, assign(socket, :rubric_form, rubric_form(params))}

  def handle_event("save_rubric", %{"rubric" => params}, socket) do
    attrs =
      %{
        criteria: criteria_attrs(params),
        source_rubric_id: id_of(socket.assigns.rubric),
        use_case_id: socket.assigns.use_case.id,
        calibration_set_id: id_of(socket.assigns.set)
      }

    case Evals.write_rubric(attrs, scope(socket)) do
      {:ok, rubric} ->
        {:noreply,
         socket
         |> assign(rubric_form: nil)
         |> load_rubrics()
         |> assign(:rubric, nil)
         |> push_patch(
           to:
             evals_path(socket.assigns, %{
               "rubric" => to_string(rubric.number),
               "edit_rubric" => nil
             })
         )}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:rubric_form, rubric_form(params))
         |> flash(:error, ErrorText.message(error))}
    end
  end

  # The button only exists when nothing blocks the run, but the event is re-checked anyway: a
  # crafted event must produce the same sentence the modal would have shown, not a crash.
  def handle_event("evaluate", _params, socket) do
    case evaluate_blocker(socket.assigns) do
      nil -> start_evaluation(socket)
      message -> {:noreply, flash(socket, :error, message)}
    end
  end

  def handle_event("cancel_run", %{"id" => id}, socket) do
    with %{} = run <- Enum.find(socket.assigns.runs, &(&1.id == id)),
         {:ok, _cancelled} <- Evals.cancel_evaluation(run, scope(socket)) do
      {:noreply, socket |> load_runs() |> refresh_selected_run()}
    else
      nil -> {:noreply, socket}
      {:error, error} -> {:noreply, flash(socket, :error, ErrorText.message(error))}
    end
  end

  defp start_evaluation(socket) do
    deployment = live_deployment(socket.assigns)
    rubric = current_rubric(socket.assigns)

    case Evals.start_evaluation(
           %{
             use_case_id: socket.assigns.use_case.id,
             deployment_id: deployment.id,
             environment_id: socket.assigns.env.id,
             rubric_id: rubric.id,
             sample_limit: max(socket.assigns.evaluate_count, 1)
           },
           scope(socket)
         ) do
      {:ok, run} ->
        {:noreply,
         socket
         |> load_runs()
         |> arm_poll()
         |> flash(
           :info,
           "Evaluating revision ##{run.deployment_revision} — #{run.item_count} logs."
         )
         |> push_patch(to: evals_path(socket.assigns, %{"evaluate" => nil, "run" => run.id}))}

      {:error, error} ->
        {:noreply, flash(socket, :error, ErrorText.message(error))}
    end
  end

  # `put_flash/3` inside a LiveComponent reaches the parent's flash tray **only** when the component
  # also patches or navigates (`Phoenix.LiveView.put_flash/3` docs), and most of these messages come
  # with no navigation at all. So the panel hands every message to the LiveView, which owns the
  # tray; `PromptOnWeb.PromptEditorLive` puts it there.
  defp flash(socket, kind, message) do
    send(self(), {:evals_flash, kind, message})
    socket
  end

  defp find_sample(socket, id), do: Enum.find(socket.assigns.samples, &(&1.id == id))

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp guard_draft(%{assigns: %{set: nil}}), do: {:error, "Sample some logs first."}
  defp guard_draft(socket), do: guard_ai(socket)

  defp guard_ai(%{assigns: %{judge?: false}}),
    do: {:error, EditorTestRun.llm_error_message(:no_provider_key)}

  defp guard_ai(%{assigns: %{stage: :running}}), do: {:error, "Still running — wait."}
  defp guard_ai(_socket), do: :ok

  # `:revise` and `:rescore` both need a rubric on screen. The buttons only exist when there is
  # one; this is the same answer for an event that arrives without it.
  defp guard_rubric(%{assigns: %{rubric: nil}}), do: {:error, "There is no rubric to work from."}
  defp guard_rubric(socket), do: guard_ai(socket)

  defp criteria_attrs(params) do
    RubricCriteria.levels()
    |> Map.new(&{&1, Map.get(params, to_string(&1), "")})
    |> Map.merge(%{
      summary: Map.get(params, "summary", ""),
      must_never: must_never_list(Map.get(params, "must_never", ""))
    })
  end

  defp must_never_list(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp must_never_list(_text), do: []

  # ---------------------------------------------------------------------------
  # Async

  @impl Phoenix.LiveComponent
  def handle_async(:draft, {:ok, {:ok, rubric}}, socket) do
    {:noreply,
     socket
     |> assign(:stage, :idle)
     |> load_rubrics()
     |> assign(:rubric, nil)
     |> push_patch(to: evals_path(socket.assigns, %{"rubric" => to_string(rubric.number)}))}
  end

  def handle_async(:revise, {:ok, {:ok, rubric}}, socket) do
    {:noreply,
     socket
     |> assign(stage: :idle, revise_note: "")
     |> load_rubrics()
     |> assign(:rubric, nil)
     |> push_patch(
       to: evals_path(socket.assigns, %{"rubric" => to_string(rubric.number), "revise" => nil})
     )}
  end

  def handle_async(:rescore, {:ok, {:ok, tally}}, socket) do
    {:noreply,
     socket
     |> assign(:stage, :idle)
     |> load_rubrics()
     |> refresh_rubric()
     |> load_scores()
     |> flash(:info, rescore_flash(tally))}
  end

  def handle_async(stage, {:ok, {:error, reason}}, socket)
      when stage in [:draft, :revise, :rescore] do
    {:noreply,
     socket
     |> assign(:stage, :error)
     |> flash(:error, async_error_message(reason))}
  end

  def handle_async(stage, {:exit, reason}, socket) when stage in [:draft, :revise, :rescore] do
    {:noreply,
     socket
     |> assign(:stage, :error)
     |> flash(:error, EditorTestRun.llm_error_message({:request_failed, reason}))}
  end

  defp refresh_rubric(%{assigns: %{rubric: nil}} = socket), do: socket

  defp refresh_rubric(socket) do
    assign(
      socket,
      :rubric,
      Enum.find(socket.assigns.rubrics, &(&1.id == socket.assigns.rubric.id))
    )
  end

  defp rescore_flash(%{scored: scored, unparsable: unparsable, failed: failed}) do
    base = "Scored #{scored} sample(s) with this rubric."

    case unparsable + failed do
      0 -> base
      n -> base <> " #{n} did not come back usable."
    end
  end

  defp async_error_message(:no_scored_samples), do: "Score the samples first."
  defp async_error_message(:no_calibration_set), do: "This rubric has no calibration set."
  defp async_error_message({:unparsable, _raw}), do: "The judge did not answer with JSON."
  defp async_error_message(%Ash.Error.Invalid{} = error), do: ErrorText.message(error)
  defp async_error_message(reason), do: EditorTestRun.llm_error_message(reason)

  # ---------------------------------------------------------------------------
  # Paths

  # The tab's links, built as a list in **fixed order** so one screen state never becomes two
  # different strings. `set` and `rubric` are left out at their default value (the latest set, the
  # current rubric) to keep the URL clean, exactly as the editor leaves out the default prompt.
  defp evals_path(assigns, overrides) do
    overrides = Map.new(overrides)

    query =
      [
        {"tab", "evals"},
        {"env", assigns.env_pinned? && assigns.env && assigns.env.slug},
        {"set", non_default_set(assigns)},
        {"rubric", non_default_rubric(assigns)},
        {"revise", if(assigns.revise?, do: "1")},
        {"edit_rubric", if(assigns.edit_rubric?, do: "1")},
        {"evaluate", if(assigns.evaluate?, do: "1")},
        {"run", assigns.run && assigns.run.id}
      ]
      |> Enum.map(fn {key, value} -> {key, Map.get(overrides, key, value)} end)
      |> Enum.reject(fn {_key, value} -> value in [nil, "", false] end)

    ~p"/#{assigns.org_slug}/#{assigns.project.slug}/use-cases/#{assigns.use_case.key}/prompt?#{query}"
  end

  defp non_default_set(%{set: nil}), do: nil

  defp non_default_set(assigns) do
    if id_of(default_set(assigns.sets)) == assigns.set.id, do: nil, else: assigns.set.id
  end

  defp non_default_rubric(%{rubric: nil}), do: nil

  defp non_default_rubric(assigns) do
    case assigns.rubrics do
      [current | _rest] ->
        if current.id == assigns.rubric.id, do: nil, else: to_string(assigns.rubric.number)

      [] ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Derived view data

  defp scored_count(samples), do: Enum.count(samples, &(not is_nil(&1.user_score)))

  defp all_scored?(samples), do: samples != [] and scored_count(samples) == length(samples)

  # One agreement row per sample: the human's score, the AI's, and the gap. A sample the rubric was
  # never run against gets a nil status, which the table renders as "not scored yet".
  defp agreement_rows(samples, scores) do
    by_sample = Map.new(scores, &{&1.calibration_sample_id, &1})

    Enum.map(samples, fn sample ->
      score = Map.get(by_sample, sample.id)

      %{
        position: sample.position,
        excerpt: input_excerpt(sample.input_text, 70),
        user_score: sample.user_score,
        ai_score: score && score.score,
        delta: score && score.absolute_error,
        status: score && score.status,
        rationale: score && score.rationale,
        error_message: score && score.error_message
      }
    end)
  end

  defp providers_path(assigns), do: ~p"/#{assigns.org_slug}/settings?#{[tab: "providers"]}"
  defp settings_path(assigns), do: ~p"/#{assigns.org_slug}/settings?#{[tab: "general"]}"

  defp api_keys_path(assigns),
    do: ~p"/#{assigns.org_slug}/#{assigns.project.slug}/api-keys"

  defp set_label(set), do: Calendar.strftime(set.inserted_at, "%b %d")

  # Why the Evaluate button cannot be pressed, in the user's words. nil means it can.
  defp evaluate_blocker(assigns) do
    cond do
      current_rubric(assigns) == nil ->
        "Draft a rubric first — an evaluation needs one."

      not assigns.judge? ->
        EditorTestRun.llm_error_message(:no_provider_key)

      assigns.env == nil ->
        "This project has no environments."

      live_deployment(assigns) == nil ->
        "Nothing is deployed to #{assigns.env.slug} yet."

      active_run_for?(assigns) ->
        "An evaluation of this revision is already running."

      not assigns.evaluate_countable? ->
        "Could not read the monitoring logs of this revision. Reload and try again."

      assigns.evaluate_count == 0 ->
        "No logs with stored payloads for this revision yet."

      true ->
        nil
    end
  end

  # The rubric an evaluation runs with is **always the current one** (ADR 0010 §5.3e): evaluating
  # with an old rubric would put a worse-calibrated average on the revision badge, which picks the
  # newest completed run regardless of rubric. `?rubric=` only steers what is displayed.
  defp current_rubric(assigns), do: List.first(assigns.rubrics)

  # The selected rubric was calibrated on a different sample set than the one on screen — the
  # agreement rows would come from set B while the rubric's numbers come from set A. Returns the
  # rubric's set id so the note can link to it, or nil when the two agree.
  defp rubric_set_mismatch(%{rubric: nil}), do: nil
  defp rubric_set_mismatch(%{rubric: %{calibration_set_id: nil}}), do: nil
  defp rubric_set_mismatch(%{set: nil}), do: nil

  defp rubric_set_mismatch(%{rubric: rubric, set: set}) do
    if rubric.calibration_set_id == set.id, do: nil, else: rubric.calibration_set_id
  end

  defp active_run_for?(assigns) do
    case live_deployment(assigns) do
      nil ->
        false

      deployment ->
        Enum.any?(
          assigns.runs,
          &(&1.deployment_id == deployment.id and &1.status in [:queued, :running])
        )
    end
  end

  defp draft_blocker(assigns) do
    cond do
      not assigns.judge? -> EditorTestRun.llm_error_message(:no_provider_key)
      not all_scored?(assigns.samples) -> "Score all #{length(assigns.samples)} samples first."
      assigns.stage == :running -> "Still running — wait."
      true -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Render

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assigns
      |> assign(:plan, Entitlements.plan(assigns.organization))
      |> assign(:scored, scored_count(assigns.samples))
      |> assign(:draft_blocker, draft_blocker(assigns))
      |> assign(:evaluate_blocker, evaluate_blocker(assigns))
      |> assign(:live, live_deployment(assigns))
      |> assign(:rows, agreement_rows(assigns.samples, assigns.scores))
      |> assign(:rubric_set_mismatch, rubric_set_mismatch(assigns))

    ~H"""
    <div id={@id} style="display:flex;flex-direction:column;gap:16px;min-width:0;">
      <DS.empty
        :if={@use_case.kind == :embedding}
        id="evals-not-applicable"
        icon="flask"
        title="Nothing to evaluate"
        sub="Evals score a prompt's output. This use case is log-only (embedding)."
      />

      <%= if @use_case.kind != :embedding do %>
        <.no_key_note :if={not @judge?} id="evals-no-key" providers_path={providers_path(assigns)} />

        <.calibration_section {assigns} />
        <.rubric_section :if={@rubric} {assigns} />
        <.runs_section {assigns} />

        <.continuous_eval_card plan={@plan} settings_path={settings_path(assigns)} />
      <% end %>

      <.revise_modal :if={@revise? and @rubric} {assigns} />
      <.rubric_editor_modal :if={@edit_rubric? and @rubric_form} {assigns} />
      <.evaluate_modal :if={@evaluate?} {assigns} />
      <.run_drawer
        :if={@run}
        run={@run}
        items={@worst}
        target={@myself}
        on_close={evals_path(assigns, %{"run" => nil})}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :providers_path, :string, required: true

  defp no_key_note(assigns) do
    ~H"""
    <div
      id={@id}
      class="card2"
      style="padding:10px 12px;display:flex;align-items:center;gap:8px;font-size:13px;color:var(--tx-2);"
    >
      <DSIcons.icon name="key" size={14} class="tx3" />
      <span>No provider key — the AI steps are disabled.</span>
      <.link navigate={@providers_path} style="color:var(--link);">Organization settings</.link>
    </div>
    """
  end

  defp calibration_section(assigns) do
    ~H"""
    <div id="evals-calibration" style="display:flex;flex-direction:column;gap:10px;min-width:0;">
      <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;">
        <span class="mono-label">Calibration</span>
        <span :if={@set} class="font-mono" style="font-size:12px;color:var(--tx-3);">
          {@scored} / {length(@samples)} scored · {ago_label(@set.inserted_at)}
        </span>
        <span style="flex:1;"></span>
        <DS.seg
          :if={length(@sets) > 1}
          id="calibration-set-picker"
          value={@set && @set.id}
          options={
            Enum.map(
              @sets,
              &%{
                value: &1.id,
                label: set_label(&1),
                patch: evals_path(assigns, %{"set" => &1.id})
              }
            )
          }
        />
        <DS.btn
          :if={@set}
          id="resample-logs"
          size="sm"
          variant="ghost"
          icon="rerun"
          phx-click="sample"
          phx-target={@myself}
          disabled={@eligible_count < 5}
          title={@eligible_count < 5 && "Fewer than five logs with stored payloads."}
        >
          Sample again
        </DS.btn>
      </div>

      <DS.empty
        :if={is_nil(@set) and @eligible_ok? and @eligible_count >= 5}
        id="evals-empty"
        icon="flask"
        title="Evaluate this use case"
        sub="Score 10 real logs → the AI writes the rubric → check it agrees with you → evaluate a whole revision."
      >
        <:action>
          <DS.btn
            id="sample-logs"
            variant="primary"
            icon="flask"
            phx-click="sample"
            phx-target={@myself}
          >
            Sample {sample_size()} logs
          </DS.btn>
        </:action>
      </DS.empty>

      <DS.empty
        :if={is_nil(@set) and @eligible_ok? and @eligible_count < 5}
        id="evals-no-logs"
        icon="database"
        title="No monitoring logs with stored payloads yet"
        sub="Evals score real traffic. Send monitoring logs from your app with the PromptOn SDK, then come back."
      >
        <:action>
          <DS.btn_link
            id="evals-open-api-keys"
            variant="outline"
            icon="key"
            navigate={api_keys_path(assigns)}
          >
            API keys & SDK setup
          </DS.btn_link>
        </:action>
      </DS.empty>

      <DS.empty
        :if={is_nil(@set) and not @eligible_ok?}
        id="evals-logs-unreadable"
        icon="database"
        title="Could not read the monitoring logs"
        sub="The log query failed, so we do not know how many samples are available. Reload the page to try again."
      />

      <%= if @set do %>
        <details id="evals-samples" class="card2 dscollapse" open={is_nil(@rubric)}>
          <summary>
            <DSIcons.icon name="chevRight" size={13} class="tx2 dscollapse-closed" />
            <DSIcons.icon name="chevDown" size={13} class="tx2 dscollapse-open" />
            <span style="font-size:13.5px;font-weight:500;">
              Samples — {@scored} / {length(@samples)} scored
            </span>
          </summary>
          <div
            class="fadeup"
            style="padding:4px 11px 11px;display:flex;flex-direction:column;gap:9px;min-width:0;"
          >
            <.sample_card :for={sample <- @samples} sample={sample} target={@myself} />

            <div style="display:flex;align-items:center;gap:10px;">
              <DS.btn
                id="draft-rubric"
                variant="primary"
                icon="sparkles"
                phx-click="draft"
                phx-target={@myself}
                disabled={@draft_blocker != nil}
                title={@draft_blocker}
              >
                {if @stage == :running, do: "Working…", else: "Draft rubric with AI"}
              </DS.btn>
              <span
                :if={@draft_blocker}
                id="draft-blocked"
                style="font-size:12.5px;color:var(--tx-3);"
              >
                {@draft_blocker}
              </span>
            </div>
          </div>
        </details>
      <% end %>
    </div>
    """
  end

  defp rubric_section(assigns) do
    ~H"""
    <div id="evals-rubric" style="display:flex;flex-direction:column;gap:10px;min-width:0;">
      <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;">
        <span class="mono-label">Rubric</span>
        <DS.seg
          :if={length(@rubrics) > 1}
          id="rubric-versions"
          value={to_string(@rubric.number)}
          options={
            Enum.map(
              @rubrics,
              &%{
                value: to_string(&1.number),
                label: "v#{&1.number}",
                patch: evals_path(assigns, %{"rubric" => to_string(&1.number), "run" => nil})
              }
            )
          }
        />
        <span style="flex:1;"></span>
        <DS.btn_link
          id="evaluate-open"
          variant="primary"
          icon="flask"
          patch={evals_path(assigns, %{"evaluate" => "1"})}
        >
          Evaluate…
        </DS.btn_link>
      </div>

      <.rubric_card rubric={@rubric} />

      <div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;">
        <DS.stat_tile
          label="mean abs. error"
          value={score_label(@rubric.mean_absolute_error)}
          sub={"n = #{@rubric.scored_count}"}
        />
        <DS.stat_tile label="within ±1" value={ratio_label(@rubric.within_one_ratio)} />
        <DS.stat_tile label="exact" value={ratio_label(@rubric.exact_ratio)} />
      </div>

      <div id="agreement-aim" style="font-size:12px;color:var(--tx-3);line-height:1.5;">
        Lower mean absolute error is better. Aim for ≤ 0.5 and ≥ 80% within ±1 before you evaluate a
        revision.
      </div>

      <div
        :if={
          is_nil(@rubric_set_mismatch) and @rubric.scored_count == 0 and
            @rubric.unparsable_count == 0
        }
        id="rubric-not-scored"
        style="font-size:13px;color:var(--tx-3);"
      >
        Not scored against these samples yet.
      </div>

      <div
        :if={@rubric_set_mismatch}
        id="rubric-other-set"
        style="font-size:13px;color:var(--tx-3);line-height:1.55;"
      >
        v{@rubric.number} was calibrated on an earlier sample set, so it cannot be compared with the
        samples shown above.
        <.link
          patch={evals_path(assigns, %{"set" => @rubric_set_mismatch})}
          style="color:var(--link);"
        >
          Show that set
        </.link>
      </div>

      <.agreement_table
        :if={
          is_nil(@rubric_set_mismatch) and
            (@rubric.scored_count > 0 or @rubric.unparsable_count > 0)
        }
        rows={@rows}
      />

      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
        <DS.btn
          id="rescore-rubric"
          size="sm"
          variant="outline"
          icon="rerun"
          phx-click="rescore"
          phx-target={@myself}
          disabled={not @judge? or @stage == :running}
          title={not @judge? && EditorTestRun.llm_error_message(:no_provider_key)}
        >
          Re-score with this rubric
        </DS.btn>
        <DS.btn_link
          id="revise-rubric"
          size="sm"
          variant="outline"
          icon="sparkles"
          patch={evals_path(assigns, %{"revise" => "1"})}
        >
          Revise with AI
        </DS.btn_link>
        <DS.btn_link
          id="edit-rubric"
          size="sm"
          variant="ghost"
          icon="note"
          patch={evals_path(assigns, %{"edit_rubric" => "1"})}
        >
          Edit manually
        </DS.btn_link>
        <span :if={@stage == :running} id="rubric-working" style="font-size:12.5px;color:var(--tx-3);">
          Working…
        </span>
      </div>
    </div>
    """
  end

  defp runs_section(assigns) do
    ~H"""
    <div id="evals-runs" style="display:flex;flex-direction:column;gap:8px;min-width:0;">
      <span class="mono-label">Evaluations</span>
      <div :if={@runs == []} id="evals-no-runs" style="font-size:13px;color:var(--tx-3);padding:2px;">
        No evaluation yet.
      </div>
      <.run_card
        :for={run <- @runs}
        run={run}
        selected?={@run && run.id == @run.id}
        patch={evals_path(assigns, %{"run" => run.id})}
      />
    </div>
    """
  end

  defp revise_modal(assigns) do
    ~H"""
    <DS.modal
      id="revise-modal"
      on_close={evals_path(assigns, %{"revise" => nil})}
      width={560}
      title={"Revise rubric v#{@rubric.number}"}
      icon="sparkles"
    >
      <form id="revise-form" phx-change="revise_change" phx-submit="revise" phx-target={@myself}>
        <div class="mono-label" style="margin-bottom:7px;">What should change? (optional)</div>
        <textarea
          id="revise-note"
          name="revise[note]"
          phx-debounce="300"
          placeholder="e.g. a wrong language should never score above 2"
          class="ring-acc"
          style="width:100%;height:84px;background:var(--bg-1);border:1px solid var(--line);border-radius:var(--r);padding:10px 12px;color:var(--tx-0);font-size:14px;font-family:inherit;resize:none;outline:none;line-height:1.55;"
        >{@revise_note}</textarea>
        <div style="font-size:12.5px;color:var(--tx-3);margin-top:8px;line-height:1.55;">
          A revision is a new version — v{@rubric.number} stays exactly as it is. The AI re-scores
          the {length(@samples)} samples with it so you can see whether agreement improved.
        </div>
      </form>
      <:footer>
        <DS.btn_link variant="ghost" patch={evals_path(assigns, %{"revise" => nil})}>Cancel</DS.btn_link>
        <DS.btn
          id="revise-submit"
          variant="primary"
          icon="sparkles"
          style="margin-left:auto;"
          form="revise-form"
          type="submit"
          disabled={not @judge? or @stage == :running}
          title={not @judge? && EditorTestRun.llm_error_message(:no_provider_key)}
        >
          {if @stage == :running, do: "Working…", else: "Revise"}
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end

  defp rubric_editor_modal(assigns) do
    ~H"""
    <DS.modal
      id="rubric-editor-modal"
      on_close={evals_path(assigns, %{"edit_rubric" => nil})}
      width={640}
      title="Edit rubric"
      icon="note"
    >
      <.form
        for={@rubric_form}
        id="rubric-form"
        phx-change="rubric_change"
        phx-submit="save_rubric"
        phx-target={@myself}
        style="display:flex;flex-direction:column;gap:10px;"
      >
        <div>
          <div class="mono-label" style="margin-bottom:6px;">summary</div>
          <DS.ds_input
            id="rubric-summary"
            field={@rubric_form[:summary]}
            placeholder="What a good answer is."
            phx-debounce="300"
          />
        </div>

        <div>
          <div class="mono-label" style="margin-bottom:6px;">must never — one per line</div>
          <textarea
            id="rubric-must-never"
            name="rubric[must_never]"
            phx-debounce="300"
            class="ring-acc"
            style="width:100%;height:60px;background:var(--bg-1);border:1px solid var(--line);border-radius:var(--r);padding:9px 11px;color:var(--tx-0);font-size:13px;font-family:inherit;resize:none;outline:none;line-height:1.5;"
          >{@rubric_form[:must_never].value}</textarea>
        </div>

        <div :for={{level, field} <- level_fields()}>
          <div class="mono-label" style="margin-bottom:6px;">{level} ★</div>
          <DS.ds_input
            id={"rubric-#{field}"}
            field={@rubric_form[field]}
            placeholder={"What a #{level} looks like."}
            phx-debounce="300"
          />
        </div>
      </.form>
      <:footer>
        <DS.btn_link variant="ghost" patch={evals_path(assigns, %{"edit_rubric" => nil})}>
          Cancel
        </DS.btn_link>
        <DS.btn
          id="rubric-save"
          variant="primary"
          icon="save"
          style="margin-left:auto;"
          form="rubric-form"
          type="submit"
        >
          Save as v{next_number(@rubrics)}
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end

  defp next_number([]), do: 1
  defp next_number([%{number: number} | _rest]), do: number + 1

  defp evaluate_modal(assigns) do
    ~H"""
    <DS.modal
      id="evaluate-modal"
      on_close={evals_path(assigns, %{"evaluate" => nil})}
      width={520}
      title="Evaluate a revision"
      icon="flask"
    >
      <div style="display:flex;flex-direction:column;gap:12px;">
        <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;">
          <span class="mono-label">environment</span>
          <DS.seg
            id="evaluate-env"
            value={@env && @env.slug}
            options={
              Enum.map(
                @envs,
                &%{value: &1.slug, label: &1.slug, patch: evals_path(assigns, %{"env" => &1.slug})}
              )
            }
          />
        </div>

        <div style="display:flex;flex-direction:column;gap:2px;">
          <DS.kv label="revision">{revision_line(@live)}</DS.kv>
          <DS.kv label="rubric">{rubric_line(current_rubric(assigns))}</DS.kv>
          <DS.kv label="samples">{@evaluate_count}</DS.kv>
          <DS.kv label="judge">{Judge.model(current_rubric(assigns), @organization)}</DS.kv>
        </div>

        <div id="evaluate-eligible" style="font-size:12.5px;color:var(--tx-2);line-height:1.55;">
          {eligible_line(@evaluate_count, @organization)}
        </div>

        <div id="evaluate-cost" style="font-size:12.5px;color:var(--tx-3);">
          ≈ {cost_label(cost_estimate(@evaluate_count))} on your OpenRouter key
          ({Judge.model(current_rubric(assigns), @organization)}).
        </div>
      </div>
      <:footer>
        <DS.btn_link variant="ghost" patch={evals_path(assigns, %{"evaluate" => nil})}>Cancel</DS.btn_link>
        <span
          :if={@evaluate_blocker}
          id="evaluate-blocked"
          style="margin-left:auto;font-size:12.5px;color:var(--tx-3);text-align:right;"
        >
          {@evaluate_blocker}
          <.link
            :if={@evaluate_blocker == EditorTestRun.llm_error_message(:no_provider_key)}
            id="evaluate-providers-link"
            navigate={providers_path(assigns)}
            style="color:var(--link);"
          >
            Organization settings
          </.link>
        </span>
        <DS.btn
          :if={is_nil(@evaluate_blocker)}
          id="run-evaluation"
          variant="primary"
          icon="play"
          style="margin-left:auto;"
          phx-click="evaluate"
          phx-target={@myself}
        >
          Run evaluation
        </DS.btn>
      </:footer>
    </DS.modal>
    """
  end

  defp rubric_line(nil), do: "—"
  defp rubric_line(rubric), do: "v#{rubric.number}"

  defp revision_line(nil), do: "—"

  defp revision_line(deployment) do
    "##{deployment.revision} · " <>
      Calendar.strftime(deployment.inserted_at, "%Y-%m-%d %H:%M")
  end

  defp eligible_line(0, _organization), do: "No logs with stored payloads for this revision yet."

  defp eligible_line(count, organization) do
    limit = Entitlements.limit(organization, :evaluation_sample_limit)

    "#{count} of the last #{Entitlements.number(limit)} logs of this revision have stored payloads."
  end
end
