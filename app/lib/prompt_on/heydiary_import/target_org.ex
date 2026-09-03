defmodule PromptOn.HeyDiaryImport.TargetOrg do
  @moduledoc """
  How the import/export mix tasks pick the target organization.

  With URLs now shaped `/{org_slug}/{project_slug}/...`, **personal organizations have no slug** —
  so a single slug cannot address every target. There are two paths:

  - `--org SLUG` — a team organization (globally unique slug)
  - `--user EMAIL` — that user's personal organization (the dev default path: the account created
    by `mix prompton.seed_admin`)

  Exactly one of the two is required.
  """

  alias PromptOn.Accounts

  @doc "Finds the organization from the options. `Mix.raise/1` when it cannot be found."
  @spec resolve!(keyword()) :: Ash.Resource.record()
  def resolve!(opts) do
    actor = PromptOn.SystemActor.new()

    case {opts[:org], opts[:user]} do
      {nil, nil} ->
        Mix.raise(
          "--org SLUG (team organization) or --user EMAIL (personal organization) is required"
        )

      {org_slug, nil} ->
        fetch!(
          Accounts.get_organization_by_slug(org_slug, actor: actor),
          "organization #{org_slug}"
        )

      {nil, email} ->
        user =
          fetch!(Accounts.get_user_by_email(email, actor: actor), "user #{email}")

        fetch!(
          Accounts.personal_organization_for(user.id, actor: actor),
          "personal organization for #{email}"
        )

      {_org_slug, _email} ->
        Mix.raise("--org and --user are mutually exclusive")
    end
  end

  @doc "Whether either `--org` or `--user` was given (to fail early, before the apply stage)."
  @spec given?(keyword()) :: boolean()
  def given?(opts), do: not is_nil(opts[:org]) or not is_nil(opts[:user])

  defp fetch!({:ok, nil}, what), do: Mix.raise("#{what} not found")
  defp fetch!({:ok, record}, _what), do: record
  defp fetch!({:error, reason}, what), do: Mix.raise("cannot look up #{what}: #{inspect(reason)}")
end
