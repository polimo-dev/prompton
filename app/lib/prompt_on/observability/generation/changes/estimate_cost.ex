defmodule PromptOn.Observability.Generation.Changes.EstimateCost do
  @moduledoc """
  Cost correction (plan.md §9.5). Priority:

  1. If `cost_usd` is already present, keep it (`cost_source` becomes `:provider` when empty).
  2. Otherwise, if tokens are present, catalog `Model.pricing` × tokens
     (`PromptOn.Catalog.Model.estimate_cost/3`) → `:catalog`. The model is looked up by `model_id`
     (soft ref) → `(provider, model string)` → `model string only`, in that order.
  3. Failing that, `cost_usd nil` and `cost_source :unknown`.

  On the bulk_create path `batch_change/3` reads the tenant catalog **once per batch** and applies
  it. The single-record path (`change/3`) reads it directly.
  """

  use Ash.Resource.Change

  alias PromptOn.Catalog.Model

  @impl true
  def change(changeset, _opts, _context) do
    models = if needs_estimate?(changeset), do: load_models(changeset.tenant), else: []
    estimate_or_settle(changeset, models)
  end

  # bulk_create calls batch_change once per batch -- read the catalog exactly once here.
  # (`before_batch/3` cannot be used for preloading because Ash calls it after batch_change.)
  @impl true
  def batch_change(changesets, _opts, _context) do
    models =
      if Enum.any?(changesets, &needs_estimate?/1),
        do: changesets |> List.first() |> Map.get(:tenant) |> load_models(),
        else: []

    Enum.map(changesets, &estimate_or_settle(&1, models))
  end

  defp estimate_or_settle(changeset, models) do
    if needs_estimate?(changeset),
      do: apply_estimate(changeset, models),
      else: settle_source(changeset)
  end

  defp needs_estimate?(changeset) do
    is_nil(Ash.Changeset.get_attribute(changeset, :cost_usd)) and
      (is_integer(Ash.Changeset.get_attribute(changeset, :input_tokens)) or
         is_integer(Ash.Changeset.get_attribute(changeset, :output_tokens)))
  end

  # cost_usd present but the source empty -> provider; nothing at all -> unknown.
  defp settle_source(changeset) do
    cost = Ash.Changeset.get_attribute(changeset, :cost_usd)
    source = Ash.Changeset.get_attribute(changeset, :cost_source)

    case {cost, source} do
      {nil, _} -> Ash.Changeset.force_change_attribute(changeset, :cost_source, :unknown)
      {_cost, nil} -> Ash.Changeset.force_change_attribute(changeset, :cost_source, :provider)
      _ -> changeset
    end
  end

  defp apply_estimate(changeset, models) do
    model = find_model(changeset, models)

    estimate =
      model &&
        Model.estimate_cost(
          model,
          Ash.Changeset.get_attribute(changeset, :input_tokens),
          Ash.Changeset.get_attribute(changeset, :output_tokens)
        )

    case estimate do
      %Decimal{} = cost ->
        changeset
        |> Ash.Changeset.force_change_attribute(:cost_usd, cost)
        |> Ash.Changeset.force_change_attribute(:cost_source, :catalog)
        |> put_model_id_if_missing(model.id)

      _ ->
        Ash.Changeset.force_change_attribute(changeset, :cost_source, :unknown)
    end
  end

  defp put_model_id_if_missing(changeset, model_id) do
    case Ash.Changeset.get_attribute(changeset, :model_id) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :model_id, model_id)
      _ -> changeset
    end
  end

  defp find_model(changeset, models) do
    model_id = Ash.Changeset.get_attribute(changeset, :model_id)
    provider = Ash.Changeset.get_attribute(changeset, :provider)
    model_string = Ash.Changeset.get_attribute(changeset, :model)

    Enum.find(models, &(&1.id == model_id)) ||
      Enum.find(models, &(&1.provider == provider and &1.model_id == model_string)) ||
      Enum.find(models, &(&1.model_id == model_string))
  end

  defp load_models(nil), do: []

  defp load_models(tenant) do
    case Ash.read(Model, tenant: tenant, actor: PromptOn.SystemActor.new()) do
      {:ok, models} -> models
      {:error, _} -> []
    end
  end
end
