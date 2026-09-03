defmodule PromptOn.Catalog do
  @moduledoc """
  Per-project model catalog domain (plan.md §5.1, §5.4). Each app exposes different models, display
  names and description keys (HeyDiary `ai_models`), so this is **project-scoped** rather than a
  global directory. A global directory is P2.
  """

  use Ash.Domain,
    otp_app: :prompton,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource PromptOn.Catalog.Model do
      define :register_model, action: :register
      define :get_model, action: :read, get_by: [:id], not_found_error?: false

      define :get_model_by_provider_model,
        action: :by_provider_model,
        args: [:provider, :model_id],
        not_found_error?: false

      define :list_models, action: :active
      define :list_all_models, action: :read
      define :edit_model_metadata, action: :edit_metadata
      define :set_model_provider_options, action: :set_provider_options
      define :set_model_pricing, action: :set_pricing
      define :deprecate_model, action: :deprecate
      define :archive_model, action: :archive
    end
  end
end
