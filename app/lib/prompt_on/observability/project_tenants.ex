defmodule PromptOn.Observability.ProjectTenants do
  @moduledoc """
  AshOban `list_tenants` -- returns **every** project id so the retention job runs once per project
  (tenant). Archived projects are included: raw-content retention must be honored even after
  archiving, so this reads with the default `:read` rather than `:active`. `GenerationPayload` is
  `multitenancy global? false`, so it cannot be read without a tenant.
  """

  @behaviour AshOban.ListTenants

  @impl true
  def list_tenants(_opts) do
    PromptOn.Projects.Project
    |> Ash.Query.select([:id])
    |> Ash.read(actor: PromptOn.SystemActor.new())
    |> case do
      {:ok, projects} -> Enum.map(projects, & &1.id)
      {:error, _} -> []
    end
  end
end
