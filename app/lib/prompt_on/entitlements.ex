defmodule PromptOn.Entitlements do
  @moduledoc """
  Plan limits — the single place that defines them and the single place that answers them
  (ADR 0010 §2.9). Nothing else in the codebase may hard-code a number from the `@limits` table
  below: enforcement sites, the settings screens and the retention job all read it from here.

  This is a plain module, not an Ash resource. The plan itself is an attribute of
  `PromptOn.Accounts.Organization` (`:free | :team | :pro`, system-actor-settable only — there is
  no billing and no self-serve change).

  ## The three answers

  - `limits/1` / `limit/2` — what a plan allows (numbers for display, numbers for enforcement).
  - `allows?/2` — the boolean limits (`:team_organizations`, `:automatic_evaluation`).
  - `check/4` — the gate: given how many already exist, may the next one be created? Returns `:ok`
    or an `Ash.Error.Changes.InvalidAttribute` carrying a user-facing sentence.

  Every refusal is an `InvalidAttribute` because `PromptOnWeb.ErrorText.message/1` renders it as
  `"<field>: <sentence>"`; the sentences are therefore self-contained and never start with a verb
  that only makes sense after a field name. The field used at each call site is `:plan` (ADR 0010
  §6), so the flash reads `"plan: the Free plan allows 2 projects per organization. …"`.

  ## Reading a plan

  `plan/1` and `plan_for_project/1` load with `PromptOn.SystemActor.new()`. A plan is not
  member-sensitive information and the retention job has no user actor, so one code path serves
  both. Anything that cannot be resolved falls back to `:free` — the safe direction for a limit.

  ## Self-hosting

  `config :prompton, :entitlements_plan_override` (default `nil`) makes `plan/1` return that plan
  for every organization. That keeps "self-hosted = everything allowed" out of the enforcement
  sites, which stay identical in both deployments.

  ## Races

  `check/4` is read-then-write without a lock, so two simultaneous creates can both pass and leave
  an organization one over its limit. Accepted (ADR 0010 §6): these are product limits, not
  security boundaries, and advisory locks on every create cost more than the overshoot.
  """

  alias PromptOn.Accounts.Organization
  alias PromptOn.Projects.Project

  @type plan :: :free | :team | :pro

  @type limit ::
          :projects_per_organization
          | :use_cases_per_project
          | :log_count_per_use_case
          | :log_retention_days
          | :members_per_organization
          | :team_organizations
          | :automatic_evaluation
          | :evaluation_sample_limit

  @type value :: pos_integer() | boolean()

  @plans [:free, :team, :pro]

  @limits %{
    free: %{
      projects_per_organization: 2,
      use_cases_per_project: 10,
      log_count_per_use_case: 1_000,
      log_retention_days: 7,
      members_per_organization: 1,
      team_organizations: false,
      automatic_evaluation: false,
      evaluation_sample_limit: 1_000
    },
    team: %{
      projects_per_organization: 20,
      use_cases_per_project: 100,
      log_count_per_use_case: 100_000,
      log_retention_days: 30,
      members_per_organization: 10,
      team_organizations: true,
      automatic_evaluation: false,
      evaluation_sample_limit: 1_000
    },
    pro: %{
      projects_per_organization: 20,
      use_cases_per_project: 100,
      log_count_per_use_case: 100_000,
      log_retention_days: 90,
      members_per_organization: 25,
      team_organizations: true,
      automatic_evaluation: true,
      evaluation_sample_limit: 1_000
    }
  }

  @labels %{free: "Free", team: "Team", pro: "Pro"}

  @doc """
  The plans, cheapest first.

      iex> PromptOn.Entitlements.plans()
      [:free, :team, :pro]
  """
  @spec plans() :: [plan()]
  def plans, do: @plans

  @doc """
  Display label of a plan.

      iex> PromptOn.Entitlements.label(:free)
      "Free"
  """
  @spec label(plan()) :: String.t()
  def label(plan) when is_atom(plan), do: Map.get(@labels, plan, @labels.free)

  @doc """
  Every limit of a plan (or of an organization). The org settings plan card renders this map
  directly, which is why the order of the keys does not matter but the completeness does.

      iex> PromptOn.Entitlements.limits(:free)[:projects_per_organization]
      2
  """
  @spec limits(plan() | Organization.t() | Ash.UUID.t() | nil) :: %{limit() => value()}
  def limits(plan_or_organization), do: Map.fetch!(@limits, plan(plan_or_organization))

  @doc """
  One limit of a plan (or of an organization).

      iex> PromptOn.Entitlements.limit(:pro, :log_retention_days)
      90
  """
  @spec limit(plan() | Organization.t() | Ash.UUID.t() | nil, limit()) :: value()
  def limit(plan_or_organization, limit) when is_atom(limit),
    do: plan_or_organization |> limits() |> Map.fetch!(limit)

  @doc """
  Whether a plan allows a feature at all. Boolean limits answer themselves; a numeric limit is
  allowed when it is greater than zero.

      iex> PromptOn.Entitlements.allows?(:free, :team_organizations)
      false

      iex> PromptOn.Entitlements.allows?(:pro, :automatic_evaluation)
      true
  """
  @spec allows?(plan() | Organization.t() | Ash.UUID.t() | nil, limit()) :: boolean()
  def allows?(plan_or_organization, limit) do
    case limit(plan_or_organization, limit) do
      value when is_boolean(value) -> value
      value when is_integer(value) -> value > 0
    end
  end

  @doc """
  The gate. `count` is how many already exist; the `count + 1`-th is the one being created.

  Returns `:ok`, or an `Ash.Error.Changes.InvalidAttribute` on `field` carrying `message/2`.
  Boolean limits are checked with `allows?/2` instead — there is nothing to count.

      iex> PromptOn.Entitlements.check(:free, :projects_per_organization, 1, :plan)
      :ok

      iex> {:error, error} = PromptOn.Entitlements.check(:free, :projects_per_organization, 2, :plan)
      iex> error.field
      :plan
  """
  @spec check(plan(), limit(), non_neg_integer(), atom()) ::
          :ok | {:error, Ash.Error.Changes.InvalidAttribute.t()}
  def check(plan, limit, count, field)
      when is_atom(plan) and is_atom(limit) and is_integer(count) and is_atom(field) do
    max = limit(plan, limit)

    if is_integer(max) and count >= max do
      {:error, error(plan, limit, field)}
    else
      :ok
    end
  end

  @doc """
  The refusal as an `InvalidAttribute`, for a validation that wants to add it to a changeset
  itself.
  """
  @spec error(plan(), limit(), atom()) :: Ash.Error.Changes.InvalidAttribute.t()
  def error(plan, limit, field) do
    Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message(plan, limit))
  end

  @doc """
  The same sentence without a changeset — for a disabled button's tooltip or an inline note.

      iex> PromptOn.Entitlements.message(:free, :projects_per_organization)
      "the Free plan allows 2 projects per organization. Archive a project, or upgrade the organization to Team."
  """
  @spec message(plan() | Organization.t() | Ash.UUID.t() | nil, limit()) :: String.t()
  def message(plan_or_organization, limit),
    do: sentence(plan(plan_or_organization), limit)

  defp sentence(plan, :projects_per_organization) do
    "the #{label(plan)} plan allows #{limit(plan, :projects_per_organization)} projects " <>
      "per organization. " <> archive_hint(plan, "project")
  end

  defp sentence(plan, :use_cases_per_project) do
    "the #{label(plan)} plan allows #{limit(plan, :use_cases_per_project)} use cases " <>
      "per project. " <> archive_hint(plan, "use case")
  end

  defp sentence(:free, :members_per_organization) do
    "the Free plan is a single-member organization. Upgrade to Team to invite members."
  end

  defp sentence(plan, :members_per_organization) do
    "the #{label(plan)} plan allows #{limit(plan, :members_per_organization)} members " <>
      "per organization."
  end

  defp sentence(plan, :team_organizations) do
    "team organizations are a Team plan feature. Your account is on the #{label(plan)} plan."
  end

  defp sentence(plan, :automatic_evaluation) do
    "automatic evaluation is a Pro plan feature. This organization is on the " <>
      "#{label(plan)} plan."
  end

  defp sentence(plan, :log_count_per_use_case) do
    "the #{label(plan)} plan keeps the most recent " <>
      "#{number(limit(plan, :log_count_per_use_case))} monitoring logs per use case."
  end

  defp sentence(plan, :log_retention_days) do
    "the #{label(plan)} plan keeps monitoring logs for " <>
      "#{limit(plan, :log_retention_days)} days."
  end

  defp sentence(plan, :evaluation_sample_limit) do
    "the #{label(plan)} plan evaluates up to " <>
      "#{number(limit(plan, :evaluation_sample_limit))} logs in one run."
  end

  defp archive_hint(:free, noun),
    do: "Archive a #{noun}, or upgrade the organization to Team."

  defp archive_hint(_plan, noun), do: "Archive a #{noun} to make room."

  @doc """
  Thousands separator for the limit numbers shown to people.

      iex> PromptOn.Entitlements.number(100_000)
      "100,000"
  """
  @spec number(integer()) :: String.t()
  def number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc """
  The plan of an organization, an organization id, or a plan atom (the identity case, so callers
  can pass either without branching). Unknown input and load failures fall back to `:free`.

  `config :prompton, :entitlements_plan_override` wins over everything.
  """
  @spec plan(Organization.t() | Ash.UUID.t() | plan() | nil) :: plan()
  def plan(subject) do
    case override() do
      nil -> resolve_plan(subject)
      plan -> plan
    end
  end

  defp resolve_plan(plan) when plan in @plans, do: plan
  defp resolve_plan(%Organization{plan: plan}) when plan in @plans, do: plan
  defp resolve_plan(%Organization{}), do: :free

  defp resolve_plan(id) when is_binary(id) do
    case Ash.get(Organization, id, actor: PromptOn.SystemActor.new()) do
      {:ok, %Organization{} = organization} -> resolve_plan(organization)
      _other -> :free
    end
  end

  defp resolve_plan(_other), do: :free

  @doc """
  The plan of the organization owning a project (a `Project` struct or a project id — the tenant
  the retention job is handed).
  """
  @spec plan_for_project(Project.t() | Ash.UUID.t() | nil) :: plan()
  def plan_for_project(subject) do
    case override() do
      nil -> resolve_project_plan(subject)
      plan -> plan
    end
  end

  defp resolve_project_plan(%Project{organization_id: organization_id}),
    do: resolve_plan(organization_id)

  defp resolve_project_plan(id) when is_binary(id) do
    case Ash.get(Project, id, actor: PromptOn.SystemActor.new()) do
      {:ok, %Project{} = project} -> resolve_project_plan(project)
      _other -> :free
    end
  end

  defp resolve_project_plan(_other), do: :free

  @doc """
  Like `plan_for_project/1`, but says so when the plan could not be read.

  `plan_for_project/1` falls back to `:free`, which is the safe direction for a **creation** gate
  and the destructive direction for the retention **deletion** job: a transient read failure would
  turn a Pro tenant's 90-day window into 7 days and delete ~83 days of logs, with no undo. The purge
  uses this function and skips a tenant it cannot resolve.
  """
  @spec plan_for_project_result(Project.t() | Ash.UUID.t() | nil) :: {:ok, plan()} | :error
  def plan_for_project_result(subject) do
    case override() do
      nil -> lookup_project_plan(subject)
      plan -> {:ok, plan}
    end
  end

  defp lookup_project_plan(%Project{organization_id: organization_id}),
    do: lookup_plan(organization_id)

  defp lookup_project_plan(id) when is_binary(id) do
    case Ash.get(Project, id, actor: PromptOn.SystemActor.new()) do
      {:ok, %Project{} = project} -> lookup_project_plan(project)
      _other -> :error
    end
  end

  defp lookup_project_plan(_other), do: :error

  defp lookup_plan(plan) when plan in @plans, do: {:ok, plan}
  defp lookup_plan(%Organization{plan: plan}) when plan in @plans, do: {:ok, plan}

  defp lookup_plan(id) when is_binary(id) do
    case Ash.get(Organization, id, actor: PromptOn.SystemActor.new()) do
      {:ok, %Organization{} = organization} -> lookup_plan(organization)
      _other -> :error
    end
  end

  defp lookup_plan(_other), do: :error

  defp override do
    case Application.get_env(:prompton, :entitlements_plan_override) do
      plan when plan in @plans -> plan
      _other -> nil
    end
  end
end
