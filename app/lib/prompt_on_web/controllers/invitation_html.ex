defmodule PromptOnWeb.InvitationHTML do
  @moduledoc """
  Templates for the signed-in invitation flow.

  Opening an invitation link only previews the invitation. Joining happens on the separate
  `POST /invitations/:token/join` request so email scanners and accidental opens cannot accept it.
  """

  use PromptOnWeb, :html

  import PromptOnWeb.AuthComponents

  embed_templates "invitation_html/*"

  def project_name(%{name: name}) when is_binary(name), do: name
  def project_name(%{slug: slug}) when is_binary(slug), do: slug
  def project_name(project), do: to_string(project)
end
