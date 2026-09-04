defmodule PromptOnWeb.PromptEditorLiveTest do
  @moduledoc """
  Tests for the use case hub screen (`PromptOnWeb.PromptEditorLive`).

  Covers: the one-column layout (models → prompt → arena → deployments), the **search-style model
  picker** (scans both sources together, multi-selects, registers catalog models on the spot, and
  is blocked without a key), the **arena's persistent history** (sending leaves user and assistant
  rows that a remount revives; per-pane and whole clears; failures are recorded too), **columns
  are exactly the selected models** (removing a model from its chip drops the column even when it
  has history, picking it again brings the conversation back, and the picker warns ahead with
  `has history`), the **messenger layout** (one scroll box wrapping every column plus sticky
  column heads plus the autoscroll hook; bubbles split left and right; a floating composer;
  `?full=1` full screen), URL state (`?tab` `?v` `?versions` `?diff` `?models` `?msort` `?deploy`
  `?ai` `?full`), **draft autosave** (edits survive a remount; no confirmation dialog; `?v=` is a
  read-only preview plus restore), **Deploy mints versions** (a changed draft → v(N+1); an
  unchanged one is reused; a past version mints nothing), the Deployments tab (rules, history,
  rollback), and access control.

  The arena calls the real `PromptOn.LLM`: the test environment adapter is `PromptOn.LLM.Fake`,
  so nothing touches the network and the response is derived deterministically from the request
  (`echo_requests/0` swaps it out).

  The model picker reads the OpenRouter list through `PromptOnWeb.ProviderCatalog`;
  `config :prompton, :provider_catalog_req_options` intercepts `Req`, so **no real HTTP happens**.
  The application environment is global, so this file is `async: false`.
  """
  use PromptOnWeb.ConnCase, async: false

  alias PromptOn.Catalog
  alias PromptOn.Deployments
  alias PromptOn.EvalsFixtures
  alias PromptOn.Fixtures
  alias PromptOn.Prompts

  # The pin label helpers are pure functions used by the hub's Deployments tab
  # (`PromptOnWeb.DeploymentsComponents`).
  doctest PromptOnWeb.DeploymentsComponents

  # The two bodies of the Integration section (curl, AI instructions) are pure functions verified
  # without a screen too.
  doctest PromptOnWeb.IntegrationComponents

  # The price display (`price_label/1`, `format_rate/1`) is a pure function verified without a
  # screen too.
  doctest PromptOnWeb.PromptEditorComponents

  @input_schema [%{name: "input", type: :string, required?: true}]

  # OpenRouter's `pricing` is a **dollars-per-token string** (`"0.000015"` = $15 per million
  # tokens).
  @openrouter_payload %{
    "data" => [
      %{
        "id" => "anthropic/claude-opus-4",
        "name" => "Anthropic: Claude Opus 4",
        "context_length" => 200_000,
        "created" => 1_745_000_000,
        "architecture" => %{"input_modalities" => ["text", "image"]},
        "supported_parameters" => ["tools"],
        "pricing" => %{"prompt" => "0.000015", "completion" => "0.000075"}
      },
      %{
        "id" => "openai/o4-mini",
        "name" => "OpenAI: o4 mini",
        "context_length" => 128_000,
        "created" => 1_744_000_000,
        "pricing" => %{"prompt" => "0.0000011", "completion" => "0.0000044"}
      }
    ]
  }

  # Catalog for sorting: prices, listing times and context lengths were chosen so they produce
  # **different orders** (so one sort never coincides with another sort's result by accident).
  @sort_payload %{
    "data" => [
      %{
        "id" => "x/unknown",
        "name" => "Xray unknown",
        "pricing" => %{"prompt" => "-1", "completion" => "-1"}
      },
      %{
        "id" => "y/pricey",
        "name" => "Yankee pricey",
        "context_length" => 1_000_000,
        "created" => 1_800_000_000,
        "pricing" => %{"prompt" => "0.00002", "completion" => "0.00003"}
      },
      %{
        "id" => "z/cheap",
        "name" => "Zeta cheap",
        "context_length" => 8_000,
        "created" => 1_700_000_000,
        "pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000002"}
      }
    ]
  }

  setup do
    stub_openrouter(@openrouter_payload)
    :ok
  end

  defp stub_openrouter(payload) do
    Application.put_env(:prompton, :provider_catalog_req_options,
      plug: fn conn -> Req.Test.json(conn, payload) end
    )

    on_exit(fn ->
      Application.put_env(:prompton, :provider_catalog_req_options,
        plug: fn conn -> Req.Test.json(conn, %{"data" => []}) end
      )
    end)
  end

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", name: "Acme"})

    use_case =
      Fixtures.use_case_fixture(project, %{
        key: "diary_generation",
        input_schema: @input_schema
      })

    v1 = Fixtures.prompt_version_fixture(use_case, %{commit_message: "First version"})

    %{
      conn: log_in_user(conn, user),
      user: user,
      project: project,
      use_case: use_case,
      prompt: Fixtures.default_prompt(use_case),
      v1: v1
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp hub_path(project, use_case, params \\ []) do
    ~p"/personal/#{project.slug}/use-cases/#{use_case.key}/prompt?#{params}"
  end

  # The arena (model row, columns, input box) lives at `?tab=arena`; the Editor tab holds only
  # prompt editing.
  defp arena_path(project, use_case, params \\ []),
    do: hub_path(project, use_case, [tab: "arena"] ++ params)

  defp scope(project), do: Fixtures.scope(project)

  # A finished evaluation of one revision: eligible logs, a rubric, a run, and the frozen counters
  # the tally writes. Enough for the score badge, which reads nothing else.
  defp evaluate(project, use_case, deployment) do
    Fixtures.stored_generations_fixture(project, use_case, 5, %{
      "deployment_id" => deployment.id,
      "deployment_revision" => deployment.revision
    })

    with_key(project)
    rubric = EvalsFixtures.rubric_fixture(use_case)
    run = EvalsFixtures.evaluation_run_fixture(use_case, deployment, %{rubric: rubric})
    opts = [tenant: project.id, actor: Fixtures.system_actor()]

    {:ok, tallied} =
      run
      |> Ash.Changeset.for_update(
        :record_tally,
        %{
          scored_count: 5,
          unparsable_count: 0,
          failed_count: 0,
          average_score: Decimal.new("4.20"),
          score_distribution: %{"4" => 4, "5" => 1},
          cost_usd: Decimal.new("0.01")
        },
        opts
      )
      |> Ash.update()

    {:ok, completed} =
      tallied |> Ash.Changeset.for_update(:complete, %{}, opts) |> Ash.update()

    completed
  end

  defp two_models(project) do
    {Fixtures.model_fixture(project, %{model_id: "m/a", display_name: "Model A"}),
     Fixtures.model_fixture(project, %{model_id: "m/b", display_name: "Model B"})}
  end

  # BYOK keys are **owned by the organization** (2026-09-01): they attach to the project's
  # organization, not to the project.
  defp with_key(project),
    do: Fixtures.provider_key_fixture(project, provider: :openrouter, secret: "sk-or-seed")

  # The **order** of the rendered picker rows (`#pick-row-<dom-id>`): the contract of the sort
  # tests is the list order.
  defp picker_order(view) do
    ~r/id="pick-row-([^"]+)"/
    |> Regex.scan(render(view))
    |> Enum.map(&List.last/1)
  end

  # The sorting stage: mixes one project model into the three OpenRouter rows (@sort_payload).
  # The project model's price and context both sit **between** two catalog rows, so whether the
  # sort interleaves the two sources becomes visible.
  defp sort_stage(project) do
    stub_openrouter(@sort_payload)

    Fixtures.model_fixture(project, %{
      model_id: "m/mid",
      display_name: "Mid model",
      context_length: 32_000,
      pricing: %{
        "input_per_m" => 5.0,
        "output_per_m" => 9.0,
        "currency" => "USD",
        "unit" => "token"
      }
    })
  end

  # Pins the arena columns ahead of time (for tests that skip the picker).
  defp pin(use_case, models) do
    {:ok, updated} =
      Prompts.set_use_case_arena_models(
        use_case,
        %{arena_model_ids: Enum.map(models, & &1.id)},
        scope(%{id: use_case.project_id})
      )

    updated
  end

  defp arena_rows(use_case) do
    {:ok, messages} =
      Prompts.arena_messages_for_use_case(use_case.id,
        tenant: use_case.project_id,
        actor: Fixtures.system_actor()
      )

    messages
  end

  defp commit_v2(use_case, attrs \\ %{}) do
    Fixtures.prompt_version_fixture(
      use_case,
      Map.merge(
        %{
          commit_message: "Second",
          messages: [
            %{role: :system, content: "You are a diary editor."},
            %{role: :user, content: "{{ input }}"}
          ]
        },
        attrs
      )
    )
  end

  # The draft sitting in the DB (`Prompt.draft`): whether autosave actually **wrote** is told by
  # the table, not the screen.
  defp reload_draft(prompt) do
    {:ok, reloaded} =
      Prompts.get_prompt(prompt.id, tenant: prompt.project_id, actor: Fixtures.system_actor())

    reloaded.draft
  end

  # The **order** of the Deploy modal radios (`#deploy-model-<id>`): the list order is the
  # contract.
  defp model_order(view) do
    ~r/id="deploy-model-([0-9a-f-]{36})"/
    |> Regex.scan(render(view))
    |> Enum.map(&List.last/1)
  end

  defp versions(prompt) do
    {:ok, versions} =
      Prompts.list_prompt_versions(prompt.id,
        tenant: prompt.project_id,
        actor: Fixtures.system_actor()
      )

    Enum.sort_by(versions, & &1.number)
  end

  # A Fake that echoes the request back: model, message count and last message reveal fan-out and
  # conversation accumulation.
  defp echo_requests do
    PromptOn.LLM.Fake.set_response(fn request ->
      last = request.messages |> List.last() |> Map.get("content")

      {:ok,
       %{
         PromptOn.LLM.Fake.default_outcome(request)
         | content: "#{request.model}|n=#{length(request.messages)}|last=#{last}"
       }}
    end)

    on_exit(&PromptOn.LLM.Fake.reset/0)
  end

  defp fill_vars(view, values),
    do: view |> form("#arena-vars-form", vars: values) |> render_change()

  defp send_message(view, text) do
    view |> form("#arena-send-form", send: %{"input" => text}) |> render_submit()
    render_async(view)
  end

  defp run_text(view) do
    view |> form("#arena-send-form") |> render_submit()
    render_async(view)
  end

  defp column(view, %{id: id}), do: view |> element("#arena-column-#{id}") |> render()

  # How many times a fragment occurs in the render: counts the things whose contract is "exactly
  # one" (the scroll box, the hook).
  defp occurrences(html, needle), do: length(String.split(html, needle)) - 1

  # ---------------------------------------------------------------------------

  describe "hub layout" do
    test "the Editor tab holds only prompt editing (the arena is the next tab)", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      assert has_element?(view, "#use-case-hub")
      assert has_element?(view, "#prompt-editor-form")
      assert has_element?(view, "#message-0-content")
      assert has_element?(view, "#detected-variables")
      assert has_element?(view, "#kind-badge")
      assert has_element?(view, "#draft-badge")

      # The arena is not on this tab.
      refute has_element?(view, "#arena-models")
      refute has_element?(view, "#arena")

      # There is no "save" verb: edits autosave and versions are born from Deploy.
      refute has_element?(view, "#unsaved-badge")
      refute has_element?(view, "#save-version")
      refute has_element?(view, "#commit-message")
      refute render(view) =~ "data-confirm"
    end

    test "the version list is a drawer (?versions=1)", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      refute has_element?(view, "#versions-drawer")
      assert has_element?(view, "#open-versions", "History")

      view |> element("#open-versions") |> render_click()

      assert_patch(view, hub_path(project, use_case, versions: 1))
      assert has_element?(view, "#versions-drawer")
      # The default selection is the **draft**; committed versions are the rows below it.
      assert has_element?(view, "#version-row-draft.is-selected")
      assert has_element?(view, "#version-row-1")
      refute has_element?(view, "#version-row-1.is-selected")
    end

    test "the header sub states the version count and the live revision", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      v2 = commit_v2(use_case)

      Fixtures.simple_deployment_fixture(use_case, Fixtures.environment(project), %{
        prompt_version: v2
      })

      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      assert render(view) =~ "2 versions · latest v2"
      assert render(view) =~ "live production #1"
    end
  end

  # The hub has three tabs: the place to write the prompt (Editor) and the place to pit models
  # against each other (Arena) are separated. The tab is carried by the URL (the CLAUDE.md
  # zero-downtime deployment discipline).
  describe "three tabs (?tab=)" do
    test "three tabs stand and each renders only its own content", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {model_a, _b} = two_models(project)
      pin(use_case, [model_a])

      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      for id <- ~w(editor arena deployments) do
        assert has_element?(view, "#tab-#{id}")
      end

      # The default is Editor: prompt editing only.
      assert has_element?(view, "#tab-editor.is-active")
      assert has_element?(view, "#prompt-editor-form")
      assert has_element?(view, "#declared-variables")
      refute has_element?(view, "#arena-models")

      view |> element("#tab-arena") |> render_click()
      assert_patch(view, arena_path(project, use_case))

      assert has_element?(view, "#tab-arena.is-active")
      assert has_element?(view, "#arena-tab")
      assert has_element?(view, "#arena-models")
      assert has_element?(view, "#arena")
      refute has_element?(view, "#prompt-editor-form")

      view |> element("#tab-deployments") |> render_click()

      assert has_element?(view, "#deployments-tab")
      refute has_element?(view, "#arena")
      refute has_element?(view, "#prompt-editor-form")
    end

    test "an unknown tab folds into Editor", %{conn: conn, project: project, use_case: use_case} do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, tab: "nope"))

      assert has_element?(view, "#tab-editor.is-active")
      assert has_element?(view, "#prompt-editor-form")
      refute has_element?(view, "#arena-models")
    end

    test "a ?tab=deployments deep link opens as is", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, tab: "deployments"))

      assert has_element?(view, "#tab-deployments.is-active")
      assert has_element?(view, "#deployments-tab")
      assert has_element?(view, "#dep-env-seg")
    end

    test "the arena runs at ?tab=arena: the fan-out and the picker that keeps the tab", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      echo_requests()
      with_key(project)
      {model_a, model_b} = two_models(project)
      use_case = pin(use_case, [model_a, model_b])

      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})
      send_message(view, "sent from the tab too")

      assert column(view, model_a) =~ "m/a|n=3"
      assert column(view, model_b) =~ "m/b|n=3"
      assert length(arena_rows(use_case)) == 4

      # The picker is a modal stacked **on top of** the tab parameter: opening, re-sorting and
      # closing all stay on Arena.
      view |> element("#open-model-picker") |> render_click()
      assert_patch(view, arena_path(project, use_case, models: 1))
      assert has_element?(view, "#model-picker-modal")

      view |> element("#model-sort-cheapest") |> render_click()
      path = assert_patch(view)
      assert path =~ "tab=arena"
      assert path =~ "msort=cheapest"

      view |> element("#model-picker-cancel") |> render_click()
      assert_patch(view, arena_path(project, use_case))
      refute has_element?(view, "#model-picker-modal")
      assert has_element?(view, "#arena-tab")
    end
  end

  describe "model picker (?models=1): search" do
    test "one search box scans both sources together", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      two_models(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      # two from the project catalog + two from OpenRouter
      assert has_element?(view, "#pick-row-m-a") or has_element?(view, "#model-picker-results")
      assert render(view) =~ "Model A"
      assert render(view) =~ "anthropic/claude-opus-4"
      assert render(view) =~ "openai/o4-mini"

      html =
        view |> form("#model-search-form", picker: %{"q" => "claude"}) |> render_change()

      assert html =~ "anthropic/claude-opus-4"
      refute html =~ "Model A"
      refute html =~ "openai/o4-mini"

      html = view |> form("#model-search-form", picker: %{"q" => "m/b"}) |> render_change()

      assert html =~ "Model B"
      refute html =~ "anthropic/claude-opus-4"
    end

    test "says so when the search has no results", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      view |> form("#model-search-form", picker: %{"q" => "zzzz"}) |> render_change()

      assert has_element?(view, "#model-picker-empty")
    end
  end

  describe "model picker: price per million tokens" do
    test "rows carry input/output prices (per-token catalog values become per-million)", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      priced =
        Fixtures.model_fixture(project, %{
          model_id: "m/priced",
          display_name: "Priced model",
          pricing: %{
            "input_per_m" => 0.15,
            "output_per_m" => 2.5,
            "currency" => "USD",
            "unit" => "token"
          }
        })

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      assert view |> element("#pick-price-#{priced.id}") |> render() =~ "$0.15 / $2.50 per 1M"

      # OpenRouter: "0.000015"/"0.000075" per token → $15/$75 per million tokens.
      assert view |> element("#pick-price-anthropic-claude-opus-4") |> render() =~
               "$15.00 / $75.00 per 1M"

      # Sub-cent values do not vanish through rounding either ("0.0000011" → $1.10).
      assert view |> element("#pick-price-openai-o4-mini") |> render() =~ "$1.10 / $4.40 per 1M"
    end

    test "an unknown price is —", %{conn: conn, project: project, use_case: use_case} do
      unpriced =
        Fixtures.model_fixture(project, %{
          model_id: "m/unpriced",
          display_name: "Unpriced model",
          pricing: %{}
        })

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      price = view |> element("#pick-price-#{unpriced.id}") |> render()
      assert price =~ "—"
      refute price =~ "$"
    end

    test "the arena column head also states only known prices", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      priced = Fixtures.model_fixture(project, %{model_id: "m/p", display_name: "Priced"})

      unpriced =
        Fixtures.model_fixture(project, %{
          model_id: "m/u",
          display_name: "Unpriced",
          pricing: %{}
        })

      use_case = pin(use_case, [priced, unpriced])

      {:ok, view, _html} = live(conn, arena_path(project, use_case))

      assert view |> element("#arena-column-price-#{priced.id}") |> render() =~
               "$3.00 / $15.00 per 1M"

      refute has_element?(view, "#arena-column-price-#{unpriced.id}")
    end
  end

  # Models registered before price storage existed (and the import path that registers without a
  # price) have an empty `Model.pricing`: if the catalog has the same `(openrouter, model_id)`,
  # that is the answer.
  describe "model picker: fills an empty stored price from the catalog" do
    test "the picker row and the arena column head use the catalog price", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      stale =
        Fixtures.model_fixture(project, %{
          model_id: "anthropic/claude-opus-4",
          display_name: "Claude Opus 4",
          pricing: %{}
        })

      use_case = pin(use_case, [stale])

      {:ok, view, _html} = live(conn, arena_path(project, use_case, models: 1))
      render_async(view)

      assert view |> element("#pick-price-#{stale.id}") |> render() =~ "$15.00 / $75.00 per 1M"

      assert view |> element("#arena-column-price-#{stale.id}") |> render() =~
               "$15.00 / $75.00 per 1M"
    end

    test "it does not just fill the screen but stores it too (idempotent)", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      stale =
        Fixtures.model_fixture(project, %{
          model_id: "anthropic/claude-opus-4",
          display_name: "Claude Opus 4",
          pricing: %{}
        })

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      {:ok, backfilled} = Catalog.get_model(stale.id, scope(project))

      assert backfilled.pricing == %{
               "input_per_m" => 15.0,
               "output_per_m" => 75.0,
               "currency" => "USD",
               "unit" => "token"
             }

      # Ingest cost estimation now works right away.
      assert Decimal.equal?(
               Catalog.Model.estimate_cost(backfilled, 1_000_000, 1_000_000),
               Decimal.new(90)
             )

      # Opening it again gives the same value (nothing is written when there is nothing to fill).
      {:ok, again, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(again)

      {:ok, reloaded} = Catalog.get_model(stale.id, scope(project))
      assert reloaded.pricing == backfilled.pricing
      assert reloaded.updated_at == backfilled.updated_at
    end

    test "a model missing from the catalog is still —", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      orphan =
        Fixtures.model_fixture(project, %{
          model_id: "m/nowhere",
          display_name: "Nowhere",
          pricing: %{}
        })

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      price = view |> element("#pick-price-#{orphan.id}") |> render()
      assert price =~ "—"
      refute price =~ "$"

      {:ok, unchanged} = Catalog.get_model(orphan.id, scope(project))
      assert unchanged.pricing == %{}
    end

    test "dynamic pricing (-1) is not filled in: an unknown value is not 0", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      stub_openrouter(%{
        "data" => [
          %{
            "id" => "openrouter/auto",
            "name" => "Auto router",
            "pricing" => %{"prompt" => "-1", "completion" => "-1"}
          }
        ]
      })

      dynamic =
        Fixtures.model_fixture(project, %{
          model_id: "openrouter/auto",
          display_name: "Auto router",
          pricing: %{}
        })

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      assert view |> element("#pick-price-#{dynamic.id}") |> render() =~ "—"

      {:ok, unchanged} = Catalog.get_model(dynamic.id, scope(project))
      assert unchanged.pricing == %{}
    end

    test "a free model is $0 (0 and unknown are different)", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      stub_openrouter(%{
        "data" => [
          %{
            "id" => "vendor/free",
            "name" => "Free model",
            "pricing" => %{"prompt" => "0", "completion" => "0"}
          }
        ]
      })

      free =
        Fixtures.model_fixture(project, %{
          model_id: "vendor/free",
          display_name: "Free model",
          pricing: %{}
        })

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      assert view |> element("#pick-price-#{free.id}") |> render() =~ "$0 / $0 per 1M"

      {:ok, backfilled} = Catalog.get_model(free.id, scope(project))
      assert backfilled.pricing["input_per_m"] == 0.0
      assert backfilled.pricing["output_per_m"] == 0.0
    end
  end

  describe "model picker: sorting (?msort)" do
    test "the default is Relevance: the project catalog first, then OpenRouter", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      mid = sort_stage(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      assert picker_order(view) == [mid.id, "x-unknown", "y-pricey", "z-cheap"]
      assert has_element?(view, "#model-sort-relevance.on")
    end

    test "Cheapest interleaves both sources and pushes unknown prices to the back", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      mid = sort_stage(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1, msort: "cheapest"))
      render_async(view)

      # $0.10 (catalog) < $5.00 (project) < $20.00 (catalog) < unknown
      assert picker_order(view) == ["z-cheap", mid.id, "y-pricey", "x-unknown"]
      assert has_element?(view, "#model-sort-cheapest.on")
    end

    test "Newest is listing time descending and rows with unknown time go last", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      mid = sort_stage(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1, msort: "newest"))
      render_async(view)

      # The project model has no listing time: it goes to the back with `x/unknown`, and between
      # those two the default order holds.
      assert picker_order(view) == ["y-pricey", "z-cheap", mid.id, "x-unknown"]
    end

    test "Context is context length descending and unknown rows go last", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      mid = sort_stage(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1, msort: "context"))
      render_async(view)

      # 1M > 32k (project) > 8k > unknown
      assert picker_order(view) == ["y-pricey", mid.id, "z-cheap", "x-unknown"]
    end

    test "an unknown msort folds into Relevance", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      mid = sort_stage(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1, msort: "bananas"))
      render_async(view)

      assert picker_order(view) == [mid.id, "x-unknown", "y-pricey", "z-cheap"]
      assert has_element?(view, "#model-sort-relevance.on")
    end

    test "the sort is carried by the URL: applied via patch and revived by a remount", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      mid = sort_stage(project)
      cheapest = ["z-cheap", mid.id, "y-pricey", "x-unknown"]

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      view |> element("#model-sort-cheapest") |> render_click()
      path = assert_patch(view)

      assert path =~ "msort=cheapest"
      assert path =~ "models=1"
      assert picker_order(view) == cheapest

      # Even when a deployment drops the socket and remounts, it must be the same screen.
      {:ok, remounted, _html} = live(conn, path)
      render_async(remounted)

      assert picker_order(remounted) == cheapest
      assert has_element?(remounted, "#model-sort-cheapest.on")
    end

    test "closing the picker drops ?msort from the URL too", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      sort_stage(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1, msort: "cheapest"))
      render_async(view)

      view |> element("#model-picker-cancel") |> render_click()
      path = assert_patch(view)

      refute path =~ "msort"
      refute path =~ "models"
      refute has_element?(view, "#model-picker-modal")
    end

    test "the 50-row cap applies **after** sorting", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      # By name (= Relevance) the row pushed past the 50th place is the cheapest one.
      stub_openrouter(%{
        "data" =>
          for n <- 1..60 do
            %{
              "id" => "bulk/m#{n}",
              "name" => "Bulk #{n}",
              "pricing" => %{
                "prompt" => :erlang.float_to_binary((61 - n) / 1_000_000, decimals: 8)
              }
            }
          end
      })

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      refute has_element?(view, "#pick-row-bulk-m60")
      assert length(picker_order(view)) == 50

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1, msort: "cheapest"))
      render_async(view)

      order = picker_order(view)

      assert List.first(order) == "bulk-m60"
      assert length(order) == 50
      assert view |> element("#model-picker-truncated") |> render() =~ "10 more"
    end
  end

  describe "ProviderCatalog: per token → per million tokens" do
    test "does not die on odd values and unknown is nil", _context do
      stub_openrouter(%{
        "data" => [
          %{
            "id" => "a/normal",
            "pricing" => %{"prompt" => "0.000003", "completion" => "0.000015"}
          },
          %{"id" => "b/sub-cent", "pricing" => %{"prompt" => "0.0000015"}},
          # OpenRouter gives dynamic pricing as "-1": not a price but "unknown".
          %{"id" => "c/dynamic", "pricing" => %{"prompt" => "-1", "completion" => "-1"}},
          # A free model is a genuine 0 (0 and "unknown" are different).
          %{"id" => "d/free", "pricing" => %{"prompt" => "0", "completion" => "0"}},
          %{"id" => "e/garbage", "pricing" => %{"prompt" => "abc", "completion" => nil}},
          %{"id" => "f/not-a-map", "pricing" => "cheap"},
          %{"id" => "g/absent"}
        ]
      })

      {:ok, models} = PromptOnWeb.ProviderCatalog.list_openrouter_models()
      pricing = Map.new(models, &{&1.model_id, &1.pricing})

      assert pricing["a/normal"] == %{input_per_m: 3.0, output_per_m: 15.0}
      assert pricing["b/sub-cent"] == %{input_per_m: 1.5, output_per_m: nil}
      assert pricing["c/dynamic"] == %{input_per_m: nil, output_per_m: nil}
      assert pricing["d/free"] == %{input_per_m: 0.0, output_per_m: 0.0}
      assert pricing["e/garbage"] == %{input_per_m: nil, output_per_m: nil}
      assert pricing["f/not-a-map"] == %{input_per_m: nil, output_per_m: nil}
      assert pricing["g/absent"] == %{input_per_m: nil, output_per_m: nil}
    end

    test "created is Unix seconds and nil when unknown", _context do
      stub_openrouter(%{
        "data" => [
          %{"id" => "a/created", "created" => 1_700_000_000},
          %{"id" => "b/string", "created" => "1700000001"},
          # 0, negative and non-numeric are "unknown" (left as 0, the model would date from 1970).
          %{"id" => "c/zero", "created" => 0},
          %{"id" => "d/garbage", "created" => "soon"},
          %{"id" => "e/absent"}
        ]
      })

      {:ok, models} = PromptOnWeb.ProviderCatalog.list_openrouter_models()
      created = Map.new(models, &{&1.model_id, &1.created})

      assert created["a/created"] == 1_700_000_000
      assert created["b/string"] == 1_700_000_001
      assert created["c/zero"] == nil
      assert created["d/garbage"] == nil
      assert created["e/absent"] == nil
    end

    test "0 is $0 and unknown is —", _context do
      alias PromptOnWeb.PromptEditorComponents, as: Components

      assert Components.price_label(%{input_per_m: 0.0, output_per_m: 0.0}) == "$0 / $0 per 1M"
      assert Components.price_label(%{input_per_m: nil, output_per_m: nil}) == "—"
      assert Components.price_label(nil) == "—"
      assert Components.format_rate("-1") == "—"
      assert Components.format_rate(1.5) == "$1.50"
      assert Components.format_rate(0.0000015) == "$0.0000015"
    end
  end

  describe "with no model at all" do
    test "the arena becomes a single CTA and there is no input row at all", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)

      assert has_element?(view, "#arena-empty-cta")
      assert render(view) =~ "No models selected"
      refute has_element?(view, "#arena-send-form")
      refute has_element?(view, "#arena-send")
      refute has_element?(view, "#arena-blocked")

      # "Add models" is primary and the CTA button opens the same picker.
      assert has_element?(view, "#open-model-picker.dsbtn-primary")

      view |> element("#arena-empty-add") |> render_click()
      assert_patch(view, arena_path(project, use_case, models: 1))
      assert has_element?(view, "#model-picker-modal")
    end

    test "without a key Send is blocked and points to the organization settings", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {model_a, _b} = two_models(project)
      use_case = pin(use_case, [model_a])

      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      fill_vars(view, %{"input" => "diary"})

      assert has_element?(view, "#arena-send[disabled]")
      assert view |> element("#arena-blocked") |> render() =~ "Organization settings"

      # Once the organization has a key it opens as is: keys are owned by the organization, not
      # registered on this project.
      with_key(project)
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      fill_vars(view, %{"input" => "diary"})

      refute has_element?(view, "#arena-send[disabled]")
      refute has_element?(view, "#arena-blocked")
    end

    test "with at least one model there is no CTA and Add models goes quiet", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {model_a, _b} = two_models(project)
      use_case = pin(use_case, [model_a])

      {:ok, view, _html} = live(conn, arena_path(project, use_case))

      refute has_element?(view, "#arena-empty-cta")
      assert has_element?(view, "#arena-send-form")
      assert has_element?(view, "#open-model-picker.dsbtn-outline")
    end

    # The arena's empty CTA sits at the bottom of the screen, so it is not noticed while writing
    # the prompt.
    test "a red warning also stands on the model row (the CTA stays)", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))

      warning = view |> element("#no-model-warning") |> render()

      assert warning =~ "No model selected"
      assert warning =~ "add at least one to test this prompt"
      assert warning =~ "var(--err)"

      # The warning is inside the model row (where the user is looking).
      assert view |> element("#arena-models") |> render() =~ "no-model-warning"
      assert has_element?(view, "#arena-empty-cta")
    end

    test "the warning disappears once there is at least one model", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {model_a, _b} = two_models(project)
      use_case = pin(use_case, [model_a])

      {:ok, view, _html} = live(conn, arena_path(project, use_case))

      refute has_element?(view, "#no-model-warning")
    end
  end

  # ADR 0007: named prompt documents under a use case (the word "lineage" appears neither on
  # screen nor in the URL).
  describe "prompt switching (?prompt=)" do
    test "the switcher row moves via ?prompt= and the default prompt leaves the URL empty", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, _ko} =
        Prompts.open_prompt(%{use_case_id: use_case.id, name: "ko"}, scope(project))

      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      assert has_element?(view, "#prompt-switcher")
      assert view |> element("#prompt-switcher") |> render() =~ "Prompts"
      assert has_element?(view, "#prompt-default.on")

      view |> element("#prompt-ko") |> render_click()

      assert_patch(view, hub_path(project, use_case, prompt: "ko"))
      assert has_element?(view, "#prompt-ko.on")
      assert page_title(view) =~ "diary_generation (ko)"

      view |> element("#prompt-default") |> render_click()
      assert_patch(view, hub_path(project, use_case))
    end

    test "the new prompt modal is ?new_prompt=1 and creating moves to that prompt", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      refute has_element?(view, "#new-prompt-modal")
      assert view |> element("#new-prompt") |> render() =~ "New prompt"

      view |> element("#new-prompt") |> render_click()

      assert_patch(view, hub_path(project, use_case, new_prompt: 1))
      assert has_element?(view, "#new-prompt-modal")
      assert has_element?(view, "#new-prompt-name")
      assert has_element?(view, "#new-prompt-description")
      assert view |> element("#create-prompt") |> render() =~ "Create prompt"

      view
      |> form("#new-prompt-form", prompt: %{"name" => "ko", "description" => "Korean prompt"})
      |> render_submit()

      assert_patch(view, hub_path(project, use_case, prompt: "ko"))
      assert render(view) =~ "Prompt ko created — write its first version."
      assert has_element?(view, "#prompt-ko.on")

      {:ok, prompts} = Prompts.list_prompts(use_case.id, scope(project))
      assert Enum.any?(prompts, &(&1.name == "ko"))
    end

    test "the word lineage appears neither on screen nor in the URL", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, new_prompt: 1))

      html = render(view)

      refute html =~ "lineage"
      refute html =~ "Lineage"
    end
  end

  describe "model picker: multi-select, registration, BYOK" do
    # The key input field is gone from the picker (2026-09-01): keys are owned by the organization,
    # and the one place to enter them is the organization settings.
    test "without a key only a pointer to organization settings remains (no inline input)", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {model_a, _b} = two_models(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      assert has_element?(view, "#picker-no-key")
      refute has_element?(view, "#picker-byok")
      refute has_element?(view, "#picker-key-form")

      assert has_element?(
               view,
               "#picker-providers-link[href='/personal/settings?tab=providers']"
             )

      # **Models can still be added** without a key: what is blocked is running, and the arena
      # says so.
      view |> element("#pick-#{model_a.id}") |> render_click()
      assert render(view) =~ "1 selected"
      refute has_element?(view, "#add-models[disabled]")
    end

    test "Add is blocked when no model is picked", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      two_models(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      assert has_element?(view, "#add-models[disabled]")
    end

    test "with a key already present the connected marker replaces the pointer", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      with_key(project)
      two_models(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      assert has_element?(view, "#picker-key-ok")
      refute has_element?(view, "#picker-no-key")
    end

    test "several are picked at once and catalog models are registered on the spot", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      with_key(project)
      {model_a, _b} = two_models(project)

      {:ok, view, _html} = live(conn, arena_path(project, use_case, models: 1))
      render_async(view)

      view |> element("#pick-#{model_a.id}") |> render_click()
      view |> element("#pick-anthropic-claude-opus-4") |> render_click()
      assert render(view) =~ "2 selected"

      # The picker is a modal stacked on top of the tab parameter, so it closes onto the Arena tab.
      view |> element("#add-models") |> render_click()
      assert_patch(view, arena_path(project, use_case))

      assert has_element?(view, "#arena-model-chip-#{model_a.id}")
      assert render(view) =~ "Claude Opus 4"

      {:ok, models} = Catalog.list_models(scope(project))
      registered = Enum.find(models, &(&1.model_id == "anthropic/claude-opus-4"))
      assert registered
      assert registered.display_name == "Anthropic: Claude Opus 4"

      # The price the catalog reported is planted as is, so `estimate_cost/3` works right away.
      assert registered.pricing == %{
               "input_per_m" => 15.0,
               "output_per_m" => 75.0,
               "currency" => "USD",
               "unit" => "token"
             }

      assert Decimal.equal?(
               Catalog.Model.estimate_cost(registered, 1_000_000, 1_000_000),
               Decimal.new(90)
             )

      # The selection attaches to the use case (`arena_model_ids`): the columns survive a remount.
      {:ok, reloaded} =
        Prompts.get_use_case_by_key("diary_generation",
          tenant: project.id,
          actor: Fixtures.system_actor()
        )

      assert length(reloaded.arena_model_ids) == 2
      assert model_a.id in reloaded.arena_model_ids
    end

    test "a model already in the arena cannot be toggled", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      with_key(project)
      {model_a, _b} = two_models(project)
      pin(use_case, [model_a])

      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      assert has_element?(view, "#pick-#{model_a.id}[disabled]")
    end

    test "a chip's x drops only the column", %{conn: conn, project: project, use_case: use_case} do
      {model_a, model_b} = two_models(project)
      pin(use_case, [model_a, model_b])

      {:ok, view, _html} = live(conn, arena_path(project, use_case))

      assert has_element?(view, "#arena-model-chip-#{model_b.id}")
      view |> element("#remove-arena-model-#{model_b.id}") |> render_click()
      refute has_element?(view, "#arena-model-chip-#{model_b.id}")
      assert has_element?(view, "#arena-model-chip-#{model_a.id}")
    end
  end

  describe "arena: persistent history (kind :chat)" do
    setup %{project: project, use_case: use_case} do
      echo_requests()
      with_key(project)
      {model_a, model_b} = two_models(project)
      %{use_case: pin(use_case, [model_a, model_b]), model_a: model_a, model_b: model_b}
    end

    test "one send goes to every column and leaves user and assistant rows", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a,
      model_b: model_b
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})

      send_message(view, "first question")

      assert column(view, model_a) =~ "first question"
      assert column(view, model_a) =~ "m/a|n=3"
      assert column(view, model_b) =~ "m/b|n=3"

      rows = arena_rows(use_case)
      assert length(rows) == 4

      by_model = Enum.group_by(rows, & &1.model_id)

      assert [%{role: :user, content: "first question"}, %{role: :assistant, status: :ok}] =
               by_model[model_a.id]

      assistant = by_model[model_a.id] |> List.last()
      assert assistant.prompt_version_number == 1
      assert assistant.latency_ms
      assert assistant.input_tokens
      assert assistant.output_tokens
    end

    test "the past conversation is still there after a remount", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})
      send_message(view, "remember this")

      {:ok, again, _html} = live(conn, arena_path(project, use_case))
      render_async(again)

      assert column(again, model_a) =~ "remember this"
      assert column(again, model_a) =~ "m/a|n=3"
    end

    test "the request is the rendered buffer ++ that pane's past turns ++ the new turn", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})

      send_message(view, "one")
      send_message(view, "two")

      # system + user (rendered) + two past user/assistant + new user = 5
      assert column(view, model_a) =~ "m/a|n=5|last=two"
    end

    test "a failed turn is recorded with status :error too", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a
    } do
      PromptOn.LLM.Fake.set_response({:error, {:http_error, 500, "boom"}})
      on_exit(&PromptOn.LLM.Fake.reset/0)

      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})
      send_message(view, "will it work")

      assert column(view, model_a) =~ "Provider responded HTTP 500"

      failed =
        use_case
        |> arena_rows()
        |> Enum.filter(&(&1.role == :assistant and &1.model_id == model_a.id))
        |> List.last()

      assert failed.status == :error
      assert failed.content == ""
      assert failed.error_message =~ "500"
    end

    test "per-pane clear empties only that model and Clear history empties everything", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a,
      model_b: model_b
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})
      send_message(view, "here it is")

      view |> element("#clear-column-#{model_a.id}") |> render_click()

      refute column(view, model_a) =~ "here it is"
      assert column(view, model_b) =~ "here it is"
      assert Enum.all?(arena_rows(use_case), &(&1.model_id == model_b.id))

      view |> element("#clear-arena") |> render_click()

      assert arena_rows(use_case) == []
      refute column(view, model_b) =~ "here it is"
    end

    test "editing the prompt keeps the history and only adds a quiet one-liner", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})
      send_message(view, "must remain")

      # Switching tabs is a patch, so it is the same LiveView: edit on the Editor tab, see the
      # result on the Arena tab.
      view |> element("#tab-editor") |> render_click()

      view
      |> form("#prompt-editor-form",
        editor: %{
          "messages" => %{
            "0" => %{"role" => "system", "content" => "A completely different prompt"},
            "1" => %{"role" => "user", "content" => "{{ input }}"}
          }
        }
      )
      |> render_change()

      view |> element("#tab-arena") |> render_click()

      assert column(view, model_a) =~ "must remain"
      assert has_element?(view, "#arena-notice")
      assert render(view) =~ "history is kept"
      # two columns × (user + assistant): editing erases nothing.
      assert length(arena_rows(use_case)) == 4
    end

    test "the version number is stamped only while the draft equals the latest commit", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})

      # An untouched draft = v1 as is → the number is stamped.
      send_message(view, "clean run")

      assert use_case
             |> arena_rows()
             |> Enum.filter(&(&1.role == :assistant))
             |> Enum.all?(&(&1.prompt_version_number == 1))

      # Change a single character and there is no version to point at → nil (a draft is not a
      # version).
      view |> element("#tab-editor") |> render_click()

      view
      |> form("#prompt-editor-form",
        editor: %{"messages" => %{"0" => %{"role" => "system", "content" => "An edited prompt"}}}
      )
      |> render_change()

      view |> element("#tab-arena") |> render_click()

      send_message(view, "edited run")

      assert use_case
             |> arena_rows()
             |> Enum.filter(&(&1.role == :assistant))
             |> List.last()
             |> Map.fetch!(:prompt_version_number) == nil
    end

    test "Send is blocked while a required variable is empty", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)

      assert has_element?(view, "#arena-send[disabled]")
      assert render(view) =~ "Fill in required variables: input"

      fill_vars(view, %{"input" => "diary"})
      refute has_element?(view, "#arena-send[disabled]")
    end
  end

  describe "arena: columns are exactly the selected models" do
    setup %{project: project, use_case: use_case} do
      echo_requests()
      with_key(project)
      {model_a, model_b} = two_models(project)
      %{use_case: pin(use_case, [model_a, model_b]), model_a: model_a, model_b: model_b}
    end

    test "unpicking drops the column despite history; re-picking restores the conversation", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a,
      model_b: model_b
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})
      send_message(view, "must remain")

      assert has_element?(view, "#arena-column-#{model_b.id}")

      view |> element("#remove-arena-model-#{model_b.id}") |> render_click()

      # Columns are only the selected models: even with history, it does not stand.
      refute has_element?(view, "#arena-column-#{model_b.id}")
      assert has_element?(view, "#arena-column-#{model_a.id}")

      # The history stays in the table as is (hidden, not deleted).
      assert Enum.any?(arena_rows(use_case), &(&1.model_id == model_b.id))

      {:ok, reloaded} =
        Prompts.get_use_case_by_key(use_case.key,
          tenant: project.id,
          actor: Fixtures.system_actor()
        )

      assert reloaded.arena_model_ids == [model_a.id]

      # The picker warns ahead that "picking it again brings the conversation back".
      view |> element("#open-model-picker") |> render_click()
      render_async(view)

      assert has_element?(view, "#pick-history-#{model_b.id}")
      refute has_element?(view, "#pick-history-#{model_a.id}")

      view |> element("#pick-#{model_b.id}") |> render_click()
      view |> element("#add-models") |> render_click()

      assert has_element?(view, "#arena-column-#{model_b.id}")
      assert column(view, model_b) =~ "must remain"
      assert column(view, model_b) =~ "m/b|n=3"
    end

    test "a removed model's column does not stand after a remount either", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a,
      model_b: model_b
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})
      send_message(view, "only the history remains")

      view |> element("#remove-arena-model-#{model_b.id}") |> render_click()

      {:ok, again, _html} = live(conn, arena_path(project, use_case))
      render_async(again)

      refute has_element?(again, "#arena-column-#{model_b.id}")
      assert has_element?(again, "#arena-column-#{model_a.id}")
    end

    test "the Deploy modal's arena marker sees the same selection", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a,
      model_b: model_b
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})
      send_message(view, "run both")

      view |> element("#remove-arena-model-#{model_b.id}") |> render_click()
      view |> element("#open-deploy") |> render_click()

      assert has_element?(view, "#deploy-model-arena-#{model_a.id}")
      # A model that is not selected is not "arena", even if its history remains.
      assert has_element?(view, "#deploy-model-#{model_b.id}")
      refute has_element?(view, "#deploy-model-arena-#{model_b.id}")
    end

    test "a model without history does not get has history", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_b: model_b
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, models: 1))
      render_async(view)

      refute has_element?(view, "#pick-history-#{model_b.id}")
    end
  end

  describe "arena: messenger layout" do
    setup %{project: project, use_case: use_case} do
      echo_requests()
      with_key(project)
      {model_a, _model_b} = two_models(project)
      %{use_case: pin(use_case, [model_a]), model_a: model_a}
    end

    test "the columns share one scroll box (viewport height, sticky head, baseline)", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)

      # There is **one** scroll box and **one** autoscroll hook: scrolling each pane separately
      # makes the same turn unreadable side by side.
      assert has_element?(
               view,
               "#arena-scroll[phx-hook='PromptOnWeb.PromptEditorComponents.ArenaAutoscroll']"
             )

      html = render(view)
      assert occurrences(html, ~s(id="arena-scroll")) == 1
      assert occurrences(html, "PromptOnWeb.PromptEditorComponents.ArenaAutoscroll") == 1
      refute has_element?(view, "#arena-scroll-#{model_a.id}")

      strip = view |> element("#arena-scroll") |> render()

      # The height is viewport-based, not a fixed pixel value (a big screen shows more history).
      assert strip =~ "min(64vh"
      assert strip =~ "overflow:auto"
      # The strip must stretch to the box height so short panes stand on the same baseline.
      assert strip =~ "min-height:100%"

      # The column head is sticky and opaque (bubbles must not show through).
      head = view |> element("#arena-column-head-#{model_a.id}") |> render()
      assert head =~ "position:sticky"
      assert head =~ "background:var(--bg-2)"

      fill_vars(view, %{"input" => "diary"})
      send_message(view, "stick to the bottom")

      # When the messages do not fill the height, the spacer pushes the empty space up and hugs
      # the conversation to the bottom.
      assert view |> element("#arena-scroll") |> render() =~ "margin-top:auto"
    end

    test "user turns are right accent bubbles, model turns left card bubbles", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)
      fill_vars(view, %{"input" => "diary"})
      send_message(view, "hello")

      rows = Enum.filter(arena_rows(use_case), &(&1.model_id == model_a.id))
      user = Enum.find(rows, &(&1.role == :user))
      assistant = Enum.find(rows, &(&1.role == :assistant))

      user_html = view |> element("#arena-row-#{model_a.id}-#{user.id}") |> render()
      assert user_html =~ ~s(data-role="user")
      assert user_html =~ "justify-content:flex-end"
      assert user_html =~ "var(--accent-soft)"

      assistant_html = view |> element("#arena-row-#{model_a.id}-#{assistant.id}") |> render()
      assert assistant_html =~ ~s(data-role="assistant")
      assert assistant_html =~ "justify-content:flex-start"
      refute assistant_html =~ "var(--accent-soft)"
      # The per-turn meta stays under the bubble (version, latency, cost, tokens).
      assert assistant_html =~ "v1 · "
      assert assistant_html =~ " tok"
    end
  end

  describe "arena: composer and full screen" do
    setup %{project: project, use_case: use_case} do
      echo_requests()
      with_key(project)
      {model_a, model_b} = two_models(project)
      %{use_case: pin(use_case, [model_a, model_b]), model_a: model_a, model_b: model_b}
    end

    test "the input row is a floating composer card (Send is primary)", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)

      # The card, border and focus ring are carried by one CSS class (:focus-within cannot be an
      # inline style).
      assert has_element?(view, "#arena-send-form.arena-composer")

      input = view |> element("#arena-input") |> render()
      assert input =~ "min-height:44px"
      assert input =~ "font-size:14px"

      # Send is the prominent primary button.
      assert has_element?(view, "#arena-send.dsbtn-primary")
    end

    test "full screen is a ?full=1 overlay (Esc hook, close patch)", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model_a: model_a
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)

      # The normal tab has no overlay.
      refute has_element?(view, "#arena-fullscreen-overlay")

      view |> element("#arena-fullscreen") |> render_click()

      assert has_element?(
               view,
               "#arena-fullscreen-overlay[phx-hook='PromptOnWeb.PromptEditorComponents.ArenaEscape']"
             )

      assert view |> element("#arena-fullscreen-overlay") |> render() =~ "position:fixed"

      # The overlay holds the whole arena: slim header (model chips), the one scroll box, the
      # composer.
      assert has_element?(view, "#arena-full-chip-#{model_a.id}")
      assert has_element?(view, "#arena-fullscreen-overlay #arena-scroll")
      assert has_element?(view, "#arena-fullscreen-overlay #arena-send-form")
      refute has_element?(view, "#arena")
      assert occurrences(render(view), ~s(id="arena-scroll")) == 1

      # Closing is a patch that drops `?full`; the Esc hook clicks this same link.
      exit_link = view |> element("#arena-exit-full") |> render()
      assert exit_link =~ "tab=arena"
      refute exit_link =~ "full=1"

      view |> element("#arena-exit-full") |> render_click()

      refute has_element?(view, "#arena-fullscreen-overlay")
      assert has_element?(view, "#arena")
    end

    test "?full=1 returns to full screen after a remount (and sending works there too)", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case, full: 1))
      render_async(view)

      assert has_element?(view, "#arena-fullscreen-overlay")
      assert has_element?(view, "#arena-scroll")
      assert has_element?(view, "#arena-send-form")
      refute has_element?(view, "#arena")

      fill_vars(view, %{"input" => "diary"})
      send_message(view, "sent from full screen")

      assert view |> element("#arena-scroll") |> render() =~ "sent from full screen"
    end
  end

  describe "arena: kind :text" do
    setup %{project: project} do
      echo_requests()
      with_key(project)

      use_case =
        Fixtures.use_case_fixture(project, %{key: "voice_transcription", kind: :text})

      Fixtures.prompt_version_fixture(use_case, %{text_template: "diary, {{ hint }}"})

      {:ok, use_case} =
        Prompts.set_use_case_input_schema(
          use_case,
          %{input_schema: [%{name: "hint", type: :string, required?: true}]},
          scope(project)
        )

      model = Fixtures.model_fixture(project, %{model_id: "m/t", display_name: "Text model"})

      %{use_case: pin(use_case, [model]), model: model}
    end

    test "Run leaves only an assistant row and the variables go into params", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model: model
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)

      assert has_element?(view, "#arena-send", "Run")
      refute has_element?(view, "#arena-input")

      fill_vars(view, %{"hint" => "today"})
      run_text(view)

      assert column(view, model) =~ "m/t|n=1|last=diary, today"

      rows = arena_rows(use_case)
      assert [%{role: :assistant, status: :ok} = row] = rows
      assert row.params == %{"variables" => %{"hint" => "today"}}
      assert row.prompt_version_number == 1
    end

    test "running again shows only the last output but the history accumulates", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model: model
    } do
      {:ok, view, _html} = live(conn, arena_path(project, use_case))
      render_async(view)

      fill_vars(view, %{"hint" => "one"})
      run_text(view)
      fill_vars(view, %{"hint" => "two"})
      run_text(view)

      assert column(view, model) =~ "last=diary, two"
      refute column(view, model) =~ "last=diary, one"
      assert length(arena_rows(use_case)) == 2
    end
  end

  describe "draft autosave" do
    test "an edit is saved on the spot and a remount revives it as is (no version is added)", %{
      conn: conn,
      project: project,
      use_case: use_case,
      prompt: prompt
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      view
      |> form("#prompt-editor-form",
        editor: %{
          "messages" => %{"0" => %{"role" => "system", "content" => "New system instructions"}}
        }
      )
      |> render_change()

      # The draft landed in the DB with neither a button nor a confirmation dialog.
      assert %{"messages" => [%{"content" => "New system instructions"} | _rest]} =
               reload_draft(prompt)

      {:ok, view, _html} = live(conn, hub_path(project, use_case))
      assert render(view) =~ "New system instructions"
      refute render(view) =~ "You are helpful."

      # Autosave creates no version.
      assert [%{number: 1}] = versions(prompt)
    end

    test "adding and removing messages autosaves too", %{
      conn: conn,
      project: project,
      use_case: use_case,
      prompt: prompt
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      view |> element("#add-message") |> render_click()
      assert %{"messages" => added} = reload_draft(prompt)
      assert length(added) == 3

      view |> element("#message-2-remove") |> render_click()
      assert %{"messages" => removed} = reload_draft(prompt)
      assert length(removed) == 2
    end

    test "the draft is not rewritten when the content is unchanged", %{
      conn: conn,
      project: project,
      use_case: use_case,
      prompt: prompt
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      # A validate that arrives with the stored content as is (form recovery): the draft column
      # stays empty.
      view
      |> form("#prompt-editor-form",
        editor: %{
          "messages" => %{
            "0" => %{"role" => "system", "content" => "You are helpful."},
            "1" => %{"role" => "user", "content" => "{{ input }}"}
          }
        }
      )
      |> render_change()

      assert reload_draft(prompt) == nil
    end

    test "drafts are per prompt: moving around does not mix them", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, ko} = Prompts.open_prompt(%{use_case_id: use_case.id, name: "ko"}, scope(project))

      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      view
      |> form("#prompt-editor-form",
        editor: %{
          "messages" => %{"0" => %{"role" => "system", "content" => "default-draft text"}}
        }
      )
      |> render_change()

      # Moving to ko shows ko's draft (= empty).
      view |> element("#prompt-ko") |> render_click()
      assert_patch(view, hub_path(project, use_case, prompt: "ko"))
      refute render(view) =~ "default-draft text"

      view
      |> form("#prompt-editor-form",
        editor: %{"messages" => %{"0" => %{"role" => "system", "content" => "ko-draft text"}}}
      )
      |> render_change()

      # Coming back, the default draft is as it was.
      view |> element("#prompt-default") |> render_click()
      assert_patch(view, hub_path(project, use_case))
      assert render(view) =~ "default-draft text"
      refute render(view) =~ "ko-draft text"

      assert %{"messages" => [%{"content" => "ko-draft text"} | _rest]} = reload_draft(ko)
    end

    test "there is neither Save nor unsaved anywhere on the screen", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, versions: 1))
      html = render(view)

      refute has_element?(view, "#save-version")
      refute has_element?(view, "#unsaved-badge")
      refute has_element?(view, "#commit-card")
      refute has_element?(view, "#commit-message")
      refute html =~ "data-confirm"
      refute html =~ "Unsaved"
    end
  end

  describe "URL state (?v, ?diff): versions are read-only previews" do
    test "the default is draft editing and ?v shows that version read-only", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      commit_v2(use_case)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, [{:versions, 1}]))
      assert has_element?(view, "#version-row-draft.is-selected")
      assert has_element?(view, "#prompt-editor-form")
      assert has_element?(view, "#draft-badge")

      {:ok, view, _html} = live(conn, hub_path(project, use_case, v: 1, versions: 1))
      assert has_element?(view, "#version-row-1.is-selected")
      assert has_element?(view, "#preview-badge")
      assert has_element?(view, "#version-preview")
      assert render(view) =~ "You are helpful."

      # Read-only: neither the edit form nor the AI draft modal.
      refute has_element?(view, "#prompt-editor-form")
      refute has_element?(view, "#message-0-content")
    end

    test "Restore this version to draft overwrites the draft (no new version)", %{
      conn: conn,
      project: project,
      use_case: use_case,
      prompt: prompt
    } do
      commit_v2(use_case)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, v: 1))
      assert has_element?(view, "#restore-version")

      view |> element("#restore-version") |> render_click()

      assert_patch(view, hub_path(project, use_case))
      assert render(view) =~ "Restored v1 to the draft."
      assert has_element?(view, "#prompt-editor-form")
      assert %{"messages" => [%{"content" => "You are helpful."} | _rest]} = reload_draft(prompt)

      # Restoring creates no version.
      assert [%{number: 1}, %{number: 2}] = versions(prompt)
    end

    test "the Back to draft link drops ?v", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, v: 1))

      view |> element("#back-to-draft") |> render_click()
      assert_patch(view, hub_path(project, use_case))
      assert has_element?(view, "#prompt-editor-form")
    end

    test "?diff shows two versions side by side", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      commit_v2(use_case)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, v: 2, diff: 1))

      assert has_element?(view, "#diff-view")
      refute has_element?(view, "#prompt-editor-form")
    end
  end

  describe "variable declaration" do
    test "one click on a red chip declares it", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      view
      |> form("#prompt-editor-form",
        editor: %{"messages" => %{"1" => %{"role" => "user", "content" => "{{ tone }}"}}}
      )
      |> render_change()

      assert has_element?(view, "#schema-undeclared")
      view |> element("#var-chip-tone") |> render_click()

      assert has_element?(view, "#var-row-tone")
      refute has_element?(view, "#schema-undeclared")
    end
  end

  describe "Deploy modal (?deploy=1)" do
    test "picks environment, version and model and commits **one pin**", %{
      conn: conn,
      project: project,
      use_case: use_case,
      v1: v1
    } do
      {model_a, _b} = two_models(project)
      pin(use_case, [model_a])
      env = Fixtures.environment(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, deploy: 1))

      assert has_element?(view, "#deploy-modal")
      assert has_element?(view, "#deploy-version")
      assert has_element?(view, "#deploy-model-#{model_a.id}")

      view
      |> form("#deploy-form",
        deploy: %{"environment" => env.id, "version" => v1.id, "model" => model_a.id}
      )
      |> render_submit()

      assert render(view) =~ "Deployed revision #1 to production"

      {:ok, deployment} = Deployments.current_deployment(use_case.id, env.id, scope(project))
      assert deployment.revision == 1
      assert deployment.model_id == model_a.id
      assert deployment.prompt_pins == %{"default" => v1.id}
    end

    test "pins **every** prompt of this use case (the modal shows that list as is)", %{
      conn: conn,
      project: project,
      use_case: use_case,
      v1: v1
    } do
      {model_a, _b} = two_models(project)
      env = Fixtures.environment(project)

      {:ok, ko} = Prompts.open_prompt(%{use_case_id: use_case.id, name: "ko"}, scope(project))

      ko_v1 =
        Fixtures.prompt_version_fixture(ko, %{
          messages: [%{role: :system, content: "Answer in Korean."}]
        })

      # A prompt with no version at all is not pinned; the modal says so.
      {:ok, _ja} = Prompts.open_prompt(%{use_case_id: use_case.id, name: "ja"}, scope(project))

      {:ok, view, _html} = live(conn, hub_path(project, use_case, deploy: 1))

      assert has_element?(view, "#deploy-pins")
      assert view |> element("#deploy-pin-default") |> render() =~ "v1"
      assert view |> element("#deploy-pin-default") |> render() =~ "current"
      assert view |> element("#deploy-pin-ko") |> render() =~ "v1"
      assert view |> element("#deploy-pin-ja") |> render() =~ "no version yet"

      view
      |> form("#deploy-form",
        deploy: %{"environment" => env.id, "version" => v1.id, "model" => model_a.id}
      )
      |> render_submit()

      {:ok, deployment} = Deployments.current_deployment(use_case.id, env.id, scope(project))
      assert deployment.prompt_pins == %{"default" => v1.id, "ko" => ko_v1.id}
    end

    test "the list is every active model: arena first, the rest by name, and it deploys as is", %{
      conn: conn,
      project: project,
      use_case: use_case,
      v1: v1
    } do
      {model_a, model_b} = two_models(project)

      zulu = Fixtures.model_fixture(project, %{model_id: "m/z", display_name: "Zulu model"})
      aardvark = Fixtures.model_fixture(project, %{model_id: "m/aa", display_name: "Aardvark"})

      # Only one is put in the arena; the other three have never been tried.
      pin(use_case, [model_b])
      env = Fixtures.environment(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, deploy: 1))

      for model <- [model_a, model_b, zulu, aardvark] do
        assert has_element?(view, "#deploy-model-#{model.id}")
      end

      # Only the model tried in the arena gets the badge.
      assert has_element?(view, "#deploy-model-arena-#{model_b.id}")
      refute has_element?(view, "#deploy-model-arena-#{model_a.id}")

      # Order: arena first, then by display name (Aardvark < Model A < Zulu model).
      assert model_order(view) == [model_b.id, aardvark.id, model_a.id, zulu.id]

      # A model never run in the arena deploys just the same.
      view
      |> form("#deploy-form",
        deploy: %{"environment" => env.id, "version" => v1.id, "model" => aardvark.id}
      )
      |> render_submit()

      assert render(view) =~ "Deployed revision #1 to production"

      {:ok, deployment} = Deployments.current_deployment(use_case.id, env.id, scope(project))
      assert deployment.model_id == aardvark.id
    end

    test "deploying a changed draft births v(N+1) and pins that version", %{
      conn: conn,
      project: project,
      use_case: use_case,
      prompt: prompt
    } do
      {model_a, _b} = two_models(project)
      pin(use_case, [model_a])
      env = Fixtures.environment(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      view
      |> form("#prompt-editor-form",
        editor: %{
          "messages" => %{"0" => %{"role" => "system", "content" => "Instructions to deploy"}}
        }
      )
      |> render_change()

      view |> element("#open-deploy") |> render_click()

      # The default selection is the current draft, and only then does the commit message field
      # appear.
      assert render(view) =~ "Current draft (will become v2)"
      assert has_element?(view, "#deploy-message")
      assert view |> element("#deploy-pin-default") |> render() =~ "v2 (new)"

      view
      |> form("#deploy-form",
        deploy: %{
          "environment" => env.id,
          "version" => "draft",
          "model" => model_a.id,
          "message" => "Tone tweak"
        }
      )
      |> render_submit()

      assert render(view) =~ "v2 created — deployed revision #1 to production"

      assert [_v1, v2] = versions(prompt)
      assert v2.commit_message == "Tone tweak"
      assert hd(v2.messages).content == "Instructions to deploy"

      {:ok, deployment} = Deployments.current_deployment(use_case.id, env.id, scope(project))
      assert deployment.prompt_pins == %{"default" => v2.id}
    end

    test "an empty commit message defaults to the deployment fact", %{
      conn: conn,
      project: project,
      use_case: use_case,
      prompt: prompt
    } do
      {model_a, _b} = two_models(project)
      env = Fixtures.environment(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      view
      |> form("#prompt-editor-form",
        editor: %{"messages" => %{"0" => %{"role" => "system", "content" => "Unnamed edit"}}}
      )
      |> render_change()

      view |> element("#open-deploy") |> render_click()

      view
      |> form("#deploy-form",
        deploy: %{
          "environment" => env.id,
          "version" => "draft",
          "model" => model_a.id,
          "message" => "   "
        }
      )
      |> render_submit()

      assert [_v1, v2] = versions(prompt)
      assert v2.commit_message == "Deployed to production"
    end

    test "a draft equal to the latest commit creates no new version and reuses that version", %{
      conn: conn,
      project: project,
      use_case: use_case,
      prompt: prompt,
      v1: v1
    } do
      {model_a, _b} = two_models(project)
      env = Fixtures.environment(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, deploy: 1))

      # An untouched draft: both the label and the missing commit message field say "no minting".
      assert render(view) =~ "Current draft (same as v1)"
      refute has_element?(view, "#deploy-message")

      view
      |> form("#deploy-form",
        deploy: %{"environment" => env.id, "version" => "draft", "model" => model_a.id}
      )
      |> render_submit()

      assert render(view) =~ "Deployed revision #1 to production"
      refute render(view) =~ "created —"

      assert [%{id: only_id}] = versions(prompt)
      assert only_id == v1.id

      {:ok, deployment} = Deployments.current_deployment(use_case.id, env.id, scope(project))
      assert deployment.prompt_pins == %{"default" => v1.id}
    end

    test "picking a past version has neither a commit message field nor minting", %{
      conn: conn,
      project: project,
      use_case: use_case,
      prompt: prompt,
      v1: v1
    } do
      {model_a, _b} = two_models(project)
      env = Fixtures.environment(project)
      commit_v2(use_case)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, deploy: 1))

      view
      |> form("#deploy-form", deploy: %{"version" => v1.id})
      |> render_change()

      refute has_element?(view, "#deploy-message")

      view
      |> form("#deploy-form",
        deploy: %{"environment" => env.id, "version" => v1.id, "model" => model_a.id}
      )
      |> render_submit()

      assert render(view) =~ "Deployed revision #1 to production"
      assert length(versions(prompt)) == 2

      {:ok, deployment} = Deployments.current_deployment(use_case.id, env.id, scope(project))
      assert deployment.prompt_pins == %{"default" => v1.id}
    end

    test "a draft that fails lint is not deployed and is rejected with a banner", %{
      conn: conn,
      project: project,
      use_case: use_case,
      prompt: prompt
    } do
      {model_a, _b} = two_models(project)
      env = Fixtures.environment(project)

      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      view
      |> form("#prompt-editor-form",
        editor: %{"messages" => %{"0" => %{"role" => "system", "content" => "{% raw %}nope"}}}
      )
      |> render_change()

      view |> element("#open-deploy") |> render_click()

      view
      |> form("#deploy-form",
        deploy: %{"environment" => env.id, "version" => "draft", "model" => model_a.id}
      )
      |> render_submit()

      assert has_element?(view, "#lint-error")
      assert [%{number: 1}] = versions(prompt)
      assert {:ok, nil} = Deployments.current_deployment(use_case.id, env.id, scope(project))
    end

    test "rules, conditions, targets and weights are gone from the screen", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {model_a, _b} = two_models(project)
      pin(use_case, [model_a])

      {:ok, view, _html} = live(conn, hub_path(project, use_case, deploy: 1))

      modal = view |> element("#deploy-modal") |> render()

      refute has_element?(view, "#deploy-other-rules")
      refute modal =~ "catch-all"
      refute modal =~ "rule"
      refute modal =~ "target"
    end

    test "the \"save first\" warning is gone: deploy right away even mid-edit", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {model_a, _b} = two_models(project)
      pin(use_case, [model_a])

      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      view
      |> form("#prompt-editor-form",
        editor: %{"messages" => %{"0" => %{"role" => "system", "content" => "Tweaked"}}}
      )
      |> render_change()

      view |> element("#open-deploy") |> render_click()

      refute has_element?(view, "#deploy-dirty")
      refute render(view) =~ "Save first"
    end
  end

  describe "Deployments tab (?tab=deployments)" do
    setup %{project: project, use_case: use_case, v1: v1} do
      model = Fixtures.model_fixture(project, %{model_id: "m/dep", display_name: "Dep model"})
      other = Fixtures.model_fixture(project, %{model_id: "m/dep2", display_name: "Other model"})
      env = Fixtures.environment(project)

      {:ok, ko} = Prompts.open_prompt(%{use_case_id: use_case.id, name: "ko"}, scope(project))

      ko_v1 =
        Fixtures.prompt_version_fixture(ko, %{
          messages: [%{role: :system, content: "Answer in Korean."}]
        })

      first =
        Fixtures.simple_deployment_fixture(use_case, env, %{prompt_version: v1, model: model})

      second =
        Fixtures.deployment_fixture(use_case, env, %{
          model_id: other.id,
          params: %{"temperature" => 0.3},
          prompt_pins: %{"default" => v1.id, "ko" => ko_v1.id}
        })

      %{model: model, other: other, env: env, first: first, second: second, ko_v1: ko_v1}
    end

    test "renders the pin (model, prompt version, params) and history; no rule editor", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, html} = live(conn, hub_path(project, use_case, tab: "deployments"))

      assert has_element?(view, "#deployments-tab")
      assert has_element?(view, "#pin-card")
      assert has_element?(view, "#pin-live")
      assert view |> element("#pin-model") |> render() =~ "Other model"
      assert view |> element("#pin-default") |> render() =~ "v1"
      assert view |> element("#pin-ko") |> render() =~ "v1"
      assert view |> element("#pin-params") |> render() =~ "temperature=0.3"

      assert has_element?(view, "#history")
      assert has_element?(view, "#revision-1")
      assert has_element?(view, "#revision-2")

      # The rule editor is gone entirely.
      refute has_element?(view, "#rules-view")
      refute has_element?(view, "#rules-editor")
      refute has_element?(view, "#edit-rules")
      refute has_element?(view, "#revision-diff")
      refute html =~ "catch-all"
      refute html =~ "conditions"
    end

    # ADR 0010 §5.4: an evaluated revision carries its average wherever the revision is shown, and a
    # revision nobody evaluated carries nothing — not a dash, not an empty column.
    test "an evaluated revision shows a score badge and an unevaluated one shows none", %{
      conn: conn,
      project: project,
      use_case: use_case,
      first: first
    } do
      evaluate(project, use_case, first)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, tab: "deployments"))

      assert view |> element("#revision-1-score") |> render() =~ "4.2"
      refute has_element?(view, "#revision-2-score")
      # The live pin is revision 2, which nobody has evaluated.
      refute has_element?(view, "#pin-score")

      {:ok, pinned, _html} = live(conn, hub_path(project, use_case, tab: "deployments", rev: 1))
      assert pinned |> element("#pin-score") |> render() =~ "4.2"
    end

    test "picking a past revision shows that revision's pin", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, tab: "deployments", rev: 1))

      assert view |> element("#pin-model") |> render() =~ "Dep model"
      assert has_element?(view, "#pin-default")
      refute has_element?(view, "#pin-ko")
      refute has_element?(view, "#pin-live")
    end

    test "switching the environment shows only that environment's history", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, tab: "deployments"))

      view |> element("#dep-env-seg a", "staging") |> render_click()

      assert_patch(view, hub_path(project, use_case, tab: "deployments", env: "staging"))
      assert has_element?(view, "#no-deployment")
      refute has_element?(view, "#pin-card")
    end

    test "deploying from the tab stays on that tab and environment and shows the new revision", %{
      conn: conn,
      project: project,
      use_case: use_case,
      model: model,
      v1: v1
    } do
      {:ok, view, _html} =
        live(conn, hub_path(project, use_case, tab: "deployments", env: "staging"))

      view |> element("#deploy-from-deployments") |> render_click()

      staging = Fixtures.environment(project, "staging")

      view
      |> form("#deploy-form",
        deploy: %{"environment" => staging.id, "version" => v1.id, "model" => model.id}
      )
      |> render_submit()

      assert_patch(view, hub_path(project, use_case, tab: "deployments", env: "staging"))
      assert has_element?(view, "#deployments-tab")
      assert has_element?(view, "#revision-1")
      assert view |> element("#pin-model") |> render() =~ "Dep model"
    end

    test "rolling back to a past revision commits a new revision", %{
      conn: conn,
      project: project,
      use_case: use_case,
      env: env,
      first: first
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, tab: "deployments"))

      view |> element("#rollback-to-1") |> render_click()
      assert has_element?(view, "#rollback-modal")

      view |> element("#confirm-rollback") |> render_click()

      assert render(view) =~ "Rolled back to #1"

      {:ok, live_deployment} = Deployments.current_deployment(use_case.id, env.id, scope(project))
      assert live_deployment.revision == 3
      assert live_deployment.model_id == first.model_id
      assert live_deployment.prompt_pins == first.prompt_pins
    end
  end

  describe "Integration section (Deployments tab)" do
    setup %{project: project, use_case: use_case, v1: v1} do
      model = Fixtures.model_fixture(project, %{model_id: "m/int", display_name: "Int model"})
      env = Fixtures.environment(project)

      {:ok, ko} = Prompts.open_prompt(%{use_case_id: use_case.id, name: "ko"}, scope(project))

      ko_v1 =
        Fixtures.prompt_version_fixture(ko, %{
          messages: [%{role: :system, content: "Answer in Korean."}]
        })

      deployment =
        Fixtures.deployment_fixture(use_case, env, %{
          model_id: model.id,
          prompt_pins: %{"default" => v1.id, "ko" => ko_v1.id}
        })

      %{env: env, model: model, deployment: deployment}
    end

    test "the curl snippet carries this use case's real values and example variables", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, tab: "deployments"))

      curl = view |> element("#integration-curl") |> render()

      assert curl =~ "curl -sS -X POST"

      # A human's smoke test is `/resolve`; there is no proxy mode (agent-first-spec §2).
      assert curl =~ PromptOnWeb.Endpoint.url() <> "/api/v1/resolve"
      refute curl =~ "/api/v1/generate"
      assert curl =~ "Bearer $PTN_API_KEY"
      assert curl =~ use_case.key
      assert curl =~ "production"

      # The required variable (input) is filled with an example value: paste it as is and it runs.
      assert curl =~ "input"
    end

    test "moving the environment picker moves the snippet's environment too", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, tab: "deployments"))

      view |> element("#dep-env-seg a", "staging") |> render_click()

      assert view |> element("#integration-curl") |> render() =~ "staging"
    end

    test "the AI instructions cover config-fetch, monitoring logs, variable schema, errors", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, tab: "deployments"))

      prompt = view |> element("#integration-prompt") |> render()

      assert prompt =~ "PromptOn"

      # Being outside the request path is the point of the first paragraph; the proxy endpoint is
      # not even mentioned.
      assert prompt =~ "not in your request path"
      refute prompt =~ "/api/v1/generate"

      # (1) the two config-fetch routes: resolve, and snapshot + local cache (recommended)
      assert prompt =~ "/api/v1/resolve"
      assert prompt =~ "/api/v1/snapshot"
      assert prompt =~ "If-None-Match"
      assert prompt =~ "use this in production"

      # (2) the app calls the provider itself with its own key
      assert prompt =~ "Call the provider yourself"

      # (3) the monitoring logs envelope
      assert prompt =~ "/api/v1/generations"
      assert prompt =~ "200 records"
      assert prompt =~ "UUIDv7"
      assert prompt =~ "payload_policy.max_bytes"
      assert prompt =~ "10,000 logs / month"

      assert prompt =~ "PTN_API_KEY"
      assert prompt =~ use_case.key
      # every prompt name pinned by this deployment
      assert prompt =~ "default"
      assert prompt =~ "ko"
      # the variable table (name, type, required)
      assert prompt =~ "input"
      assert prompt =~ "string"
      # the error code table
      assert prompt =~ "invalid_request"
      assert prompt =~ "payload_too_large"
      assert prompt =~ "unavailable"
      # the final instruction
      assert prompt =~ "Find where this codebase calls an LLM"
    end

    test "both cards have a copy button carrying their own body", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case, tab: "deployments"))

      curl_button = view |> element("#copy-integration-curl") |> render()
      assert curl_button =~ "phx-hook"
      assert curl_button =~ "curl -sS -X POST"

      prompt_button = view |> element("#copy-integration-prompt") |> render()
      assert prompt_button =~ "phx-hook"
      assert prompt_button =~ "Integrate this application with PromptOn."
    end
  end

  describe "AI draft modal (?ai)" do
    test "opens the modal, receives a draft and swaps the message", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      PromptOn.LLM.Fake.set_response(%{content: "Instructions written by the AI"})
      on_exit(&PromptOn.LLM.Fake.reset/0)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, ai: 0))
      assert has_element?(view, "#ai-draft-modal")

      view |> element("#ai-generate") |> render_click()
      render_async(view)

      assert has_element?(view, "#ai-result")
      view |> element("#ai-replace") |> render_click()

      assert render(view) =~ "Instructions written by the AI"
    end

    # Without a BYOK key the place to go is the **organization** settings; the project settings
    # have no provider tab.
    test "without a key it gives only a link to the organization settings", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      PromptOn.LLM.Fake.set_response({:error, :no_provider_key})
      on_exit(&PromptOn.LLM.Fake.reset/0)

      {:ok, view, _html} = live(conn, hub_path(project, use_case, ai: 0))

      view |> element("#ai-generate") |> render_click()
      render_async(view)

      assert has_element?(view, "#ai-no-key")

      assert has_element?(
               view,
               "#ai-providers-link[href='/personal/settings?tab=providers']"
             )
    end
  end

  describe "kind :embedding" do
    test "the Editor tab is a one-line note and the Arena tab is only the model row", %{
      conn: conn,
      project: project
    } do
      use_case = Fixtures.use_case_fixture(project, %{key: "diary_embedding", kind: :embedding})

      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      assert has_element?(view, "#embedding-note")
      assert has_element?(view, "#open-deploy")
      refute has_element?(view, "#prompt-editor-form")
      refute has_element?(view, "#save-version")

      # Models stay on the Arena tab because Deploy will pick one; there is just nothing to run.
      view |> element("#tab-arena") |> render_click()

      assert has_element?(view, "#arena-models")
      assert has_element?(view, "#arena-embedding-note")
      refute has_element?(view, "#arena")
      refute has_element?(view, "#arena-send-form")
    end
  end

  # The use case's own settings: name and description (`describe`), default parameters
  # (`set_default_params`), the raw payload policy (`set_payload_policy`), archive (`archive`).
  # All of them are existing domain actions.
  describe "Evals tab (?tab=evals)" do
    test "the tab strip has Evals and the panel is only mounted there", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} = live(conn, hub_path(project, use_case))

      assert has_element?(view, "#tab-evals")
      refute has_element?(view, "#evals-panel")

      view |> element("#tab-evals") |> render_click()

      assert_patch(view, hub_path(project, use_case, tab: "evals"))
      assert has_element?(view, "#evals-panel")
    end

    # ADR 0010 §5.2: the Evals tab reuses the Deployments tab's `?env=`, so moving between them
    # keeps the environment you were looking at.
    test "switching between Deployments and Evals keeps ?env=", %{
      conn: conn,
      project: project,
      use_case: use_case
    } do
      {:ok, view, _html} =
        live(conn, hub_path(project, use_case, tab: "deployments", env: "staging"))

      view |> element("#tab-evals") |> render_click()
      assert_patch(view, hub_path(project, use_case, tab: "evals", env: "staging"))

      view |> element("#tab-deployments") |> render_click()
      assert_patch(view, hub_path(project, use_case, tab: "deployments", env: "staging"))
    end
  end

  describe "access control" do
    test "a user from another organization cannot open it", %{
      project: project,
      use_case: use_case
    } do
      stranger = Fixtures.user_fixture()
      conn = log_in_user(Phoenix.ConnTest.build_conn(), stranger)

      assert {:error, {:redirect, %{to: "/personal"}}} =
               live(conn, hub_path(project, use_case))
    end

    test "a missing use case redirects to the list", %{conn: conn, project: project} do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/personal/#{project.slug}/use-cases/nope/prompt")

      assert to == "/personal/acme/use-cases"
      assert flash["error"] =~ "Use case not found: nope"
    end
  end
end
