defmodule PromptOn.Catalog.Model.Validations.Pricing do
  @moduledoc """
  Shape validation for the `pricing` map. It is a free-form map, but the keys that
  `estimate_cost/3` reads have a fixed shape: the rate keys (`input_per_m`/`output_per_m`/
  `cached_input_per_m`) are numbers >= 0, `unit` is `"token"` | `"audio_second"`, and `currency` is
  a string. Missing keys are allowed (partial pricing).
  """

  use Ash.Resource.Validation

  @rate_keys ~w(input_per_m output_per_m cached_input_per_m)

  @impl true
  def validate(changeset, _opts, _context) do
    pricing =
      changeset
      |> Ash.Changeset.get_attribute(:pricing)
      |> PromptOnSDK.Params.stringify_keys()

    with :ok <- check_rates(pricing),
         :ok <- check_unit(pricing["unit"]),
         :ok <- check_currency(pricing["currency"]) do
      :ok
    else
      {:error, message} ->
        {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :pricing, message: message)}
    end
  end

  defp check_rates(pricing) do
    Enum.find_value(@rate_keys, :ok, &check_rate(&1, Map.get(pricing, &1)))
  end

  defp check_rate(_key, nil), do: nil
  defp check_rate(_key, n) when is_number(n) and n >= 0, do: nil

  defp check_rate(key, %Decimal{} = d),
    do: if(Decimal.negative?(d), do: {:error, "#{key} must be >= 0"})

  defp check_rate(key, _), do: {:error, "#{key} must be a non-negative number"}

  defp check_unit(nil), do: :ok
  defp check_unit(unit) when is_atom(unit), do: check_unit(Atom.to_string(unit))

  defp check_unit(unit) when is_binary(unit) do
    units = PromptOn.Catalog.Model.pricing_units()

    if unit in units,
      do: :ok,
      else: {:error, "unit must be one of #{Enum.join(units, ", ")}"}
  end

  defp check_unit(_), do: {:error, "unit must be a string"}

  defp check_currency(nil), do: :ok
  defp check_currency(c) when is_binary(c), do: :ok
  defp check_currency(_), do: {:error, "currency must be a string"}
end
