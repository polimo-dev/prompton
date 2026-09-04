defmodule PromptOn.Repo.Migrations.RenameApiKeyResolveScopeToRead do
  use Ecto.Migration

  def change do
    execute(
      "UPDATE api_keys SET scopes = array_replace(scopes, 'resolve', 'read')",
      "UPDATE api_keys SET scopes = array_replace(scopes, 'read', 'resolve')"
    )
  end
end
