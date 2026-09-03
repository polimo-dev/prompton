defmodule PromptOn.Accounts.ReservedSlugsTest do
  use ExUnit.Case, async: true

  alias PromptOn.Accounts.ReservedSlugs

  test "reserved? is case-insensitive and only matches strings" do
    assert ReservedSlugs.reserved?("personal")
    assert ReservedSlugs.reserved?("Personal")
    refute ReservedSlugs.reserved?("personally")
    refute ReservedSlugs.reserved?(nil)
    refute ReservedSlugs.reserved?(:personal)
  end

  test "`personal` is reserved — it is the path segment for the current user's personal org" do
    assert "personal" in ReservedSlugs.all()
  end

  # This test is the enforcer of the "keep in sync with the router" rule. Adding a static top-level
  # route to the router breaks it here, and it passes only once that name is added to
  # `PromptOn.Accounts.ReservedSlugs`.
  test "every static top-level router segment is reserved" do
    router_segments =
      PromptOnWeb.Router.__routes__()
      |> Enum.map(fn route ->
        route.path |> String.split("/", trim: true) |> List.first()
      end)
      |> Enum.reject(
        &(is_nil(&1) or String.starts_with?(&1, ":") or String.starts_with?(&1, "*"))
      )
      |> Enum.uniq()

    missing = Enum.reject(router_segments, &ReservedSlugs.reserved?/1)

    assert missing == [],
           "router serves #{inspect(missing)} at the top level but they are not reserved " <>
             "organization slugs — add them to PromptOn.Accounts.ReservedSlugs"
  end

  test "project_reserved? is case-insensitive and only matches strings" do
    assert ReservedSlugs.project_reserved?("settings")
    assert ReservedSlugs.project_reserved?("Members")
    assert ReservedSlugs.project_reserved?("usage")
    refute ReservedSlugs.project_reserved?("settings-app")
    refute ReservedSlugs.project_reserved?(nil)
    refute ReservedSlugs.project_reserved?(:settings)
  end

  test "`account` is reserved — the account pages live at the top level" do
    assert ReservedSlugs.reserved?("account")
  end

  # The static second segment under the organization scope (`/:org_slug/...`) shares a namespace
  # with project slugs. When the web agent opens a route like `/{org}/members`, it breaks here, and
  # it passes only once that name is added to the project list in
  # `PromptOn.Accounts.ReservedSlugs`.
  test "every static second segment under /:org_slug is a reserved project slug" do
    org_scoped_segments =
      PromptOnWeb.Router.__routes__()
      |> Enum.map(&(&1.path |> String.split("/", trim: true)))
      |> Enum.filter(&match?([":org_slug", _ | _], &1))
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.reject(&(String.starts_with?(&1, ":") or String.starts_with?(&1, "*")))
      |> Enum.uniq()

    missing = Enum.reject(org_scoped_segments, &ReservedSlugs.project_reserved?/1)

    assert missing == [],
           "router serves #{inspect(missing)} under /:org_slug but they are not reserved " <>
             "project slugs — add them to PromptOn.Accounts.ReservedSlugs"
  end

  test "every static asset path is reserved" do
    missing =
      PromptOnWeb.static_paths()
      |> Enum.reject(&ReservedSlugs.reserved?/1)

    assert missing == []
  end
end
