defmodule PromptOn.Evals.EvaluationRun.Validations.NoActiveRun do
  @moduledoc """
  `EvaluationRun.:start`: one deployment revision may have only one evaluation in flight
  (ADR 0010 §2.6).

  Two concurrent runs over the same revision would spend the organization's provider budget twice
  for two numbers nobody can tell apart, and the second one's badge would silently replace the
  first's. Finished runs are not in the way — a revision may be measured again with a new rubric.

  This validation is the **friendly** half: it runs while the changeset is built, so it names the
  revision that is already running before anything is written. It is not the guard — it holds no
  lock and runs outside the transaction, so two tabs can both read nil. The guard is the partial
  unique index behind `EvaluationRun`'s `:one_active_run_per_deployment` identity, which makes the
  losing insert fail in Postgres with the same sentence. Keep both: without the identity the race
  is real, without this the message names no revision.
  """

  use Ash.Resource.Validation

  require Ash.Query

  alias PromptOn.Evals.EvaluationRun

  @impl true
  def validate(changeset, _opts, _context) do
    deployment_id = Ash.Changeset.get_attribute(changeset, :deployment_id)
    opts = [tenant: changeset.to_tenant || changeset.tenant, actor: PromptOn.SystemActor.new()]

    EvaluationRun
    |> Ash.Query.filter(deployment_id == ^deployment_id and status in [:queued, :running])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} ->
        :ok

      {:ok, %EvaluationRun{deployment_revision: revision}} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :deployment_id,
           message: "an evaluation of revision ##{revision} is already running"
         )}

      {:error, error} ->
        {:error, error}
    end
  end
end
