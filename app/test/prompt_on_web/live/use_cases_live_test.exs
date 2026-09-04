defmodule PromptOnWeb.UseCasesLiveTest do
  @moduledoc """
  Use case list screen (`/p/:project_slug/use-cases`, mockup `s_usecases.jsx` UseCasesScreen).

  Checks that the filter and the "Define use case" modal travel **only through URL query
  parameters** (the CLAUDE.md zero-downtime deployment discipline), and that row data (prompt
  count, revision + model of the live production deployment) comes from the real domain.
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Fixtures

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", name: "Acme"})
    production = Fixtures.environment(project, "production")

    diary =
      Fixtures.use_case_fixture(project, %{
        key: "diary_generation",
        kind: :chat,
        input_schema: [
          %{name: "tone", type: :string, required?: true},
          %{name: "history", type: :list},
          %{name: "language", type: :string},
          %{name: "extra", type: :string}
        ]
      })

    chat = Fixtures.use_case_fixture(project, %{key: "chat_response", kind: :chat})

    embedding =
      Fixtures.use_case_fixture(project, %{key: "diary_embedding", kind: :embedding})

    version = Fixtures.prompt_version_fixture(diary)
    model = Fixtures.model_fixture(project, %{model_id: "m/a", display_name: "Model A"})

    deployment =
      Fixtures.simple_deployment_fixture(diary, production, %{
        prompt_version: version,
        model: model
      })

    %{
      conn: log_in_user(conn, user),
      user: user,
      project: project,
      production: production,
      diary: diary,
      chat: chat,
      embedding: embedding,
      model: model,
      version: version,
      deployment: deployment
    }
  end

  describe "list" do
    test "shows the use case key, prompt count and the live production deployment", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      assert has_element?(view, "#use-cases-screen")
      assert has_element?(view, "#use-cases-table")
      assert has_element?(view, "#use-case-diary_generation")
      assert has_element?(view, "#use-case-chat_response")
      assert has_element?(view, "#use-case-diary_embedding")

      assert html =~ "diary_generation"
      assert html =~ "live in production"

      # A deployed use case shows the revision number + the representative model; the rest show
      # "not deployed".
      assert view |> element("#use-case-live-diary_generation") |> render() =~ "#1 · Model A"
      assert view |> element("#use-case-live-chat_response") |> render() =~ "not deployed"

      # The word variant is nowhere on the screen.
      refute html =~ "variant"
    end

    test "shows the latest revision once revisions pile up", %{
      conn: conn,
      project: project,
      production: production,
      diary: diary,
      version: version
    } do
      other = Fixtures.model_fixture(project, %{model_id: "m/b", display_name: "Model B"})

      Fixtures.simple_deployment_fixture(diary, production, %{
        prompt_version: version,
        model: other
      })

      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      assert view |> element("#use-case-live-diary_generation") |> render() =~ "#2 · Model B"
    end

    test "a row is a link to the use case hub", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      assert view
             |> element("#use-case-diary_generation")
             |> render() =~ ~p"/personal/#{project.slug}/use-cases/diary_generation/prompt"
    end

    test "an embedding use case gets the LOG ONLY badge", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      assert view |> element("#use-case-diary_embedding") |> render() =~ "LOG ONLY"
      refute view |> element("#use-case-diary_generation") |> render() =~ "LOG ONLY"
    end

    test "shows up to 3 variable chips and folds the rest into +N", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      row = view |> element("#use-case-diary_generation") |> render()

      assert row =~ "tone"
      assert row =~ "+1"
    end
  end

  describe "filter (?q=)" do
    test "typing patches the URL and narrows the list", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      html =
        view
        |> form("#use-case-filter-form", %{"q" => "embedding"})
        |> render_change()

      assert_patch(view, ~p"/personal/#{project.slug}/use-cases?#{[q: "embedding"]}")
      assert html =~ "diary_embedding"
      assert has_element?(view, "#use-case-diary_embedding")
      refute has_element?(view, "#use-case-diary_generation")
    end

    test "the filter is restored from ?q= in the URL alone (remount)", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} =
        live(conn, ~p"/personal/#{project.slug}/use-cases?#{[q: "chat"]}")

      assert has_element?(view, "#use-case-chat_response")
      refute has_element?(view, "#use-case-diary_generation")
    end

    test "a tampered ?q[]= falls back to no filter", %{conn: conn, project: project} do
      # The URL is a shared contract: the screen must render even from a broken link (no 500s).
      {:ok, view, html} = live(conn, ~p"/personal/#{project.slug}/use-cases" <> "?q[]=x")

      assert html =~ "use-cases-screen"
      assert has_element?(view, "#use-case-diary_generation")
      assert has_element?(view, "#use-case-chat_response")
    end

    test "no matching key gives the empty state", %{conn: conn, project: project} do
      {:ok, view, _html} =
        live(conn, ~p"/personal/#{project.slug}/use-cases?#{[q: "nope"]}")

      assert has_element?(view, "#use-cases-empty")
    end
  end

  describe "Define use case modal (?new=1)" do
    test "?new=1 opens the modal", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases?#{[new: 1]}")

      assert has_element?(view, "#define-use-case-modal")
      assert has_element?(view, "#define-use-case-form")
      assert has_element?(view, "#use-case-key")
    end

    test "the button patches to ?new=1", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      refute has_element?(view, "#define-use-case-modal")

      view |> element("#new-use-case") |> render_click()

      assert_patch(view, ~p"/personal/#{project.slug}/use-cases?#{[new: 1]}")
      assert has_element?(view, "#define-use-case-modal")
    end

    test "opened without the modal, the modal is closed", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases")

      refute has_element?(view, "#define-use-case-modal")
    end

    # The first-run flow is use case → model → prompt → arena → deploy: once the definition is
    # done, send straight to the use case hub, which has all of that.
    test "defining a text use case navigates to the use case hub", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases?#{[new: 1]}")

      result =
        view
        |> form("#define-use-case-form", %{
          "use_case" => %{
            "key" => "diary_summary",
            "kind" => "text"
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == ~p"/personal/#{project.slug}/use-cases/diary_summary/prompt"

      assert {^to, flash} = assert_redirect(view)
      assert flash["info"] == "Use case created — add models, write the prompt, then deploy."

      assert {:ok, use_case} =
               PromptOn.Prompts.get_use_case_by_key("diary_summary",
                 tenant: project.id,
                 actor: PromptOn.Fixtures.system_actor()
               )

      assert use_case.kind == :text
      assert use_case.name == "Diary summary"
    end

    test "a chat use case navigates to the use case hub too", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases?#{[new: 1]}")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#define-use-case-form", %{
                 "use_case" => %{
                   "key" => "support_reply",
                   "kind" => "chat"
                 }
               })
               |> render_submit()

      assert to == ~p"/personal/#{project.slug}/use-cases/support_reply/prompt"
    end

    # An embedding use case has no prompt to write: the hub shows only models and Deploy (the
    # destination is the same).
    test "an embedding use case navigates to the use case hub too", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases?#{[new: 1]}")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#define-use-case-form", %{
                 "use_case" => %{
                   "key" => "note_embedding",
                   "kind" => "embedding"
                 }
               })
               |> render_submit()

      assert to == ~p"/personal/#{project.slug}/use-cases/note_embedding/prompt"

      assert {^to, flash} = assert_redirect(view)
      assert flash["info"] == "Use case note_embedding defined — add models, then deploy."
    end

    test "an invalid key stays as a form error", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases?#{[new: 1]}")

      html =
        view
        |> form("#define-use-case-form", %{
          "use_case" => %{"key" => "Bad Key", "kind" => "chat"}
        })
        |> render_submit()

      assert has_element?(view, "#define-use-case-modal")
      assert html =~ "match"
    end

    test "an existing key is rejected", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases?#{[new: 1]}")

      view
      |> form("#define-use-case-form", %{
        "use_case" => %{"key" => "chat_response", "kind" => "chat"}
      })
      |> render_submit()

      assert has_element?(view, "#define-use-case-modal")
    end

    # The plan entitlement error is an `InvalidAttribute` on `:plan`, and `:plan` is not an input on
    # this form — without the flash it renders nowhere at all and the button looks broken.
    test "at the plan limit the plan sentence reaches the flash", %{
      conn: conn,
      project: project,
      user: user
    } do
      # three use cases already exist in the fixture; take the project to the Free limit
      for n <- 4..PromptOn.Entitlements.limit(:free, :use_cases_per_project) do
        Fixtures.use_case_fixture(project, %{key: "filler_#{n}", kind: :chat})
      end

      {:ok, view, _html} = live(conn, ~p"/personal/#{project.slug}/use-cases?#{[new: 1]}")

      html =
        view
        |> form("#define-use-case-form", %{
          "use_case" => %{"key" => "one_too_many", "kind" => "chat"}
        })
        |> render_submit()

      assert has_element?(view, "#define-use-case-modal")

      assert html =~
               "plan: the Free plan allows 10 use cases per project. " <>
                 "Archive a use case, or upgrade the organization to Team."

      assert {:error, _error} =
               PromptOn.Prompts.define_use_case(%{key: "one_too_many", kind: :chat},
                 tenant: project.id,
                 actor: user
               )
    end
  end

  describe "permissions" do
    test "a non-member is sent back to /personal", %{conn: conn} do
      stranger = Fixtures.user_fixture()
      other = Fixtures.project_fixture(%{user: stranger, slug: "stranger-co"})

      assert {:error, {:redirect, %{to: "/personal"}}} =
               live(conn, ~p"/personal/#{other.slug}/use-cases")
    end

    test "redirects to /sign-in when signed out", %{project: project} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(build_conn(), ~p"/personal/#{project.slug}/use-cases")
    end
  end
end
