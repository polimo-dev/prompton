defmodule PromptOn.Accounts.InvitationConcurrencyTest do
  @moduledoc """
  Exercises invitation row locks and organization seat limits with real database commits.

  Separate unboxed connections reproduce the commit boundaries hidden by sandbox transactions.
  Every fixture address and team slug has a unique prefix, and cleanup removes those organizations
  before their users so project creator foreign keys cannot leave committed fixture data behind.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PromptOn.Accounts
  alias PromptOn.Accounts.Invitation
  alias PromptOn.Entitlements
  alias PromptOn.Fixtures
  alias PromptOn.Repo

  setup do
    prefix = "invite-race-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"
    on_exit(fn -> cleanup(prefix) end)

    unboxed(fn ->
      owner = user(prefix, "owner")
      invited = user(prefix, "invited")
      organization = Fixtures.team_org_fixture(%{user: owner, slug: prefix})
      organization = Fixtures.set_plan(organization, :team)
      project = Fixtures.project_fixture(%{user: owner, organization: organization})

      %{
        prefix: prefix,
        owner: owner,
        invited: invited,
        organization: organization,
        project: project
      }
    end)
  end

  test "simultaneous Join requests consume one invitation and create one membership", context do
    invitation = unboxed(fn -> invite(context, context.invited) end)
    token = Ash.Resource.get_metadata(invitation, :token)

    results =
      concurrently([
        fn -> accept(context.invited, token) end,
        fn -> accept(context.invited, token) end
      ])

    assert_one_winner(results)

    unboxed(fn ->
      stored = Ash.get!(Invitation, invitation.id, actor: Fixtures.system_actor())
      assert stored.accepted_at
      assert stored.accepted_by_id == context.invited.id
      assert is_nil(stored.revoked_at)
      assert membership_count(context.organization.id, context.invited.id) == 1
      assert project_grant_count(context.project.id, context.invited.id) == 1
    end)
  end

  test "simultaneous Join and revoke leave only the winning terminal state", context do
    invitation = unboxed(fn -> invite(context, context.invited) end)
    token = Ash.Resource.get_metadata(invitation, :token)

    results =
      concurrently([
        fn -> accept(context.invited, token) end,
        fn -> revoke(context.owner, invitation) end
      ])

    assert_one_winner(results)

    unboxed(fn ->
      stored = Ash.get!(Invitation, invitation.id, actor: Fixtures.system_actor())
      accepted? = not is_nil(stored.accepted_at)
      revoked? = not is_nil(stored.revoked_at)
      assert accepted? != revoked?

      expected_count = if accepted?, do: 1, else: 0
      assert membership_count(context.organization.id, context.invited.id) == expected_count
      assert project_grant_count(context.project.id, context.invited.id) == expected_count

      if accepted? do
        assert stored.accepted_by_id == context.invited.id
        assert [{:ok, %Invitation{}}, {:error, _}] = results
      else
        assert is_nil(stored.accepted_by_id)
        assert [{:error, _}, {:ok, %Invitation{}}] = results
      end
    end)
  end

  test "two different invitations cannot consume the organization's last seat", context do
    {limit, other, first_invitation, second_invitation} =
      unboxed(fn ->
        limit =
          context.organization
          |> Entitlements.plan()
          |> Entitlements.limit(:members_per_organization)

        # The owner already occupies one seat. Leave exactly one seat for the two Join requests.
        for index <- 1..(limit - 2) do
          member = user(context.prefix, "member-#{index}")

          {:ok, _membership} =
            Accounts.add_member(
              %{
                organization_id: context.organization.id,
                user_id: member.id,
                role: :member
              },
              actor: Fixtures.system_actor()
            )
        end

        other = user(context.prefix, "other-invited")
        {limit, other, invite(context, context.invited), invite(context, other)}
      end)

    first_token = Ash.Resource.get_metadata(first_invitation, :token)
    second_token = Ash.Resource.get_metadata(second_invitation, :token)

    results =
      concurrently([
        fn -> accept(context.invited, first_token) end,
        fn -> accept(other, second_token) end
      ])

    assert_one_winner(results)

    unboxed(fn ->
      organization_id = Ecto.UUID.dump!(context.organization.id)

      assert Repo.one(
               from(m in "memberships",
                 where: m.organization_id == ^organization_id,
                 select: count()
               )
             ) == limit

      for {invitation, invited} <- [
            {first_invitation, context.invited},
            {second_invitation, other}
          ] do
        stored = Ash.get!(Invitation, invitation.id, actor: Fixtures.system_actor())
        expected_count = if stored.accepted_at, do: 1, else: 0

        assert is_nil(stored.revoked_at)
        assert membership_count(context.organization.id, invited.id) == expected_count
        assert project_grant_count(context.project.id, invited.id) == expected_count

        if is_nil(stored.accepted_at), do: assert(Invitation.pending?(stored))
      end
    end)
  end

  defp invite(context, invited) do
    {:ok, invitation} =
      Invitation
      |> Ash.Changeset.for_create(
        :invite,
        %{
          organization_id: context.organization.id,
          email: invited.email,
          role: :member,
          project_ids: [context.project.id]
        },
        actor: context.owner
      )
      |> Ash.create()

    invitation
  end

  defp accept(actor, token) do
    Invitation
    |> Ash.ActionInput.for_action(:accept, %{token: token}, actor: actor)
    |> Ash.run_action()
  end

  defp revoke(actor, invitation) do
    invitation
    |> Ash.Changeset.for_update(:revoke, %{}, actor: actor)
    |> Ash.update()
  end

  defp assert_one_winner(results) do
    assert [{:error, %Ash.Error.Invalid{}}, {:ok, %Invitation{}}] =
             Enum.sort_by(results, &elem(&1, 0))
  end

  defp concurrently(funs) do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    gate = make_ref()

    tasks =
      Enum.map(funs, fn fun ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          unboxed(fn ->
            send(parent, {:ready, gate, self()})

            receive do
              {:run, ^gate} -> fun.()
            after
              10_000 -> raise "invitation concurrency test did not release its start gate"
            end
          end)
        end)
      end)

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^gate, ^pid}, 10_000
    end

    Enum.each(tasks, &send(&1.pid, {:run, gate}))
    Task.await_many(tasks, 30_000)
  end

  defp membership_count(organization_id, user_id) do
    organization_id = Ecto.UUID.dump!(organization_id)
    user_id = Ecto.UUID.dump!(user_id)

    Repo.one(
      from(m in "memberships",
        where: m.organization_id == ^organization_id and m.user_id == ^user_id,
        select: count()
      )
    )
  end

  defp project_grant_count(project_id, user_id) do
    project_id = Ecto.UUID.dump!(project_id)
    user_id = Ecto.UUID.dump!(user_id)

    Repo.one(
      from(m in "project_memberships",
        where: m.project_id == ^project_id and m.user_id == ^user_id,
        select: count()
      )
    )
  end

  defp user(prefix, suffix),
    do: Fixtures.user_fixture(%{email: "#{prefix}-#{suffix}@example.com"})

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp cleanup(prefix) do
    unboxed(fn ->
      {:ok, _deleted_users} =
        Repo.transaction(fn ->
          email_pattern = "#{prefix}-%@example.com"
          users = from(u in "users", where: like(u.email, ^email_pattern), select: u.id)

          personal_organizations =
            from(m in "memberships",
              where: m.user_id in subquery(users),
              select: m.organization_id
            )

          Repo.delete_all(
            from(o in "organizations",
              where:
                o.slug == ^prefix or
                  (field(o, :personal?) == true and o.id in subquery(personal_organizations))
            )
          )

          Repo.delete_all(from(u in "users", where: like(u.email, ^email_pattern)))
        end)
    end)
  end
end
