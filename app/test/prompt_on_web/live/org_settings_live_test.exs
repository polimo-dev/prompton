defmodule PromptOnWeb.OrgSettingsLiveTest do
  @moduledoc """
  Organization settings (`/:org_slug/settings`) tests.

  Checks: General saves name and slug through the real domain actions, the personal
  organization's "Convert to team organization" is `:claim_slug` itself, and **provider keys live
  here and nowhere else** (register, rotate, remove; organization-owned; raw secret never shown).
  BYOK is **OpenRouter only** (2026-09-01), so there is neither a provider row nor a provider
  picker. Tab and modal targets must stay in the URL (zero-downtime deployment discipline).
  """
  use PromptOnWeb.ConnCase, async: true

  alias PromptOn.Accounts
  alias PromptOn.Fixtures

  doctest PromptOnWeb.OrgComponents, import: true

  setup %{conn: conn} do
    user = Fixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "tabs" do
    test "tabs are patch links and stay in the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/settings")

      assert has_element?(view, "#org-settings-general")

      view |> element("#tab-providers") |> render_click()

      assert_patched(view, ~p"/personal/settings?tab=providers")
      assert has_element?(view, "#org-settings-providers")
    end

    test "opens a tab directly from the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/personal/settings?tab=providers")

      assert has_element?(view, "#tab-providers.is-active")
      assert has_element?(view, "#org-settings-providers")
    end
  end

  describe "General: personal organization" do
    test "says it is a personal organization and saves the name", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/personal/settings")

      assert html =~ "Personal organization"
      assert html =~ "Convert to team organization"

      view |> form("#org-name-form", organization: %{"name" => "My Space"}) |> render_submit()

      assert render(view) =~ "Organization saved"
      assert {:ok, org} = Accounts.personal_organization_for(user.id, actor: user)
      assert org.name == "My Space"
      assert org.personal?
    end

    test "claiming a slug makes it a team organization and goes to the new address", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/settings")

      view
      |> form("#org-slug-form", claim: %{"slug" => "promoted-co", "name" => "Promoted Co"})
      |> render_submit()

      assert_redirect(view, ~p"/promoted-co/settings?tab=general")

      assert {:ok, %{personal?: false, name: "Promoted Co"}} =
               Accounts.get_organization_by_slug("promoted-co", actor: user)
    end

    test "a reserved word or duplicate slug is rejected and the screen stays alive", %{
      conn: conn,
      user: user
    } do
      _taken = Fixtures.team_org_fixture(%{user: user, slug: "taken-slug"})

      for bad <- ["settings", "taken-slug", "x"] do
        {:ok, view, _html} = live(conn, ~p"/personal/settings")

        html =
          view
          |> form("#org-slug-form", claim: %{"slug" => bad, "name" => "X"})
          |> render_submit()

        assert html =~ "flash-error", "expected #{bad} to be rejected"
        assert has_element?(view, "#org-slug-form")
      end

      assert {:ok, %{personal?: true}} =
               Accounts.personal_organization_for(user.id, actor: user)
    end
  end

  describe "General: team organization" do
    setup %{user: user} do
      %{organization: Fixtures.team_org_fixture(%{user: user, slug: "acme-inc", name: "Acme"})}
    end

    test "says it is a team organization and changes the slug", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/acme-inc/settings")

      assert html =~ "Team organization"
      refute html =~ "Convert to team organization"

      view |> form("#org-slug-form", claim: %{"slug" => "acme-2"}) |> render_submit()

      assert_redirect(view, ~p"/acme-2/settings?tab=general")
      assert {:ok, %{slug: "acme-2"}} = Accounts.get_organization_by_slug("acme-2", actor: user)
    end
  end

  describe "Provider Keys" do
    test "there is a single OpenRouter card, and with no key it is none", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/personal/settings?tab=providers")

      row = view |> element("#provider-row-openrouter") |> render()
      assert row =~ "— no key —"
      assert row =~ "none"
      assert has_element?(view, "#add-provider-openrouter")
      assert has_element?(view, "#provider-keys-note")
      assert html =~ "More providers later"

      # No other provider rows, and nothing to pick from.
      for provider <- [:openai, :anthropic, :groq, :google] do
        refute has_element?(view, "#provider-row-#{provider}")
        refute has_element?(view, "#add-provider-#{provider}")
      end
    end

    test "the add modal has no provider picker", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/personal/settings?tab=providers&add-provider=openrouter")

      assert has_element?(view, "#add-provider-modal")
      assert has_element?(view, "#add-provider-form")

      for provider <- [:openrouter, :openai, :anthropic, :groq, :google] do
        refute has_element?(view, "#pick-provider-#{provider}")
      end
    end

    test "adding a key shows the masked value and connected (the raw secret is not on screen)", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/personal/settings?tab=providers")

      view |> element("#add-provider-openrouter") |> render_click()
      assert_patched(view, ~p"/personal/settings?tab=providers&add-provider=openrouter")

      html =
        view
        |> form("#add-provider-form",
          provider_key: %{"secret" => "sk-or-v1-0123456789abcdef4Xa2", "label" => "default"}
        )
        |> render_submit()

      assert_patched(view, ~p"/personal/settings?tab=providers")
      assert html =~ "Provider key stored (encrypted)"

      row = view |> element("#provider-row-openrouter") |> render()
      assert row =~ "sk-or-v1-••••4Xa2"
      assert row =~ "connected"
      refute render(view) =~ "0123456789abcdef"
      # Once connected, the add button goes away and only rotate and remove remain.
      refute has_element?(view, "#add-provider-openrouter")
      assert has_element?(view, "#rotate-provider-openrouter")
      assert has_element?(view, "#remove-provider-openrouter")

      # The key is owned by the **organization**: it is found by organization id, not project.
      org = Fixtures.organization_for(user)

      assert {:ok, [%{organization_id: org_id}]} =
               Accounts.list_provider_keys(org.id, actor: user)

      assert org_id == org.id
    end

    test "rotating the key changes the hint", %{conn: conn, user: user} do
      org = Fixtures.organization_for(user)
      key = Fixtures.provider_key_fixture(org, secret: "sk-or-v1-oldoldoldold1111")

      {:ok, view, _html} = live(conn, ~p"/personal/settings?tab=providers")

      view |> element("#rotate-provider-openrouter") |> render_click()
      assert_patched(view, ~p"/personal/settings?tab=providers&rotate-provider=#{key.id}")

      view
      |> form("#rotate-provider-form", provider_key: %{"secret" => "sk-or-v1-newnewnewnew2222"})
      |> render_submit()

      assert_patched(view, ~p"/personal/settings?tab=providers")

      row = view |> element("#provider-row-openrouter") |> render()
      assert row =~ "2222"
      refute row =~ "1111"
      refute render(view) =~ "newnewnewnew"
    end

    test "removing the key goes back to none", %{conn: conn, user: user} do
      org = Fixtures.organization_for(user)
      key = Fixtures.provider_key_fixture(org)

      {:ok, view, _html} = live(conn, ~p"/personal/settings?tab=providers")

      assert has_element?(view, "#remove-provider-openrouter[phx-value-id='#{key.id}']")

      view |> element("#remove-provider-openrouter") |> render_click()

      assert view |> element("#provider-row-openrouter") |> render() =~ "— no key —"
      assert has_element?(view, "#add-provider-openrouter")
    end

    test "an empty key is rejected", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, ~p"/personal/settings?tab=providers&add-provider=openrouter")

      html =
        view |> form("#add-provider-form", provider_key: %{"secret" => "  "}) |> render_submit()

      assert html =~ "flash-error"
      assert view |> element("#provider-row-openrouter") |> render() =~ "— no key —"
    end
  end

  describe "there are no management keys (2026-09-02)" do
    test "neither the tab nor the copy remains: the CLI gets a person's token via `prompton login`",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/personal/settings")

      refute has_element?(view, "#tab-keys")
      refute html =~ "Management key"

      # Pointing at a missing tab falls back to the first tab (General).
      {:ok, _view, html} = live(conn, ~p"/personal/settings?tab=keys")
      assert html =~ "org-settings-general"
    end
  end

  describe "zero-downtime deployment: URL state and form recovery" do
    test "every form carries phx-change (recovery target)", %{conn: conn} do
      forms = [
        {~p"/personal/settings?tab=general", "#org-name-form"},
        {~p"/personal/settings?tab=general", "#org-slug-form"},
        {~p"/personal/settings?tab=providers&add-provider=openrouter", "#add-provider-form"}
      ]

      for {path, selector} <- forms do
        {:ok, view, _html} = live(conn, path)
        assert view |> element(selector) |> render() =~ "phx-change=", "#{selector} (#{path})"
      end
    end

    test "a tampered ?rotate-provider=nope only closes the modal", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/personal/settings?tab=providers&rotate-provider=nope")

      assert html =~ "org-settings-providers"
      refute has_element?(view, "#rotate-provider-modal")
    end
  end

  describe "access control" do
    test "a non-member cannot open another organization's settings", %{conn: conn} do
      stranger = Fixtures.user_fixture()
      _closed = Fixtures.team_org_fixture(%{user: stranger, slug: "closed-doors"})

      assert {:error, {:redirect, %{to: "/personal"}}} = live(conn, ~p"/closed-doors/settings")
    end
  end
end
