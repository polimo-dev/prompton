defmodule PromptOnWeb.API.V1.FallbackController do
  @moduledoc """
  Turns the `{:error, _}` a controller returned into the §6.1 error envelope.

  Internal exception text (`inspect`, DB messages, stacks) never goes into the response (contract
  decision #8): `Ash.Error.Invalid` is reduced to its field validation messages, sent down as
  `message`/`details.errors`, and any other unknown error becomes a generic 500 `internal_error`
  message plus a server log line.
  """

  use PromptOnWeb, :controller

  require Logger

  alias PromptOnWeb.API.V1.ErrorJSON

  def call(conn, {:error, %Ash.Error.Forbidden{}}),
    do: send_error(conn, 403, "forbidden", "forbidden")

  def call(conn, {:error, %Ash.Error.Query.NotFound{}}),
    do: send_error(conn, 404, "not_found", "not found")

  def call(conn, {:error, %Ash.Error.Invalid{} = err}) do
    case field_errors(err) do
      [] ->
        send_error(conn, 400, "invalid_request", "invalid request")

      errors ->
        message = Enum.map_join(errors, "; ", &"#{&1.field}: #{&1.message}")
        send_error(conn, 400, "invalid_request", message, %{errors: errors})
    end
  end

  def call(conn, {:error, %Ash.Error.Unknown{} = err}) do
    Logger.error("prompton api: unknown error: #{Exception.message(err)}")
    send_error(conn, 500, "internal_error", "internal error")
  end

  def call(conn, {:error, :not_found}), do: send_error(conn, 404, "not_found", "not found")

  def call(conn, {:error, {:not_found, message, details}}),
    do: send_error(conn, 404, "not_found", to_string(message), details)

  def call(conn, {:error, :forbidden}), do: send_error(conn, 403, "forbidden", "forbidden")

  def call(conn, {:error, {:invalid_request, message}}),
    do: send_error(conn, 400, "invalid_request", to_string(message))

  def call(conn, {:error, {:invalid_request, message, details}}),
    do: send_error(conn, 400, "invalid_request", to_string(message), details)

  def call(conn, {:error, {:conflict, message}}),
    do: send_error(conn, 409, "conflict", to_string(message))

  # 409 is **where idempotency lives** in the management API - trying to re-create a project, use
  # case, prompt, or model that already exists returns that resource in `details`. A coding AI that
  # re-ran a provisioning script must be able to move on to the next step without one more lookup
  # (docs/management-api.md).
  def call(conn, {:error, {:conflict, message, details}}),
    do: send_error(conn, 409, "conflict", to_string(message), details)

  # The four polling states of device authorization (RFC 8628) - all 400, distinguished by `code`
  # (`authorization_pending`, `slow_down`, `expired_token`, `access_denied`).
  # The names are fixed by the standard, so they are used as-is rather than aligned with the rest of
  # this API's `code` vocabulary.
  def call(conn, {:error, {:device, code, message}}) when is_atom(code),
    do: send_error(conn, 400, to_string(code), to_string(message))

  def call(conn, {:error, other}) do
    Logger.error("prompton api: unhandled error: #{inspect(other, limit: 20)}")
    send_error(conn, 400, "invalid_request", "invalid request")
  end

  @doc "Picks the client-safe field errors out of an Ash invalid error class: `[%{field, message}]`"
  @spec field_errors(Ash.Error.Invalid.t()) :: [%{field: String.t() | nil, message: String.t()}]
  def field_errors(%Ash.Error.Invalid{errors: errors}), do: Enum.flat_map(errors, &field_error/1)

  defp field_error(%struct{field: field, message: message} = error)
       when struct in [
              Ash.Error.Changes.InvalidAttribute,
              Ash.Error.Changes.InvalidArgument,
              Ash.Error.Query.InvalidArgument
            ] and is_binary(message),
       do: [%{field: field && to_string(field), message: interpolate(message, error)}]

  defp field_error(%Ash.Error.Changes.Required{field: field}),
    do: [%{field: to_string(field), message: "is required"}]

  defp field_error(%Ash.Error.Changes.InvalidChanges{fields: fields, message: message} = error)
       when is_binary(message),
       do: [
         %{
           field: fields |> List.wrap() |> Enum.map_join(",", &to_string/1),
           message: interpolate(message, error)
         }
       ]

  defp field_error(%Ash.Error.Invalid.NoSuchInput{input: input}),
    do: [%{field: to_string(input), message: "is not an accepted input"}]

  defp field_error(_), do: []

  defp interpolate(message, error) do
    error
    |> Map.get(:vars, [])
    |> List.wrap()
    |> Enum.reduce(message, fn
      {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value))
      _, acc -> acc
    end)
  end

  defp send_error(conn, status, code, message, details \\ %{}) do
    conn
    |> put_status(status)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: code, message: message, details: details)
  end
end
