defmodule Mix.Tasks.Prompton.SeedAdmin do
  @shortdoc "Create an account ahead of time by email (idempotent) — sign in with the email code at /sign-in"

  @moduledoc """
      mix prompton.seed_admin --email you@example.com

  Creates a user from a single email (`PromptOn.Accounts.User.:register`, system actor). Does
  nothing when the user already exists (idempotent). There is no password — sign in at `/sign-in`
  by entering the 6-digit code received by email (ADR 0008).

  Strictly speaking this task is not needed: sign-up = sign-in, so an email arriving at `/sign-in`
  for the first time gets an account the moment its code is verified. It is kept for preparing an
  account without email (a dev DB, `heydiary_import --user`).

  When a user is newly created, a personal Organization + Membership (owner) are created along with
  it (plan.md §4.7).
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [email: :string])

    email = opts[:email] || Mix.raise("--email is required")

    Mix.Task.run("app.start")

    actor = PromptOn.SystemActor.new()

    case PromptOn.Accounts.get_user_by_email(email, actor: actor) do
      {:ok, nil} ->
        {:ok, user} = PromptOn.Accounts.register_user(%{email: email}, actor: actor)
        Mix.shell().info("created user #{user.email} (#{user.id})")

      {:ok, user} ->
        Mix.shell().info("user #{user.email} already exists")
    end

    Mix.shell().info(
      "Sign in at /sign-in with #{email} using the 6-digit code we email " <>
        "(in dev without PTN_RESEND_API_KEY the code is in /dev/mailbox)."
    )
  end
end
