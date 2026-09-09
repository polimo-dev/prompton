defmodule PromptOn.Accounts.InvitationEmailTest do
  use PromptOn.DataCase, async: false

  alias PromptOn.Accounts.Invitation
  alias PromptOn.Accounts.Invitation.Email
  alias PromptOn.Fixtures

  test "delivered invitations identify the inviter, organization and invited address" do
    owner = Fixtures.user_fixture()

    organization =
      %{user: owner, name: "Research & Development"}
      |> Fixtures.team_org_fixture()
      |> Fixtures.set_plan(:team)

    recipient = Fixtures.unique_email()

    assert {:ok, invitation} =
             Invitation
             |> Ash.Changeset.for_create(
               :invite,
               %{organization_id: organization.id, email: recipient, role: :member},
               actor: owner
             )
             |> Ash.create()

    assert_receive {:email, %Swoosh.Email{} = email}, 500
    assert email.to == [{"", recipient}]
    assert email.from == PromptOn.Accounts.SignIn.Email.from()
    assert email.text_body =~ "#{owner.email} invited you to join #{organization.name}"
    assert email.text_body =~ "This invitation is for #{recipient}"
    assert email.text_body =~ "You won't need another email verification code"
    assert email.html_body =~ "Research &amp; Development"
    assert email.html_body =~ to_string(owner.email)
    assert email.html_body =~ recipient

    url = invitation |> Ash.Resource.get_metadata(:token) |> Email.invitation_url()
    assert email.text_body =~ url
    assert email.html_body =~ ~s(href="#{url}")
    assert email.html_body =~ ">#{url}</a>"
    assert is_nil(invitation.accepted_at)
  end

  test "untrusted organization and inviter text cannot inject HTML into the invitation" do
    organization_name = ~s|Acme <script>alert("join")</script> & Friends|
    inviter_email = ~s(owner+<team>@example.com)

    email =
      Email.build("invited@example.com", "opaque-token", organization_name, inviter_email)

    assert email.text_body =~ organization_name
    assert email.text_body =~ inviter_email
    refute email.html_body =~ "<script>"
    refute email.html_body =~ "<team>"
    assert email.html_body =~ "&lt;script&gt;alert(&quot;join&quot;)&lt;/script&gt; &amp; Friends"
    assert email.html_body =~ "owner+&lt;team&gt;@example.com"
    assert email.subject == "You're invited to PromptOn"
  end

  test "the action and fallback links use the configured origin and an encoded token" do
    token = ~s(opaque?next=https://untrusted.example/"<>)
    url = Email.invitation_url(token)
    email = Email.build("invited@example.com", token, "Team", "owner@example.com")

    assert url ==
             PromptOnWeb.Endpoint.url() <> "/invitations/" <> URI.encode_www_form(token)

    assert email.html_body =~ ~s(href="#{url}")
    assert email.html_body =~ ">#{url}</a>"
    refute email.html_body =~ ~s(href="https://untrusted.example)
    assert email.text_body =~ "click Join"
    assert email.html_body =~ "click Join"
  end
end
