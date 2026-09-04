defmodule PromptOnWeb.EvalsComponentsTest do
  @moduledoc """
  The presentational half of the Evals tab (ADR 0010 §5.1) checked without a screen.

  Two things are worth pinning down here rather than through a LiveView: the score badge's
  **nothing** case (a revision nobody evaluated must render no badge at all — `CLAUDE.md` forbids
  always-empty columns) and its tone thresholds, and the distribution bar's zero case, which is the
  one place this module could divide by zero.
  """
  use PromptOnWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PromptOnWeb.EvalsComponents

  doctest PromptOnWeb.EvalsComponents

  defp run(attrs \\ %{}) do
    Map.merge(
      %{
        id: "01a0-run",
        average_score: Decimal.new("4.20"),
        scored_count: 812,
        rubric_number: 3,
        judge_model: "openai/gpt-4o-mini",
        finished_at: DateTime.utc_now()
      },
      attrs
    )
  end

  describe "score_badge/1" do
    test "renders nothing for a revision that was never evaluated" do
      assert render_component(&EvalsComponents.score_badge/1, run: nil) |> String.trim() == ""
    end

    test "shows the average, the sample count and the rubric version" do
      html = render_component(&EvalsComponents.score_badge/1, run: run(), id: "pin-score")

      assert html =~ "4.2"
      assert html =~ "n=812"
      assert html =~ "v3"
      assert html =~ ~s|id="pin-score"|
      assert html =~ "rubric v3 · openai/gpt-4o-mini"
    end

    test "the tone flips at 4.0 and at 3.0" do
      assert EvalsComponents.score_tone(Decimal.new("4.00")) == :ok
      assert EvalsComponents.score_tone(Decimal.new("3.99")) == :neutral
      assert EvalsComponents.score_tone(Decimal.new("3.00")) == :neutral
      assert EvalsComponents.score_tone(Decimal.new("2.99")) == :err

      good = render_component(&EvalsComponents.score_badge/1, run: run())

      bad =
        render_component(&EvalsComponents.score_badge/1,
          run: run(%{average_score: Decimal.new("2.10")})
        )

      assert good =~ "var(--ok)"
      assert bad =~ "var(--err)"
    end
  end

  describe "distribution_bar/1" do
    test "an all-zero distribution renders the empty track without dividing by zero" do
      html = render_component(&EvalsComponents.distribution_bar/1, distribution: %{}, id: "d")

      assert html =~ ~s|id="d"|
      refute html =~ "id=\"d-level-"
    end

    test "a nil distribution is the same as an empty one" do
      html = render_component(&EvalsComponents.distribution_bar/1, distribution: nil, id: "d")

      assert html =~ ~s|id="d"|
      refute html =~ "id=\"d-level-"
    end

    test "each present level gets its share of the width" do
      html =
        render_component(&EvalsComponents.distribution_bar/1,
          distribution: %{"4" => 3, "5" => 1},
          id: "d",
          legend: true
        )

      assert html =~ ~s|id="d-level-4"|
      assert html =~ "width:75.0%"
      assert html =~ "width:25.0%"
      refute html =~ ~s|id="d-level-1"|
      assert html =~ "★ 3"
    end
  end

  describe "continuous_eval_card/1" do
    test "is a disabled checkbox on every plan, and never a button" do
      for plan <- [:free, :team, :pro] do
        html =
          render_component(&EvalsComponents.continuous_eval_card/1,
            plan: plan,
            settings_path: "/personal/settings?tab=general"
          )

        assert html =~ ~s|type="checkbox"|
        assert html =~ "disabled"
        refute html =~ "<button"
      end
    end

    # The copy is derived from `PromptOn.Entitlements`, never written out: only `:pro` includes
    # `:automatic_evaluation`, so a Team organization must not be told the feature is on its plan.
    test "the badge names the plans that really have the feature, and Coming soon on pro" do
      free =
        render_component(&EvalsComponents.continuous_eval_card/1,
          plan: :free,
          settings_path: "/personal/settings"
        )

      team =
        render_component(&EvalsComponents.continuous_eval_card/1,
          plan: :team,
          settings_path: "/personal/settings"
        )

      pro =
        render_component(&EvalsComponents.continuous_eval_card/1,
          plan: :pro,
          settings_path: "/personal/settings"
        )

      assert free =~ "Available on Pro."
      refute free =~ "Team/Pro"
      assert team =~ "Available on Pro."
      refute PromptOn.Entitlements.allows?(:team, :automatic_evaluation)
      assert pro =~ "Coming soon"
      assert pro =~ "Not built yet"
    end
  end

  describe "labels" do
    test "cost never shows a rounded-down zero for a real amount" do
      assert EvalsComponents.cost_label(Decimal.new("0")) == "$0.00"
      assert EvalsComponents.cost_label(Decimal.new("0.004")) == "< $0.01"
      assert EvalsComponents.cost_label(Decimal.new("1.239")) == "$1.24"
    end

    test "an excerpt is the first line only, cut to length" do
      assert EvalsComponents.excerpt("first\nsecond", 40) == "first"

      assert EvalsComponents.excerpt(String.duplicate("a", 50), 10) ==
               String.duplicate("a", 10) <> "…"

      assert EvalsComponents.excerpt("   \n x", 10) == "—"
    end

    test "progress says done, not scored, and names the failures" do
      assert EvalsComponents.progress_label(%{
               scored_count: 3,
               unparsable_count: 1,
               failed_count: 2,
               item_count: 10
             }) == "6 / 10 done · 3 scored · 1 unparsable · 2 failed"

      # A run in which nothing was scored must never read "5 / 5 scored".
      assert EvalsComponents.progress_label(%{
               scored_count: 0,
               unparsable_count: 0,
               failed_count: 5,
               item_count: 5
             }) == "5 / 5 done · 0 scored · 5 failed"

      assert EvalsComponents.progress_label(%{
               scored_count: 10,
               unparsable_count: 0,
               failed_count: 0,
               item_count: 10
             }) == "10 / 10 done"
    end

    test "a log reference discriminates between logs of one batch" do
      first = "01a06a65-9c2f-7b1e-8000-0123456789ab"
      second = "01a06a65-9c2f-7b1e-8000-0123456789cd"

      refute EvalsComponents.log_ref(first) == EvalsComponents.log_ref(second)
      assert EvalsComponents.log_ref(nil) == "—"
    end
  end
end
