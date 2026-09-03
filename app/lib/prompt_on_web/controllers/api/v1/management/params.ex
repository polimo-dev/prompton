defmodule PromptOnWeb.API.V1.Management.Params do
  @moduledoc """
  Reading management API request bodies - **shape only**.

  The meaning of values (allowed atoms, formats, referential integrity) is already enforced by the
  constraints/validations of the Ash actions, and `PromptOnWeb.API.V1.FallbackController` turns
  those errors into per-field 400s. Only three things happen here:

  1. **Distinguish a missing key from `null`** - PATCH has to tell "not sent" apart from "please
     clear it".
  2. Stop with a 400 before handing off to the action when a JSON type is wrong (`"name": 3`).
  3. Restore domain fields whose names carry a `?`, like `required?`, from their JSON name
     (`required`).

  **Unknown keys are ignored.** The clients of this API are coding AIs, which often send fields
  ahead of time that will only exist later; failing the whole request on an unknown key would break
  the client every time the server gets one step ahead.
  """

  @type spec :: [{String.t(), atom(), atom()}]

  @doc """
  Builds the action input map from only the keys listed in the spec. **A key absent from the
  request is absent from the result too** - which is why the same function serves both create
  (full) and PATCH (partial update).

      collect(params, [{"name", :name, :string}, {"input_schema", :input_schema, :input_schema}])
  """
  @spec collect(map(), spec()) :: {:ok, map()} | {:error, term()}
  def collect(params, spec) do
    Enum.reduce_while(spec, {:ok, %{}}, fn {json_key, attr, type}, {:ok, acc} ->
      case Map.fetch(params, json_key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case cast(type, json_key, value) do
            {:ok, cast} -> {:cont, {:ok, Map.put(acc, attr, cast)}}
            {:error, error} -> {:halt, {:error, error}}
          end
      end
    end)
  end

  @doc "Required string (a value the request must carry, like `{key, name}`)."
  @spec required_string(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, invalid("#{key} is required")}
    end
  end

  @doc "Optional string. `{:ok, nil}` when absent."
  @spec optional_string(map(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def optional_string(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, invalid("#{key} must be a string")}
    end
  end

  @doc "Optional object. `{:ok, nil}` when absent."
  @spec optional_map(map(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def optional_map(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _other -> {:error, invalid("#{key} must be an object")}
    end
  end

  @doc "Optional integer. `{:ok, nil}` when absent."
  @spec optional_integer(map(), String.t()) :: {:ok, integer() | nil} | {:error, term()}
  def optional_integer(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_integer(value) -> {:ok, value}
      _other -> {:error, invalid("#{key} must be an integer")}
    end
  end

  # ---------------------------------------------------------------------------
  # cast

  defp cast(:string, _key, nil), do: {:ok, nil}
  defp cast(:string, _key, value) when is_binary(value), do: {:ok, value}
  defp cast(:string, key, _value), do: {:error, invalid("#{key} must be a string")}

  defp cast(:map, _key, value) when is_map(value), do: {:ok, value}
  defp cast(:map, key, _value), do: {:error, invalid("#{key} must be an object")}

  defp cast(:integer, _key, nil), do: {:ok, nil}
  defp cast(:integer, _key, value) when is_integer(value), do: {:ok, value}
  defp cast(:integer, key, _value), do: {:error, invalid("#{key} must be an integer")}

  defp cast(:strings, key, value) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: {:ok, value},
      else: {:error, invalid("#{key} must be an array of strings")}
  end

  defp cast(:strings, key, _value), do: {:error, invalid("#{key} must be an array of strings")}

  # Message array - `{"role": "system", "content": "…", "name": null}`.
  defp cast(:messages, key, value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case message do
        %{"role" => role, "content" => content} when is_binary(role) and is_binary(content) ->
          {:cont, {:ok, [message_map(message, role, content) | acc]}}

        _other ->
          {:halt, {:error, invalid("#{key} entries need a string role and content")}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, error} -> {:error, error}
    end
  end

  defp cast(:messages, key, _value), do: {:error, invalid("#{key} must be an array")}

  # Input schema - JSON says `required`, the domain attribute is `required?`.
  defp cast(:input_schema, key, value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn variable, {:ok, acc} ->
      case variable do
        %{"name" => name} when is_binary(name) ->
          {:cont, {:ok, [variable_map(variable) | acc]}}

        _other ->
          {:halt, {:error, invalid("#{key} entries need a string name")}}
      end
    end)
    |> case do
      {:ok, variables} -> {:ok, Enum.reverse(variables)}
      {:error, error} -> {:error, error}
    end
  end

  defp cast(:input_schema, key, _value), do: {:error, invalid("#{key} must be an array")}

  defp message_map(message, role, content) do
    %{role: role, content: content, name: Map.get(message, "name")}
  end

  defp variable_map(variable) do
    %{
      name: variable["name"],
      type: variable["type"] || "string",
      # `required` is the JSON name and `required?` the domain attribute. Both are accepted.
      required?: variable["required"] || variable["required?"] || false,
      description: variable["description"],
      example: variable["example"]
    }
  end

  defp invalid(message), do: {:invalid_request, message}
end
