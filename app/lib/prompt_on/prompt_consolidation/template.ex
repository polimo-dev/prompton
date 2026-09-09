defmodule PromptOn.PromptConsolidation.Template do
  @moduledoc "Preserves named template outputs while expressing their differences as variables."

  alias PromptOnSDK.Template

  @tones ~w(harsh practical empathetic gentle formal casual professional friendly)

  def strategy(names) do
    names = Enum.sort(Enum.uniq(names))
    alternatives = names -- ["default"]

    cond do
      alternatives == [] -> simple(names, "variant", nil)
      Enum.all?(alternatives, &(&1 in @tones)) -> simple(names, "tone", nil)
      Enum.all?(alternatives, &language?/1) -> simple(names, "language", nil)
      true -> composite(names) || simple(names, "variant", nil)
    end
  end

  def selections(strategy), do: strategy.selections

  # A selector must not take over an independent input that old templates already interpolate.
  # Keep semantic names where free, and reserve a distinct prompt_* input on a collision.
  def reserve_inputs(strategy, inputs) do
    used = MapSet.new(inputs)

    renames =
      Map.new(strategy.dimensions, fn {name, _default} -> {name, unused_name(name, used)} end)

    %{
      dimensions:
        Enum.map(strategy.dimensions, fn {name, default} -> {renames[name], default} end),
      selections:
        Map.new(strategy.selections, fn {name, selectors} ->
          {name, Map.new(selectors, fn {key, value} -> {renames[key], value} end)}
        end)
    }
  end

  defp unused_name(name, used) do
    if MapSet.member?(used, name), do: unused_name("prompt_" <> name, used), else: name
  end

  def fields(strategy) do
    Enum.map(strategy.dimensions, fn {variable, default} ->
      values =
        strategy.selections
        |> Map.values()
        |> Enum.map(& &1[variable])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      %{
        name: variable,
        type: :string,
        required?: false,
        description:
          "Values: #{Enum.join(values, ", ")}. Omitted or unmatched values use #{default || "the original default"}.",
        example: Enum.find(values, &(&1 != default)) || default
      }
    end)
  end

  def merge!(%{"default" => source} = variants, _strategy) when map_size(variants) == 1 do
    source = content(source)
    validate_messages!(source.messages)
    source
  end

  def merge!(variants, strategy) do
    default =
      Map.get(variants, "default") ||
        raise ArgumentError, "a default prompt is required for consolidation"

    default = content(default)
    validate_messages!(default.messages)

    prepared = Map.new(variants, fn {name, version} -> {name, content(version)} end)
    shape = shape(default.messages)

    unless Enum.all?(prepared, fn {_name, version} -> shape(version.messages) == shape end) do
      raise ArgumentError,
            "prompt variants must have the same message shape (count, roles and names)"
    end

    messages =
      default.messages
      |> Enum.with_index()
      |> Enum.map(fn {message, index} ->
        entries =
          Enum.map(prepared, fn {name, version} ->
            source = Enum.at(version.messages, index).content
            source = liquid_source!(source, version.engine)
            {Map.fetch!(strategy.selections, name), source}
          end)

        fallback = liquid_source!(message.content, default.engine)
        merged = branch(entries, strategy.dimensions, fallback)

        case Template.lint(merged) do
          :ok ->
            %{message | content: merged}

          {:error, reasons} ->
            raise ArgumentError, "invalid consolidated template: #{inspect(reasons)}"
        end
      end)

    %{engine: :liquid, messages: messages, text_template: nil}
  end

  def content(version) do
    engine = if field(version, :engine) in [:raw, "raw"], do: :raw, else: :liquid

    messages =
      Enum.map(field(version, :messages) || [], fn message ->
        %{
          role: to_string(field(message, :role)),
          content: field(message, :content) || "",
          name: field(message, :name)
        }
      end)

    %{engine: engine, messages: messages, text_template: nil}
  end

  defp shape(messages), do: Enum.map(messages, &{&1.role, &1.name})

  defp validate_messages!([]),
    do: raise(ArgumentError, "an empty draft needs content before consolidation")

  defp validate_messages!(_messages), do: :ok
  defp language?(name), do: Regex.match?(~r/^[a-z]{2}(?:-[A-Za-z]{2})?$/, name)

  defp simple(names, variable, default) do
    %{
      dimensions: [{variable, default}],
      selections:
        Map.new(names, fn name ->
          {name, %{variable => if(name == "default", do: default, else: name)}}
        end)
    }
  end

  defp composite(names) do
    pairs =
      Enum.map(
        names -- ["default"],
        &Regex.run(~r/^(.+)_([a-z]{2}(?:-[A-Za-z]{2})?)$/, &1, capture: :all_but_first)
      )

    if Enum.all?(pairs, &is_list/1) do
      modes = pairs |> Enum.map(&hd/1) |> Enum.uniq()
      languages = pairs |> Enum.map(&List.last/1) |> Enum.uniq()

      missing =
        for mode <- modes,
            language <- languages,
            [mode, language] not in pairs,
            do: [mode, language]

      case missing do
        [[mode, language]] ->
          selectors =
            Map.new(Enum.zip(names -- ["default"], pairs), fn {name, [mode, language]} ->
              {name, %{"mode" => mode, "language" => language}}
            end)

          %{
            dimensions: [{"mode", mode}, {"language", language}],
            selections: Map.put(selectors, "default", %{"mode" => mode, "language" => language})
          }

        _ ->
          nil
      end
    end
  end

  defp branch([], _dimensions, fallback), do: fallback
  defp branch([{_selectors, source} | _], [], _fallback), do: source

  defp branch(entries, [{variable, default} | rest], fallback) do
    groups = Enum.group_by(entries, fn {selectors, _source} -> selectors[variable] end)
    default_content = branch(Map.get(groups, default, []), rest, fallback)

    alternatives =
      groups
      |> Map.delete(default)
      |> Enum.sort()
      |> Enum.map(fn {value, entries} ->
        {value, branch(entries, rest, fallback)}
      end)
      |> Enum.reject(fn {_value, source} -> source == default_content end)

    case alternatives do
      [] ->
        default_content

      alternatives ->
        branches =
          alternatives
          |> Enum.with_index()
          |> Enum.map_join(fn {{value, source}, index} ->
            tag = if index == 0, do: "if", else: "elsif"
            "{% #{tag} #{variable} == #{literal!(value)} %}" <> source
          end)

        branches <> "{% else %}" <> default_content <> "{% endif %}"
    end
  end

  defp literal!(value) do
    cond do
      not String.contains?(value, "'") ->
        "'#{value}'"

      not String.contains?(value, "\"") ->
        "\"#{value}\""

      true ->
        raise ArgumentError,
              "prompt names containing both quote styles need an explicit variable mapping"
    end
  end

  defp liquid_source!(source, :liquid), do: source

  defp liquid_source!(source, :raw) do
    case PromptOn.HeyDiaryImport.Spec.escape_literal(source) do
      {:ok, escaped} -> escaped
      {:error, reason} -> raise ArgumentError, "cannot preserve raw template: #{inspect(reason)}"
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
