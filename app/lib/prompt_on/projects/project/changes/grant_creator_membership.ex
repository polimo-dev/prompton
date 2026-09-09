defmodule PromptOn.Projects.Project.Changes.GrantCreatorMembership do
  @moduledoc "Grants explicit project access to the user who created the project."

  use Ash.Resource.Change

  alias PromptOn.Projects

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, project ->
      case project.creator_id do
        nil ->
          {:ok, project}

        user_id ->
          case Projects.grant_project_membership(%{project_id: project.id, user_id: user_id},
                 actor: PromptOn.SystemActor.new()
               ) do
            {:ok, _grant} -> {:ok, project}
            {:error, error} -> {:error, error}
          end
      end
    end)
  end
end
