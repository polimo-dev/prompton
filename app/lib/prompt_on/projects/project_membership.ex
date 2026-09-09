defmodule PromptOn.Projects.ProjectMembership do
  @moduledoc """
  Per-project access grants for organization members with the `:member` role.

  The row is valid only while the user is still a member of the project owner's organization. The
  policies repeat that organization-membership requirement so a stale grant cannot leak access.
  """

  use Ash.Resource,
    otp_app: :prompton,
    domain: PromptOn.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "project_memberships"
    repo PromptOn.Repo

    # Existing non-manager roles previously accessed every project in their organization. Keep
    # those grants during the rollout without guessing who created historical projects.
    custom_statements do
      statement :backfill_legacy_project_access do
        after_tables ["projects", "memberships"]

        up """
        INSERT INTO project_memberships (id, project_id, user_id, inserted_at, updated_at)
        SELECT uuid_generate_v7(), projects.id, memberships.user_id, now(), now()
        FROM projects
        JOIN memberships ON memberships.organization_id = projects.organization_id
        WHERE memberships.role IN ('editor', 'viewer')
        ON CONFLICT (project_id, user_id) DO NOTHING
        """

        down "SELECT 1"
      end
    end

    references do
      reference :project, on_delete: :delete
      reference :user, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :grant do
      accept [:project_id, :user_id]
      upsert? true
      upsert_identity :unique_project_member
      upsert_fields []
      change PromptOn.Projects.ProjectMembership.Changes.ValidateUserInProjectOrganization
    end

    destroy :revoke do
    end
  end

  policies do
    bypass PromptOn.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if {PromptOn.Checks.ProjectMember, path: [:project]}
    end

    policy action_type([:create, :destroy]) do
      authorize_if PromptOn.Checks.CanGrantProjectMembership
    end
  end

  attributes do
    uuid_v7_primary_key :id

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :project, PromptOn.Projects.Project do
      allow_nil? false
      public? true
    end

    belongs_to :user, PromptOn.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_project_member, [:project_id, :user_id]
  end
end
