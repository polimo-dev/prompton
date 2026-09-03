defmodule PromptOnWeb.ErrorText do
  @moduledoc """
  Ash error -> a one-line flash. **Every LiveView uses this one function.**

  There used to be five formatters, one per screen, and the same error looked different on every
  screen - the separator (`"; "` vs `" · "`), the forbidden wording, and the last-resort fallback
  all varied. A flash is one line, so there is one rule:

  - Expand with `Ash.Error.to_error_class/1`, then write each sub-error as `field: message` joined
    with `·`. Field names are not stripped, since the user needs to know which field is wrong.
  - `%{var}` placeholders in validation messages are removed rather than left in place without
    vars.
  - Forbidden is replaced with a single line instead of Ash's internal wording - policy names mean
    nothing to the user.
  - If expanding fails, fall back to `inspect/1`. A screen must not die over a one-line flash.

      iex> PromptOnWeb.ErrorText.message(
      ...>   Ash.Error.Changes.InvalidAttribute.exception(field: :key, message: "has already been taken")
      ...> )
      "key: has already been taken"

      iex> PromptOnWeb.ErrorText.message(:boom)
      "unknown error: :boom"
  """

  @separator " · "

  @doc "An error (anything) -> a one-line flash."
  @spec message(term()) :: String.t()
  def message(error) do
    case Ash.Error.to_error_class(error) do
      %Ash.Error.Forbidden{} -> "You don't have permission to do that."
      %{errors: [_ | _] = errors} -> errors |> Enum.map(&describe/1) |> Enum.uniq() |> join()
      class -> Exception.message(class)
    end
  rescue
    _ -> inspect(error)
  end

  defp join(messages), do: Enum.join(messages, @separator)

  defp describe(%{field: field, message: message})
       when not is_nil(field) and is_binary(message),
       do: "#{field}: #{interpolate(message)}"

  defp describe(%{message: message}) when is_binary(message), do: interpolate(message)
  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(other), do: inspect(other)

  defp interpolate(message), do: String.replace(message, ~r/%\{\w+\}/, "")
end
