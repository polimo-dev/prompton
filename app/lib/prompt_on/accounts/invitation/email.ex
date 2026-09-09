defmodule PromptOn.Accounts.Invitation.Email do
  @moduledoc """
  Email sent when a member is invited to a PromptOn organization.
  """

  import Swoosh.Email

  @subject "You're invited to PromptOn"

  @doc "Recipient address + raw invitation token -> `Swoosh.Email`."
  @spec build(String.t(), String.t()) :: Swoosh.Email.t()
  def build(recipient, token) when is_binary(recipient) and is_binary(token) do
    url = invitation_url(token)

    new()
    |> to(recipient)
    |> from(PromptOn.Accounts.SignIn.Email.from())
    |> subject(@subject)
    |> text_body(text(url))
    |> html_body(html(url))
  end

  @doc "The public URL for a raw invitation token, derived only from Endpoint configuration."
  @spec invitation_url(String.t()) :: String.t()
  def invitation_url(token) when is_binary(token),
    do: PromptOnWeb.Endpoint.url() <> "/invitations/" <> URI.encode_www_form(token)

  defp text(url) do
    """
    You've been invited to join a PromptOn organization.

    Open this link and click Join to accept the invitation:
    #{url}

    This invitation expires in 7 days. If you did not expect this invitation, ignore this email.
    """
  end

  defp html(url) do
    """
    <!doctype html>
    <html>
      <body style="margin:0;padding:32px 16px;background:#f6f6f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111;">
        <div style="max-width:440px;margin:0 auto;background:#fff;border:1px solid #e5e5e5;border-radius:12px;padding:28px;">
          <p style="margin:0 0 6px;font-size:13px;color:#666;">PromptOn</p>
          <h1 style="margin:0 0 12px;font-size:18px;font-weight:600;">You have been invited</h1>
          <p style="margin:0 0 18px;font-size:14px;line-height:1.5;">Open the invitation and click Join to accept.</p>
          <p style="margin:0 0 18px;"><a href="#{url}" style="display:inline-block;background:#111;color:#fff;text-decoration:none;border-radius:8px;padding:10px 14px;font-size:14px;">Open invitation</a></p>
          <p style="margin:0;font-size:12px;line-height:1.5;color:#666;">This invitation expires in 7 days.</p>
        </div>
      </body>
    </html>
    """
  end
end
