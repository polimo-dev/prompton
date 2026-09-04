defmodule PromptOn.Evals.EvaluationResult.Changes.MarkFailed do
  @moduledoc """
  `EvaluationResult.:mark_failed` — the trigger's `on_error` after the last attempt, and the stall
  sweeper (ADR 0010 §3.1, §3.1b).

  The row is the record of what happened, so the failure is written here rather than left to Oban's
  `discarded` state (`on_error_fails_job? false` keeps the job itself from being marked failed once
  we have recorded it).

  The error is reduced to a **shape**, never a body: a provider error body can quote the request
  that produced it, and that request contains the user's payload.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    message =
      changeset
      |> Ash.Changeset.get_argument(:error)
      |> describe()

    Ash.Changeset.force_change_attributes(changeset, %{
      status: :failed,
      error_message: String.slice(message, 0, 500),
      scored_at: DateTime.utc_now()
    })
  end

  defp describe(nil), do: "the judge job failed"
  defp describe(:evaluation_timed_out), do: "evaluation timed out"
  defp describe(:timeout), do: "timeout"
  defp describe({:request_failed, _reason}), do: "request failed"
  defp describe({:http_error, status, _body}), do: "HTTP #{status}"
  defp describe({:http_error, status, _body, _headers}), do: "HTTP #{status}"
  defp describe({:invalid_response, _body}), do: "invalid provider response"
  defp describe({:unparsable, _raw}), do: "the judge did not answer with JSON"
  defp describe(reason) when is_atom(reason), do: to_string(reason)

  # An Ash error **class** wraps the real reason: its own `Exception.message/1` starts with a blank
  # line and then the class header ("Invalid Error"), which says nothing. Unwrap to the first
  # sub-error, which is the one the judge produced.
  defp describe(%{__exception__: true, errors: [first | _rest]}), do: describe(first)

  # `Exception.message/1` can start with a blank line, and `List.first/1` would hand back `""` —
  # truthy, so a `||` fallback never fires and Ash casts the empty string to nil, recording no
  # reason at all. Take the first line that has something on it.
  defp describe(%{__exception__: true} = error) do
    error
    |> Exception.message()
    |> String.split("\n")
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      nil -> "the judge job failed"
      line -> String.trim(line)
    end
  end

  # A binary reason is deliberately NOT passed through: the only strings that reach here come from
  # a provider, and a provider error body can quote the request.
  defp describe(_reason), do: "the judge job failed"
end
