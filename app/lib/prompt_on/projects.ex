defmodule PromptOn.Projects do
  @moduledoc """
  Domain for the tenant container (Project), environments and SDK keys (plan.md §5.1). Project and
  ApiKey live outside the tenant, Environment inside. Provider keys (BYOK) are owned by the
  organization and therefore live in `PromptOn.Accounts`.
  """

  use Ash.Domain,
    otp_app: :prompton,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource PromptOn.Projects.Project do
      define :create_project, action: :create
      define :get_project, action: :read, get_by: [:id], not_found_error?: false

      define :get_project_by_slug,
        action: :by_slug,
        args: [:organization_id, :slug],
        not_found_error?: false

      define :list_projects, action: :active
      define :rename_project, action: :rename
      define :set_project_payload_policy, action: :set_payload_policy
      define :archive_project, action: :archive
    end

    resource PromptOn.Projects.Environment do
      define :add_environment, action: :add
      define :get_environment, action: :read, get_by: [:id], not_found_error?: false
      define :get_environment_by_slug, action: :by_slug, args: [:slug], not_found_error?: false
      define :list_environments, action: :active
      define :rename_environment, action: :rename
      define :archive_environment, action: :archive
      define :config_snapshot, action: :config_snapshot, args: [:environment_id]
    end

    resource PromptOn.Projects.ApiKey do
      define :issue_api_key, action: :issue
      define :revoke_api_key, action: :revoke
      define :touch_api_key, action: :touch_last_used
      define :api_key_by_raw_key, action: :by_raw_key, args: [:raw_key], not_found_error?: false
      define :list_api_keys, action: :for_project, args: [:project_id]
    end
  end
end
