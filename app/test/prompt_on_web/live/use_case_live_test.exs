defmodule PromptOnWeb.UseCaseLiveTest do
  @moduledoc """
  Use case detail path (`/p/:slug/use-cases/:key`): only the redirect to the hub remains.

  Everything about a use case now lives in the hub (`/p/:slug/use-cases/:key/prompt`). This path
  stays alive for old links and bookmarks, and carries `?tab`/`?prompt` over.
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Fixtures

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    project = Fixtures.project_fixture(%{user: user, slug: "acme", name: "Acme"})
    use_case = Fixtures.use_case_fixture(project, %{key: "diary_generation"})

    %{conn: log_in_user(conn, user), user: user, project: project, use_case: use_case}
  end

  test "sends to the hub", %{conn: conn, project: project, use_case: use_case} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/personal/#{project.slug}/use-cases/#{use_case.key}")

    assert to == "/personal/acme/use-cases/diary_generation/prompt"
  end

  test "carries the tab and the prompt over", %{conn: conn, project: project, use_case: use_case} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(
               conn,
               ~p"/personal/#{project.slug}/use-cases/#{use_case.key}?#{[tab: "deployments", prompt: "ko"]}"
             )

    assert to =~ "/prompt?"
    assert to =~ "tab=deployments"
    assert to =~ "prompt=ko"
  end

  test "the old prompts tab is the hub's default tab, so it is dropped", %{
    conn: conn,
    project: project,
    use_case: use_case
  } do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(
               conn,
               ~p"/personal/#{project.slug}/use-cases/#{use_case.key}?#{[tab: "prompts"]}"
             )

    assert to == "/personal/acme/use-cases/diary_generation/prompt"
  end

  test "an unknown use case is sent to the list with a flash", %{conn: conn, project: project} do
    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn, ~p"/personal/#{project.slug}/use-cases/nope")

    assert to == "/personal/acme/use-cases"
    assert flash["error"] =~ "Use case not found: nope"
  end

  test "a user from another organization cannot open the project", %{
    project: project,
    use_case: use_case
  } do
    stranger = Fixtures.user_fixture()
    conn = log_in_user(Phoenix.ConnTest.build_conn(), stranger)

    assert {:error, {:redirect, %{to: "/personal", flash: flash}}} =
             live(conn, ~p"/personal/#{project.slug}/use-cases/#{use_case.key}")

    assert flash["error"] =~ "Project not found"
  end
end
