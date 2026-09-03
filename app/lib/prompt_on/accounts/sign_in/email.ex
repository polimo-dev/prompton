defmodule PromptOn.Accounts.SignIn.Email do
  @moduledoc """
  The sign-in code email (`PromptOn.Accounts.SignIn.request/2` sends it through
  `PromptOn.Mailer`).

  **The code comes first in the body**: the first line of the text, and the big code is the first
  element of the HTML. The reader must be able to copy the code from nothing but a phone
  notification or the inbox preview (subject + first line of body). **It is not put in the
  subject**, and there is no hidden preheader text visible only in notifications (user
  instruction 2026-09-03).

  Text + simple HTML. The HTML shows the code large, spaced in groups of three (`123 456`), but
  **copying yields the six digits joined**: there is no whitespace character between the two
  `<span>`s. The input field is `maxlength="6"`, so pasting "123 456" with a space would truncate
  the last digit. The text body is written joined for the same reason.

  The sender is `PromptOn <noreply@prompton.ai>`, changed via `PTN_MAIL_FROM`
  (`config :prompton, :mail_from`, `"Name <addr>"` or just an address). The adapter is chosen by
  the environment: prod uses Resend, dev uses Resend if `PTN_RESEND_API_KEY` is set and
  `/dev/mailbox` otherwise, test uses Swoosh Test.
  """

  import Swoosh.Email

  @default_from {"PromptOn", "noreply@prompton.ai"}
  @subject "Your PromptOn sign-in code"

  @doc "Recipient address + raw code → `Swoosh.Email`."
  @spec build(String.t(), String.t()) :: Swoosh.Email.t()
  def build(recipient, code) when is_binary(recipient) and is_binary(code) do
    new()
    |> to(recipient)
    |> from(from())
    |> subject(@subject)
    |> text_body(text(code))
    |> html_body(html(code))
  end

  @doc "The mail subject (fixed; the code appears only in the first line of the body)."
  @spec subject() :: String.t()
  def subject, do: @subject

  @doc """
  The sender `{name, address}`, resolved from `config :prompton, :mail_from` (`PTN_MAIL_FROM`).
  `"Name <addr>"` is used as is; a bare address gets the name `PromptOn`; if unset,
  `PromptOn <noreply@prompton.ai>`.
  """
  @spec from() :: {String.t(), String.t()}
  def from do
    case Application.get_env(:prompton, :mail_from) do
      nil ->
        @default_from

      {name, address} when is_binary(name) and is_binary(address) ->
        {name, address}

      raw when is_binary(raw) ->
        case Regex.run(~r/^\s*(.*?)\s*<\s*([^>]+?)\s*>\s*$/, raw) do
          [_, "", address] -> {elem(@default_from, 0), address}
          [_, name, address] -> {name, address}
          nil -> {elem(@default_from, 0), String.trim(raw)}
        end
    end
  end

  # The first line is the code; it shows up in the preview as is.
  defp text(code) do
    """
    #{code}

    Your PromptOn sign-in code. Enter it on the sign-in page to finish signing in.
    It expires in 5 minutes. If you didn't request it, ignore this email.
    """
  end

  defp html(code) do
    {left, right} = String.split_at(code, 3)

    """
    <!doctype html>
    <html>
      <body style="margin:0;padding:32px 16px;background:#f6f6f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#111;">
        <div style="max-width:440px;margin:0 auto;background:#fff;border:1px solid #e5e5e5;border-radius:12px;padding:28px;">
          <p style="margin:0 0 20px;font-family:'Geist Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:36px;font-weight:500;letter-spacing:6px;color:#111;"><span>#{left}</span><span style="margin-left:18px;">#{right}</span></p>
          <p style="margin:0 0 6px;font-size:13px;color:#666;">PromptOn</p>
          <h1 style="margin:0 0 12px;font-size:18px;font-weight:600;">Your sign-in code</h1>
          <p style="margin:0 0 16px;font-size:14px;line-height:1.5;">Enter it on the sign-in page to finish signing in.</p>
          <p style="margin:0;font-size:12px;line-height:1.5;color:#666;">It expires in 5 minutes.<br />If you didn't request it, ignore this email.</p>
        </div>
      </body>
    </html>
    """
  end
end
