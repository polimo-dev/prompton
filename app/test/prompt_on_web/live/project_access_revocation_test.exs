defmodule PromptOnWeb.ProjectAccessRevocationTest do
  use PromptOnWeb.ConnCase, async: false

  import PromptOn.EvalsFixtures
  import PromptOn.Fixtures

  alias PromptOn.Accounts
  alias PromptOn.Evals
  alias PromptOn.Evals.Calibration
  alias PromptOn.Projects
  alias PromptOn.Prompts

  setup %{conn: conn} do
    owner = user_fixture()

    organization =
      team_org_fixture(%{user: owner})
      |> Accounts.set_organization_draft_model!(%{draft_model: "openai/gpt-4.1-mini"},
        actor: system_actor()
      )
      |> Accounts.set_organization_judge_model!(%{judge_model: "openai/gpt-4o-mini"},
        actor: system_actor()
      )

    set_plan(organization, :pro)
    admin = user_fixture()

    {:ok, membership} =
      Accounts.add_member(
        %{organization_id: organization.id, user_id: admin.id, role: :admin},
        actor: system_actor()
      )

    project = project_fixture(%{user: owner, organization: organization})
    use_case = use_case_fixture(project)

    on_exit(&PromptOn.LLM.Fake.reset/0)

    %{
      conn: log_in_user(conn, admin),
      admin: admin,
      organization: organization,
      membership: membership,
      project: project,
      use_case: use_case
    }
  end

  test "usage refreshes its allowed projects before aggregating after a demotion", context do
    %{conn: conn, organization: organization, project: project, use_case: use_case} = context
    assert %{accepted: 1} = ingest_fixture(project, [generation_payload_fixture(use_case)])
    {:ok, view, _html} = live(conn, ~p"/#{organization.slug}/usage")
    assert has_element?(view, "#usage-row-#{project.slug}")

    demote(context)
    view |> element("#usage-period a", "7d") |> render_click()

    assert has_element?(view, "#usage-empty")
    refute has_element?(view, "#usage-row-#{project.slug}")
    refute has_element?(view, "#usage-breakdown-#{project.slug}")
  end

  test "the overview rejects a period change after project access is lost", context do
    %{conn: conn, organization: organization, project: project} = context
    {:ok, view, _html} = live(conn, ~p"/#{organization.slug}/#{project.slug}")
    assert has_element?(view, "#overview-totals")

    demote(context)
    view |> element("#overview-period a", "7d") |> render_click()

    assert_redirect(view, ~p"/#{organization.slug}")
  end

  test "an open AI draft cannot spend a provider key after project access is lost", context do
    prepare_editor(context)
    %{conn: conn, organization: organization, project: project, use_case: use_case} = context

    {:ok, view, _html} =
      live(conn, ~p"/#{organization.slug}/#{project.slug}/use-cases/#{use_case.key}/prompt?ai=0")

    assert has_element?(view, "#ai-generate")
    demote(context)
    watch_llm()

    view |> element("#ai-generate") |> render_click()
    render_async(view)

    refute has_element?(view, "#ai-result")
    refute_received :llm_called
  end

  test "an open arena cannot call the provider or record a run after access is lost", context do
    prepare_editor(context)
    %{conn: conn, organization: organization, project: project, use_case: use_case} = context

    {:ok, view, _html} =
      live(
        conn,
        ~p"/#{organization.slug}/#{project.slug}/use-cases/#{use_case.key}/prompt?tab=arena"
      )

    assert has_element?(view, "#arena-send-form")
    refute has_element?(view, "#arena-send[disabled]")
    demote(context)
    watch_llm()

    view |> form("#arena-send-form", send: %{"input" => "Still connected"}) |> render_submit()
    render_async(view)

    refute_received :llm_called
    assert {:ok, []} = Prompts.arena_messages_for_use_case(use_case.id, scope(project))
    assert Ash.count!(PromptOn.Observability.Generation, scope(project)) == 0
  end

  test "calibration rechecks the caller before all three AI operations", context do
    %{project: project, use_case: use_case, admin: admin} = context
    provider_key_fixture(project)
    {set, _samples} = scored_calibration_set_fixture(project, use_case, [5, 4, 3, 2, 1])
    rubric = rubric_fixture(use_case, %{calibration_set_id: set.id})
    opts = scope(project, admin)

    plant_score_answer(4)
    assert {:ok, %{scored: 5}} = Calibration.score_set(rubric, opts)
    demote(context)
    watch_llm()

    assert {:error, :forbidden} = Calibration.draft(set, opts)
    assert {:error, :forbidden} = Calibration.revise(rubric, opts)
    assert {:error, :forbidden} = Calibration.score_set(rubric, opts)
    refute_received :llm_called

    assert {:ok, scores} = Evals.list_calibration_scores(rubric.id, scope(project))
    assert Enum.all?(scores, &(&1.score == 4))
    assert Ash.count!(PromptOn.Evals.Rubric, scope(project)) == 1
  end

  test "calibration rejects mismatched tenants and runtime API keys before calling AI", context do
    %{project: project, use_case: use_case, admin: admin, organization: organization} = context
    {set, _samples} = scored_calibration_set_fixture(project, use_case, [5, 4, 3, 2, 1])
    rubric = rubric_fixture(use_case, %{calibration_set_id: set.id})
    {api_key, _raw} = api_key_fixture(project)
    other_project = project_fixture(%{user: admin, organization: organization})
    watch_llm()

    for opts <- [scope(other_project, admin), scope(project, api_key)] do
      assert {:error, :forbidden} = Calibration.draft(set, opts)
      assert {:error, :forbidden} = Calibration.revise(rubric, opts)
      assert {:error, :forbidden} = Calibration.score_set(rubric, opts)
    end

    refute_received :llm_called
    assert {:ok, []} = Evals.list_calibration_scores(rubric.id, scope(project))
  end

  defp prepare_editor(%{project: project, use_case: use_case}) do
    provider_key_fixture(project)
    model = model_fixture(project)

    prompt_version_fixture(use_case, %{
      messages: [%{role: :system, content: "Answer the user's request."}]
    })

    {:ok, _use_case} =
      Prompts.set_use_case_arena_models(use_case, %{arena_model_ids: [model.id]}, scope(project))
  end

  defp demote(%{membership: membership, project: project, admin: admin}) do
    # Simulate a concurrent permission change without relying on the initiating session's UI.
    PromptOn.Repo.query!(
      "UPDATE memberships SET role = 'member' WHERE id = $1",
      [Ecto.UUID.dump!(membership.id)]
    )

    assert {:ok, nil} = Projects.get_project(project.id, actor: admin)
  end

  defp watch_llm do
    test_pid = self()

    PromptOn.LLM.Fake.set_response(fn request ->
      send(test_pid, :llm_called)
      {:ok, PromptOn.LLM.Fake.default_outcome(request)}
    end)
  end
end
