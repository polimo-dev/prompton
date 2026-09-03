defmodule PromptOn.ProjectScoped do
  @moduledoc """
  Shared fragment for project-scoped (tenant) resources. plan.md §5.3:

      use Ash.Resource, ..., fragments: [PromptOn.ProjectScoped]

  - `multitenancy strategy :attribute, attribute :project_id, global? false`: calls without a tenant
    are an error.
  - `belongs_to :project` (FK `on_delete: :delete`): `PromptOn.Checks.ProjectMember` uses this path.
  - `postgres repo PromptOn.Repo`: each resource only declares its `table`.

  Resources outside the tenant (User/Token/Organization/Membership/Project/ApiKey) do not use this
  fragment.
  """

  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    repo PromptOn.Repo

    references do
      reference :project, on_delete: :delete
    end
  end

  multitenancy do
    strategy :attribute
    attribute :project_id
    global? false
  end

  relationships do
    belongs_to :project, PromptOn.Projects.Project do
      allow_nil? false
      public? true
    end
  end
end
