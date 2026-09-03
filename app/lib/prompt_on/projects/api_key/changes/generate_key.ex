defmodule PromptOn.Projects.ApiKey.Changes.GenerateKey do
  @moduledoc """
  Generates the raw `ptn_<project_slug>_<random32>` key, stores `key_hash` (sha256 hex) and
  `key_prefix` (first 16 characters), and returns the raw key only as the `:raw_key` metadata of the
  resulting record.

  The prefix changed from the environment slug to the **project slug** because keys are no longer
  bound to an environment (2026-09-01: the environment is chosen by the request parameter).

  Prefix `pon_` -> `ptn_` (2026-09-03): authentication only compares the sha256 of the raw key with
  `key_hash` in `ApiKey.:by_raw_key` and never inspects the prefix string (the same goes for
  `PromptOnWeb.Plugs.ApiKeyAuth`), so already-issued `pon_…` keys keep working until revoked. Only
  newly minted keys use `ptn_`.
  """

  use Ash.Resource.Change

  alias PromptOn.Projects

  @impl true
  def change(changeset, _opts, _context) do
    project_id = Ash.Changeset.get_attribute(changeset, :project_id)

    case fetch_project(project_id) do
      {:ok, project} when not is_nil(project) ->
        raw = "ptn_#{project.slug}_" <> random32()

        changeset
        |> Ash.Changeset.force_change_attribute(:key_hash, PromptOn.Projects.ApiKey.hash(raw))
        |> Ash.Changeset.force_change_attribute(:key_prefix, String.slice(raw, 0, 16))
        |> Ash.Changeset.after_action(fn _changeset, record ->
          {:ok, Ash.Resource.put_metadata(record, :raw_key, raw)}
        end)

      _ ->
        Ash.Changeset.add_error(changeset,
          field: :project_id,
          message: "project not found"
        )
    end
  end

  defp fetch_project(nil), do: {:ok, nil}

  defp fetch_project(project_id),
    do: Projects.get_project(project_id, actor: PromptOn.SystemActor.new())

  # 32 URL-safe characters (a-z0-9), about 165 bits of entropy
  defp random32 do
    :crypto.strong_rand_bytes(24)
    |> Base.encode32(case: :lower, padding: false)
    |> String.slice(0, 32)
  end
end
