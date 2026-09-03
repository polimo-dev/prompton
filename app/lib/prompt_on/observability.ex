defmodule PromptOn.Observability do
  @moduledoc """
  The logging and monitoring domain (plan.md §5.7, §9): the narrow `Generation` table plus its 1:1
  `GenerationPayload` (encrypted raw content), the raw-content storage policy `PayloadPolicy`
  (embedded, owned by Project/UseCase), the batch ingest service `PromptOn.Observability.Ingest`,
  and the aggregation `PromptOn.Observability.Stats`. Every resource lives inside a tenant
  (`project_id`).
  """

  use Ash.Domain,
    otp_app: :prompton,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource PromptOn.Observability.Generation do
      define :ingest_generation, action: :ingest
      define :get_generation, action: :read, get_by: [:id], not_found_error?: false
      define :list_generations, action: :list_for_project
      define :generations_for_trace, action: :for_trace, args: [:trace_id]
      define :generations_for_end_user, action: :for_end_user, args: [:end_user_ref]
    end

    resource PromptOn.Observability.GenerationPayload do
      define :store_payload, action: :store
      define :get_payload, action: :read, get_by: [:generation_id], not_found_error?: false
      define :expired_payloads, action: :expired
      define :purge_expired_payloads, action: :purge_expired
      define :purge_payloads_for_end_user, action: :purge_for_end_user, args: [:end_user_ref]
    end
  end
end
