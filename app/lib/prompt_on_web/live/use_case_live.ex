defmodule PromptOnWeb.UseCaseLive do
  @moduledoc """
  Use case detail (`/:org_slug/:project_slug/use-cases/:key`); **only the redirect to the hub is
  left**.

  Everything about a use case (model · prompt · arena · deployment · deployment history) now lives
  in one screen, `PromptOnWeb.PromptEditorLive`. Other screens and bookmarks still point at this
  route, so it stays alive, but instead of drawing a screen it hands over with `push_navigate`.

  URL state is carried across the handover:

  - `?tab=deployments` → the same tab of the hub. The old `?tab=prompts` is the hub's default tab
    (editor), so it is dropped.
  - `?prompt=<name>` → as is.

  Opening a missing use case sends the user to the list with a flash (same wording as the hub).
  """
  use PromptOnWeb, :live_view

  alias PromptOn.Prompts

  @impl Phoenix.LiveView
  def mount(%{"key" => key} = params, _session, socket) do
    %{org_slug: org_slug, project: %{slug: slug}} = socket.assigns

    case Prompts.get_use_case_by_key(key,
           tenant: socket.assigns.project.id,
           actor: socket.assigns.current_user
         ) do
      {:ok, %{key: found}} ->
        {:ok, push_navigate(socket, to: hub_path(org_slug, slug, found, params))}

      # With `not_found_error?: false` a missing key comes back as `{:ok, nil}` (not an error).
      _missing ->
        {:ok,
         socket
         |> put_flash(:error, "Use case not found: #{key}")
         |> push_navigate(to: ~p"/#{org_slug}/#{slug}/use-cases")}
    end
  end

  defp hub_path(org_slug, slug, key, params) do
    query =
      [tab: tab_param(params), prompt: prompt_param(params)]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/#{org_slug}/#{slug}/use-cases/#{key}/prompt?#{query}"
  end

  defp tab_param(%{"tab" => "deployments"}), do: "deployments"
  defp tab_param(_params), do: nil

  defp prompt_param(%{"prompt" => name}) when is_binary(name) and name != "", do: name
  defp prompt_param(_params), do: nil

  # Mount redirects immediately, so render is never reached: an empty screen that satisfies the
  # LiveView contract.
  @impl Phoenix.LiveView
  def render(assigns), do: ~H""
end
