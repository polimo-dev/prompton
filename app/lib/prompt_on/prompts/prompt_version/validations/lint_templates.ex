defmodule PromptOn.Prompts.PromptVersion.Validations.LintTemplates do
  @moduledoc """
  When `engine == :liquid`, checks every template fragment (each message.content, text_template)
  with `PromptOnSDK.Template.lint/1`: tags/filters outside the P0 whitelist, whitespace control
  (`{%-`/`-%}`) and parse errors are rejected (plan.md §5.5). Because it is the same code as the
  SDK, "a template the server accepted can be rendered by the SDK". `engine == :raw` is not checked
  (no substitution of the source text).
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :engine) == :raw do
      :ok
    else
      messages = Ash.Changeset.get_attribute(changeset, :messages) || []
      text_template = Ash.Changeset.get_attribute(changeset, :text_template)

      message_problems =
        messages
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {message, index} ->
          message |> content_of() |> problems("message #{index}")
        end)

      text_problems =
        if is_nil(text_template), do: [], else: problems(text_template, "text_template")

      cond do
        message_problems != [] -> invalid(:messages, message_problems)
        text_problems != [] -> invalid(:text_template, text_problems)
        true -> :ok
      end
    end
  end

  defp problems(nil, _label), do: []

  defp problems(source, label) do
    case PromptOnSDK.Template.lint(source) do
      :ok -> []
      {:error, reasons} -> Enum.map(reasons, &"#{label}: #{reason_text(&1)}")
    end
  end

  defp reason_text({:whitespace_control, marker}),
    do: "whitespace control #{marker} is not allowed"

  defp reason_text({:disallowed_tag, name}), do: "tag '#{name}' is not allowed"
  defp reason_text({:disallowed_filter, name}), do: "filter '#{name}' is not allowed"
  defp reason_text({:parse, reason}), do: "parse error: #{reason}"
  defp reason_text(other), do: inspect(other)

  defp invalid(field, problems) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: field,
       message: "template lint failed: " <> Enum.join(problems, "; ")
     )}
  end

  defp content_of(%{content: c}), do: c
  defp content_of(%{"content" => c}), do: c
  defp content_of(_), do: nil
end
