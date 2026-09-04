defmodule Mix.Tasks.Prompton.SetPlan do
  @shortdoc "Set an organization's entitlement plan (free | team | pro)"

  @moduledoc """
      mix prompton.set_plan --org acme-inc --plan pro
      mix prompton.set_plan --email you@example.com --plan team

  Sets `PromptOn.Accounts.Organization.plan` through `:set_plan` as the system actor
  (ADR 0010 §2.8). Plans are not self-serve and there is no billing: this task — and later the
  private admin app — is the operational handle.

  The organization is addressed either by `--org <slug>` (a team organization) or by `--email
  <address>` (that user's **personal** organization, the row a paying person's plan lives on).
  `PromptOn.Entitlements` is what turns the resulting value into limits; nothing else reads it.
  """

  use Mix.Task

  alias PromptOn.Accounts
  alias PromptOn.Entitlements

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [org: :string, email: :string, plan: :string])

    plan = parse_plan(opts[:plan])

    Mix.Task.run("app.start")

    actor = PromptOn.SystemActor.new()
    organization = resolve_organization(opts, actor)

    case Accounts.set_organization_plan(organization, %{plan: plan}, actor: actor) do
      {:ok, updated} ->
        Mix.shell().info(
          "#{describe(updated)} is now on the #{Entitlements.label(updated.plan)} plan"
        )

        Enum.each(Entitlements.limits(updated.plan), fn {limit, value} ->
          Mix.shell().info("  #{limit}: #{value}")
        end)

      {:error, error} ->
        Mix.raise("could not set the plan: #{Exception.message(error)}")
    end
  end

  defp parse_plan(nil), do: Mix.raise("--plan is required (#{plan_list()})")

  defp parse_plan(value) do
    plan = String.to_existing_atom(value)
    if plan in Entitlements.plans(), do: plan, else: Mix.raise("unknown plan (#{plan_list()})")
  rescue
    ArgumentError -> Mix.raise("unknown plan (#{plan_list()})")
  end

  defp plan_list, do: Enum.map_join(Entitlements.plans(), " | ", &to_string/1)

  defp resolve_organization(opts, actor) do
    case {opts[:org], opts[:email]} do
      {nil, nil} -> Mix.raise("--org <slug> or --email <address> is required")
      {slug, nil} -> by_slug(slug, actor)
      {nil, email} -> personal_for(email, actor)
      {_slug, _email} -> Mix.raise("pass either --org or --email, not both")
    end
  end

  defp by_slug(slug, actor) do
    case Accounts.get_organization_by_slug(slug, actor: actor) do
      {:ok, %PromptOn.Accounts.Organization{} = organization} -> organization
      _other -> Mix.raise("no team organization with slug #{slug}")
    end
  end

  defp personal_for(email, actor) do
    with {:ok, %PromptOn.Accounts.User{} = user} <-
           Accounts.get_user_by_email(email, actor: actor),
         {:ok, %PromptOn.Accounts.Organization{} = organization} <-
           Accounts.personal_organization_for(user.id, actor: actor) do
      organization
    else
      _other -> Mix.raise("no personal organization for #{email}")
    end
  end

  defp describe(%{personal?: true, name: name}), do: "personal organization #{inspect(name)}"
  defp describe(%{slug: slug}), do: "/#{slug}"
end
