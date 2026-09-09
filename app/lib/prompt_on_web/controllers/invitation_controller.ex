defmodule PromptOnWeb.InvitationController do
  @moduledoc """
  Invitation accept flow.

  The router requires a signed-in user while preserving the invitation URL through the email-code
  sign-in flow. This controller never accepts on `GET`; it previews the target organization and
  requires an explicit Join button click.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Accounts
  alias PromptOnWeb.ErrorText

  plug :private_token_response

  def show(conn, %{"token" => token}) do
    preview(conn, token, fn conn, view ->
      if matching_email?(conn.assigns.current_user, view) do
        render(conn, :show, assigns(view, token))
      else
        render(conn, :wrong_account, assigns(view, token))
      end
    end)
  end

  def join(conn, %{"token" => token}) do
    preview(conn, token, fn conn, view ->
      if matching_email?(conn.assigns.current_user, view) do
        case Accounts.accept_invitation(token, actor: conn.assigns.current_user) do
          {:ok, accepted} ->
            redirect_to = organization_path(accepted) || organization_path(view) || ~p"/personal"

            conn
            |> put_flash(:info, "You joined #{view.organization_name}.")
            |> redirect(to: redirect_to)

          {:error, error} ->
            render(conn, :unavailable, assigns(view, token, ErrorText.message(error)))
        end
      else
        conn
        |> put_status(:forbidden)
        |> render(:wrong_account, assigns(view, token))
      end
    end)
  end

  defp preview(conn, token, fun) do
    case Accounts.preview_invitation(token, actor: conn.assigns.current_user) do
      {:ok, invitation} ->
        fun.(conn, view(invitation))

      {:error, error} ->
        conn
        |> put_status(:not_found)
        |> render(:unavailable, assigns(empty_view(), token, ErrorText.message(error)))
    end
  end

  defp private_token_response(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp assigns(view, token, error \\ nil) do
    Map.merge(view, %{page_title: "Join #{view.organization_name}", token: token, error: error})
  end

  defp view(invitation) do
    organization = field(invitation, :organization)

    %{
      invitation: invitation,
      organization: organization,
      organization_name: organization_name(organization, invitation),
      organization_path: organization_path(organization),
      invited_email: to_string(field(invitation, :email) || ""),
      role: field(invitation, :role) || :member,
      projects: invitation_projects(invitation)
    }
  end

  defp empty_view do
    %{
      invitation: nil,
      organization: nil,
      organization_name: "this organization",
      organization_path: nil,
      invited_email: "",
      role: :member,
      projects: []
    }
  end

  defp matching_email?(user, %{invited_email: invited_email}) do
    normalize_email(field(user, :email)) == normalize_email(invited_email)
  end

  defp normalize_email(email), do: email |> to_string() |> String.trim() |> String.downcase()

  defp organization_name(%{name: name}, _invitation) when is_binary(name), do: name

  defp organization_name(_organization, invitation),
    do: field(invitation, :organization_name) || "this organization"

  defp organization_path(%{personal?: true}), do: ~p"/personal"
  defp organization_path(%{slug: slug}) when is_binary(slug), do: ~p"/#{slug}"
  defp organization_path(%{organization: organization}), do: organization_path(organization)
  defp organization_path(_other), do: nil

  defp invitation_projects(invitation) do
    case Ash.Resource.get_metadata(invitation, :projects) do
      projects when is_list(projects) -> projects
      _other -> []
    end
  rescue
    _error -> []
  end

  defp field(nil, _field), do: nil

  defp field(map, field) when is_map(map),
    do: Map.get(map, field) || Map.get(map, to_string(field))
end
