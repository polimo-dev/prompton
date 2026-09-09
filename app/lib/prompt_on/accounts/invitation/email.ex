defmodule PromptOn.Accounts.Invitation.Email do
  @moduledoc """
  Email sent when a member is invited to a PromptOn organization.
  """

  import Swoosh.Email

  @subject "You're invited to PromptOn"

  @doc "Recipient, raw token and the known invitation context -> `Swoosh.Email`."
  @spec build(String.t(), String.t(), String.t(), String.t()) :: Swoosh.Email.t()
  def build(recipient, token, organization_name, inviter_email)
      when is_binary(recipient) and is_binary(token) and is_binary(organization_name) and
             is_binary(inviter_email) do
    url = invitation_url(token)

    new()
    |> to(recipient)
    |> from(PromptOn.Accounts.SignIn.Email.from())
    |> subject(@subject)
    |> text_body(text(url, recipient, organization_name, inviter_email))
    |> html_body(html(url, recipient, organization_name, inviter_email))
  end

  @doc "The public URL for a raw invitation token, derived only from Endpoint configuration."
  @spec invitation_url(String.t()) :: String.t()
  def invitation_url(token) when is_binary(token),
    do: PromptOnWeb.Endpoint.url() <> "/invitations/" <> URI.encode_www_form(token)

  defp text(url, recipient, organization_name, inviter_email) do
    """
    #{inviter_email} invited you to join #{organization_name} on PromptOn.

    This invitation is for #{recipient}. Open the link and click Join to create your account or
    sign in and join the organization. You won't need another email verification code.
    #{url}

    This invitation expires in 7 days. Keep this link private; it gives access to your invitation.
    If you did not expect this invitation, ignore this email.
    """
  end

  defp html(url, recipient, organization_name, inviter_email) do
    url = escape(url)
    recipient = escape(recipient)
    organization_name = escape(organization_name)
    inviter_email = escape(inviter_email)

    """
    <!doctype html>
    <html>
      <body style="margin:0;padding:32px 16px;background:#f6f6f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111;">
        <div style="max-width:440px;margin:0 auto;background:#fff;border:1px solid #e5e5e5;border-radius:12px;padding:28px;">
          <p style="margin:0 0 6px;font-size:13px;color:#666;">PromptOn</p>
          <h1 style="margin:0 0 12px;font-size:18px;font-weight:600;">Join #{organization_name}</h1>
          <p style="margin:0 0 18px;font-size:14px;line-height:1.5;">#{inviter_email} invited you to join #{organization_name} on PromptOn.</p>
          <p style="margin:0 0 18px;font-size:14px;line-height:1.5;">This invitation is for <strong>#{recipient}</strong>. Open the link and click Join to create your account or sign in and join the organization. You won't need another email verification code.</p>
          <p style="margin:0 0 18px;"><a href="#{url}" style="display:inline-block;background:#111;color:#fff;text-decoration:none;border-radius:8px;padding:10px 14px;font-size:14px;">Open invitation</a></p>
          <p style="margin:0 0 18px;font-size:12px;line-height:1.5;color:#666;">If the button doesn't work, open this link:<br /><a href="#{url}" style="color:#111;overflow-wrap:anywhere;">#{url}</a></p>
          <p style="margin:0;font-size:12px;line-height:1.5;color:#666;">This invitation expires in 7 days. Keep this link private; it gives access to your invitation.<br />If you did not expect this invitation, ignore this email.</p>
        </div>
      </body>
    </html>
    """
  end

  defp escape(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
