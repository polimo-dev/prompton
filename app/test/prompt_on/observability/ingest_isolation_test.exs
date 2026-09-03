defmodule PromptOn.Observability.IngestIsolationTest do
  @moduledoc """
  Ingest's "no poison batches" (contract decision #7): even when the batch statement fails with a
  DB error, only that record is isolated and the rest go in as 202. The DB error is produced with a
  CHECK constraint inside the transaction (the DDL rolls back together with the sandbox
  transaction), and the MERGE unique violation of a concurrent same-id batch is produced by a real
  connection outside the sandbox (`Sandbox.unboxed_run`) that holds the same id in a transaction
  and then commits.

  The DDL takes an ACCESS EXCLUSIVE lock on `generations`, hence `async: false`.
  """

  use PromptOn.DataCase, async: false

  import PromptOn.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias PromptOn.Observability
  alias PromptOn.Observability.Ingest

  # Users/organizations created outside the sandbox (real commits) get this email prefix and are
  # deleted here once every test in the module has finished and the sandbox transaction has been
  # rolled back (an on_exit inside a test runs before the sandbox owner and is blocked by
  # uncommitted rows).
  @unboxed_email_prefix "ingest-isolation-"

  setup_all do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          """
          DELETE FROM organizations WHERE id IN (
            SELECT m.organization_id FROM memberships m JOIN users u ON u.id = m.user_id
            WHERE u.email::text LIKE $1
          )
          """,
          ["#{@unboxed_email_prefix}%"]
        )

        Repo.query!("DELETE FROM users WHERE email::text LIKE $1", ["#{@unboxed_email_prefix}%"])
      end)
    end)

    :ok
  end

  setup do
    project = project_fixture()
    use_case = use_case_fixture(project, %{key: "diary_generation"})
    {api_key, _raw} = api_key_fixture(project, scopes: [:logs])
    %{project: project, use_case: use_case, api_key: api_key}
  end

  test "a record the database rejects is isolated; the rest of the batch is stored", %{
    project: project,
    use_case: use_case
  } do
    # a DB rule the pre-validation does not know -- the whole batch MERGE fails and the per-record
    # retry has to find the culprit
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE generations ADD CONSTRAINT poison_model CHECK (model <> 'poison')"
    )

    good1 = generation_payload_fixture(use_case)
    poison = generation_payload_fixture(use_case, %{"model" => "poison"})
    good2 = generation_payload_fixture(use_case)

    assert %{accepted: 2, duplicates: 0, rejected: [rejected]} =
             ingest_fixture(project, [good1, poison, good2])

    assert rejected.index == 1
    assert rejected.id == poison["id"]
    assert rejected.code == "invalid_request"
    # DB error text does not leak
    assert rejected.message == "record could not be stored"

    {:ok, %{results: gens}} = Observability.list_generations(scope(project))
    assert gens |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([good1["id"], good2["id"]])

    for p <- [good1, good2] do
      assert Observability.get_generation!(p["id"], scope(project)).payload_state == :stored
      assert %{} = Observability.get_payload!(p["id"], scope(project))
    end

    # the transaction is still alive -- the next batch works too
    assert %{accepted: 1} = ingest_fixture(project, [generation_payload_fixture(use_case)])
  end

  test "a payload the database rejects is dropped alone; its generation and the others stay", %{
    project: project,
    use_case: use_case
  } do
    poison_output = %{"content" => "POISON-OUTPUT"}

    poison_hash =
      :crypto.hash(:sha256, Jason.encode!(poison_output)) |> Base.encode16(case: :lower)

    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE generation_payloads ADD CONSTRAINT poison_output CHECK (output_sha256 <> '#{poison_hash}')"
    )

    good = generation_payload_fixture(use_case)
    poison = generation_payload_fixture(use_case, %{"output" => poison_output})

    assert %{accepted: 2, duplicates: 0, rejected: []} = ingest_fixture(project, [good, poison])

    assert %{} = Observability.get_payload!(good["id"], scope(project))
    assert {:ok, nil} = Observability.get_payload(poison["id"], scope(project))
    assert %{} = Observability.get_generation!(poison["id"], scope(project))
  end

  test "concurrent same-id batch (MERGE unique violation) is classified as duplicate/conflict, rest accepted",
       %{project: project, use_case: use_case, api_key: api_key} do
    parent = self()
    id_a = Ash.UUIDv7.generate()
    id_b = Ash.UUIDv7.generate()

    :telemetry.attach(
      "ingest-retry-#{inspect(self())}",
      [:prompton, :ingest, :retry],
      fn _event, measurements, metadata, pid -> send(pid, {:retry, measurements, metadata}) end,
      parent
    )

    on_exit(fn -> :telemetry.detach("ingest-retry-#{inspect(parent)}") end)

    # A real connection outside the sandbox: create and commit a project (it must be visible from
    # another connection for the FK to resolve), then hold the same id inside a transaction and
    # commit while we wait in the MERGE → unique violation.
    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          user =
            user_fixture(%{
              email: "#{@unboxed_email_prefix}#{System.unique_integer([:positive])}@example.com"
            })

          other = project_fixture(%{user: user})
          {other_key, _} = api_key_fixture(other, scopes: [:logs])
          send(parent, {:ready, %{project: other, api_key: other_key}})

          for id <- [id_a, id_b] do
            receive do
              {:hold, ^id} -> :ok
            end

            Repo.transaction(fn ->
              {:ok, _, _notifications} =
                Observability.ingest_generation(
                  %{
                    id: id,
                    use_case_key: "k",
                    model: "m",
                    status: :ok,
                    started_at: DateTime.utc_now()
                  },
                  scope(other) ++ [return_notifications?: true]
                )

              send(parent, {:held, id})
              Process.sleep(1_000)
            end)
          end
        end)
      end)

    assert_receive {:ready, %{project: other, api_key: other_key}}, 10_000

    # 1) same project: unique violation → duplicate
    send(task.pid, {:hold, id_a})
    assert_receive {:held, ^id_a}, 5_000
    fresh = generation_payload_fixture("k")
    clash = generation_payload_fixture("k", %{"id" => id_a})

    assert {:ok, %{accepted: 1, duplicates: 1, rejected: []}} =
             Ingest.ingest([fresh, clash], actor: other_key, tenant: other.id)

    assert_received {:retry, %{count: 1}, %{reason: :unique_violation}}
    assert %{} = Observability.get_generation!(fresh["id"], scope(other))

    # 2) another project commits the same id first: unique violation → conflict
    send(task.pid, {:hold, id_b})
    assert_receive {:held, ^id_b}, 5_000
    mine = generation_payload_fixture(use_case)
    clash = generation_payload_fixture(use_case, %{"id" => id_b})

    assert {:ok, %{accepted: 1, duplicates: 0, rejected: [rejected]}} =
             Ingest.ingest([mine, clash], actor: api_key, tenant: project.id)

    assert rejected.code == "conflict" and rejected.id == id_b
    assert_received {:retry, %{count: 1}, %{reason: :unique_violation}}
    assert %{} = Observability.get_generation!(mine["id"], scope(project))

    Task.await(task, 10_000)
  end
end
