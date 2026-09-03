defmodule PromptOn.CanonicalJSON do
  @moduledoc """
  Deterministic JSON serialization: **keys are sorted recursively** (byte order) and encoded
  without whitespace (plan.md §6.2 snapshot ETag). The same map yields the same bytes, hence the
  same sha256.

  - Map keys become strings (atom -> string); atom values become strings (except `true/false/nil`).
  - Structs: `DateTime`/`Date`/`Time`/`NaiveDateTime` as ISO 8601, `Decimal` as a string; any other
    struct is unwrapped into a map and the same rules apply (embedded resources etc.; `__meta*__`
    keys are dropped).
  """

  @meta_keys [:__metadata__, :__meta__, :__lateral_join_source__, :__order__, :__struct__]

  @doc "Canonical JSON bytes."
  @spec encode!(term()) :: binary()
  def encode!(term), do: term |> canonicalize() |> Jason.encode!()

  @doc "`\"sha256-<hex>\"`: the sha256 of the canonical bytes."
  @spec etag(binary()) :: String.t()
  def etag(body) when is_binary(body) do
    "sha256-" <> (:crypto.hash(:sha256, body) |> Base.encode16(case: :lower))
  end

  @doc "Key-sorted `Jason.OrderedObject` tree (the pre-encoding form)."
  @spec canonicalize(term()) :: term()
  def canonicalize(%Jason.OrderedObject{values: values}), do: canonicalize(Map.new(values))

  def canonicalize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def canonicalize(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  def canonicalize(%Date{} = d), do: Date.to_iso8601(d)
  def canonicalize(%Time{} = t), do: Time.to_iso8601(t)
  def canonicalize(%Decimal{} = d), do: Decimal.to_string(d, :normal)

  def canonicalize(%_{} = struct) do
    struct |> Map.from_struct() |> Map.drop(@meta_keys) |> canonicalize()
  end

  def canonicalize(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {key_to_string(k), canonicalize(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  def canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)

  def canonicalize(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  def canonicalize(other), do: other

  defp key_to_string(k) when is_binary(k), do: k
  defp key_to_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_to_string(k), do: to_string(k)
end
