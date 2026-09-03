defmodule PromptOnWeb.EditorTestRun do
  @moduledoc """
  Request assembly, execution, and recording for one cell (= one model) of the use case screen's
  **arena** (`PromptOnWeb.PromptEditorLive`, plan.md §11.2).

  No deployment is required. What runs here is the *edit buffer* (the draft), regardless of whether
  it has been saved (ADR 0007). A Deployment is the artifact committed **after** "let's go with this
  model" has been decided, not a precondition for running.

  - `build_messages/4` renders the buffer (`[%{role, content}]`) with the variables. `kind :text` is
    a single template, so the rendered result becomes **one user message** (OpenRouter only accepts
    messages).
  - `context_turns/2` reduces the cell's **persistent history** (`PromptOn.Prompts.ArenaMessage`) to
    its last 30 turns, in the shape the request carries. See "Context window" below.
  - `run/1` appends `:turns` after the rendered buffer and calls `PromptOn.LLM.complete/2`. It runs
    **inside the LiveView's `start_async` task**, so it never holds the socket.
  - `record/2` records the result as a `Generation` (`source :playground`).
  - `cast_variables/2`, `missing_required/2`, `render_error_message/1`, `llm_error_message/1` handle
    variable form casting and error copy. The Playground module used to own them, but once the arena
    became the only execution screen they **moved here** (nothing outside this module references
    them).

  ## Context window (last 30 turns)

  The arena history is append-only, so a long conversation would overflow the provider context. The
  request therefore carries **the cell's last 30 turns** (`max_context_turns/0`). Only the request
  is trimmed; the screen and the table keep everything.

  Failed assistant turns (`status: :error`) are not carried. They are slots the model never
  answered, so putting them into the conversation would send an empty assistant message. Trimming
  happens **after** filtering.

  ## Can it record without saving? (verified)

  The only references a log carries are `prompt_version_id` and `model_id`, and both are nullable.
  `prompt_version_id` is set only when a version is selected (`nil` for a buffer that has not been
  saved yet).

  However, **the raw payload (`GenerationPayload`) is not kept** (`payload_state :dropped`). The
  payload policy exists to reproduce "this version was run with this model", and a draft run has no
  such reference point: a payload pointing at an unsaved buffer can never be compared against
  anything later. Only the narrow table (cost, latency, tokens, errors) is kept. Restoring the arena
  screen is `ArenaMessage`'s separate job.
  """

  alias PromptOn.Observability.Generation
  alias PromptOnSDK.Template

  require Logger

  @max_context_turns 30

  @typedoc "One conversation turn: `role` is user/assistant, `content` is raw text, never rendered."
  @type turn :: %{optional(any()) => any()}

  @type context :: %{
          :project => map(),
          :use_case => map(),
          :model => map(),
          :buffer => [map()],
          :variables => map(),
          optional(:engine) => atom(),
          optional(:prompt_version_id) => String.t() | nil,
          optional(:turns) => [turn()]
        }

  @type result :: map()

  @doc "Max conversation turns carried in the request (the screen and the table are not trimmed)."
  @spec max_context_turns() :: pos_integer()
  def max_context_turns, do: @max_context_turns

  # ---------------------------------------------------------------------------
  # Render

  @doc """
  Renders the edit buffer with the variables to build the request messages. On failure, returns the
  render error (`{:missing_variable, name}` / `{:parse, _}` / `{:render, _}`).
  """
  @spec build_messages(map(), [map()], map(), atom()) :: {:ok, [map()]} | {:error, term()}
  def build_messages(use_case, buffer, variables, engine \\ :liquid)

  def build_messages(%{kind: :text}, buffer, variables, engine) do
    case Template.render(first_content(buffer), variables, engine: engine) do
      {:ok, text} -> {:ok, [%{"role" => "user", "content" => text}]}
      {:error, reason} -> {:error, reason}
    end
  end

  def build_messages(_use_case, buffer, variables, engine) do
    buffer
    |> Enum.map(&%{"role" => to_string(role_of(&1)), "content" => content_of(&1) || ""})
    |> Template.render_messages(variables, engine: engine)
  end

  defp first_content([message | _rest]), do: content_of(message) || ""
  defp first_content(_buffer), do: ""

  defp role_of(%{role: role}), do: role
  defp role_of(%{"role" => role}), do: role
  defp role_of(_message), do: "user"

  defp content_of(%{content: content}), do: content
  defp content_of(%{"content" => content}), do: content
  defp content_of(_message), do: ""

  # ---------------------------------------------------------------------------
  # Context window

  @doc """
  One cell's persistent history → the list of turns to carry in the request. Failed turns are
  filtered out **first**, then only the last `limit` remain (trimming before filtering would let
  error rows eat the window, losing that much real conversation).

      iex> alias PromptOnWeb.EditorTestRun
      iex> EditorTestRun.context_turns([
      ...>   %{role: :user, content: "hi", status: :ok},
      ...>   %{role: :assistant, content: "", status: :error},
      ...>   %{role: :assistant, content: "hello", status: :ok}
      ...> ])
      [%{role: "user", content: "hi"}, %{role: "assistant", content: "hello"}]
  """
  @spec context_turns([map()], pos_integer()) :: [%{role: String.t(), content: String.t()}]
  def context_turns(messages, limit \\ @max_context_turns) do
    messages
    |> List.wrap()
    |> Enum.reject(&(status_of(&1) == :error))
    |> Enum.take(-limit)
    |> Enum.map(&%{role: to_string(role_of(&1)), content: to_string(content_of(&1) || "")})
  end

  defp status_of(%{status: status}), do: status
  defp status_of(%{"status" => status}), do: status
  defp status_of(_message), do: :ok

  # ---------------------------------------------------------------------------
  # Variables

  @doc """
  Variable form (string map) → Liquid variable map. Only names declared in `input_schema` are
  included (undeclared values are dropped).

  - `:list` splits by line (blank lines excluded).
  - `:map` parses as JSON; on failure the raw string is kept as is (so the render fails honestly).
  - `:number` parses as integer/float; on failure the raw string.
  - `:boolean` is true only for `"true"`/`"1"`.
  - Anything else is the string as is (empty values go in as `""` too: `strict_variables` only
    errors on "the key is missing").
  """
  @spec cast_variables([map()], map()) :: map()
  def cast_variables(input_schema, values) do
    Map.new(List.wrap(input_schema), fn variable ->
      {variable.name, cast_value(variable.type, Map.get(values, variable.name, ""))}
    end)
  end

  defp cast_value(:list, raw) do
    raw
    |> to_string()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp cast_value(:map, raw) do
    case Jason.decode(to_string(raw)) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> to_string(raw)
    end
  end

  defp cast_value(:number, raw) do
    text = raw |> to_string() |> String.trim()

    case Integer.parse(text) do
      {int, ""} ->
        int

      _other ->
        case Float.parse(text) do
          {float, ""} -> float
          _other -> to_string(raw)
        end
    end
  end

  defp cast_value(:boolean, raw), do: String.trim(to_string(raw)) in ["true", "1"]

  defp cast_value(_type, raw), do: to_string(raw)

  @doc "Names of `required?` variables whose form value is blank."
  @spec missing_required([map()], map()) :: [String.t()]
  def missing_required(input_schema, values) do
    input_schema
    |> List.wrap()
    |> Enum.filter(&(&1.required? and blank?(Map.get(values, &1.name, ""))))
    |> Enum.map(& &1.name)
  end

  defp blank?(value), do: value |> to_string() |> String.trim() == ""

  # ---------------------------------------------------------------------------
  # Execution

  @doc """
  Actually runs one model. The return value is always a map (so the `start_async` task never dies
  from an exception):

      %{status: :ok, messages: [...], outcome: %{...}, params: %{}, provider_options: %{},
        context: %{...}, started_at: ~U[...], received_at: ~U[...]}

      %{status: :error, stage: :render | :llm, reason: term(), message: "…", context: %{...},
        messages: [...] | nil, ...}

  The result carries the **dispatch-time context** as is (`:context`). Rebuilding it from the
  assigns after completion would lose the (already billed) call of a user who edited the buffer
  mid-run, leaving no Generation behind.
  """
  @spec run(context()) :: result()
  def run(%{project: project, use_case: use_case, model: model, variables: variables} = context) do
    params = use_case.default_params || %{}
    provider_options = model.provider_options || %{}
    started_at = DateTime.utc_now()

    base = %{
      context: context,
      params: params,
      provider_options: provider_options,
      variables: variables,
      started_at: started_at
    }

    case build_messages(use_case, Map.get(context, :buffer, []), variables, engine(context)) do
      {:ok, rendered} ->
        messages = rendered ++ conversation_turns(context)

        request = %{
          model: model.model_id,
          messages: messages,
          params: params,
          provider_options: provider_options
        }

        # BYOK keys are **organization-owned** (2026-09-01): what the adapter receives is the
        # organization id, not the project id.
        complete(request, project.organization_id, Map.put(base, :messages, messages))

      {:error, reason} ->
        Map.merge(base, %{
          status: :error,
          stage: :render,
          reason: reason,
          message: render_error_message(reason),
          messages: nil,
          received_at: DateTime.utc_now()
        })
    end
  end

  defp engine(context), do: Map.get(context, :engine) || :liquid

  defp complete(request, organization_id, base) do
    case PromptOn.LLM.complete(request, organization_id: organization_id) do
      {:ok, outcome} ->
        Map.merge(base, %{status: :ok, outcome: outcome, received_at: DateTime.utc_now()})

      {:error, reason} ->
        Map.merge(base, %{
          status: :error,
          stage: :llm,
          reason: reason,
          message: llm_error_message(reason),
          received_at: DateTime.utc_now()
        })
    end
  end

  # The prior conversation is **not rendered**: it is sent exactly as the user typed it and exactly
  # as the model answered (variable substitution is the template's job; the conversation is
  # already-made raw text).
  defp conversation_turns(context) do
    context
    |> Map.get(:turns)
    |> List.wrap()
    |> Enum.map(&%{"role" => to_string(role_of(&1)), "content" => to_string(content_of(&1))})
  end

  # ---------------------------------------------------------------------------
  # Error copy

  @doc "Render failure reason → one line shown on screen as is."
  @spec render_error_message(term()) :: String.t()
  def render_error_message(:no_prompt_version),
    do: "This column has no prompt version to render."

  def render_error_message({:missing_variable, name}),
    do: "Template variable `#{name}` has no value."

  def render_error_message({:parse, error}), do: "Template parse failed: #{describe(error)}"
  def render_error_message({:render, error}), do: "Template render failed: #{describe(error)}"
  def render_error_message(other), do: "Template render failed: #{describe(other)}"

  @doc "LLM call failure reason → one line shown on screen as is."
  @spec llm_error_message(term()) :: String.t()
  def llm_error_message(:no_provider_key),
    do: "No provider key (organization key or PTN_OPENROUTER_API_KEY)."

  def llm_error_message({:http_error, status, body, _headers}),
    do: llm_error_message({:http_error, status, body})

  def llm_error_message({:http_error, status, body}),
    do: "Provider responded HTTP #{status}: #{String.slice(describe(body), 0, 240)}"

  def llm_error_message({:request_failed, reason}), do: "Request failed: #{describe(reason)}"
  def llm_error_message({:invalid_response, _body}), do: "Couldn't parse the provider response."
  def llm_error_message(other), do: "Call failed: #{describe(other)}"

  defp describe(term) when is_binary(term), do: term
  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(term), do: inspect(term)

  # ---------------------------------------------------------------------------
  # Recording

  @doc """
  Records the run result as a `Generation`. So that the screen is never blocked, a failure is only
  logged and `{:error, reason}` is returned.
  """
  @spec record(context(), result()) :: {:ok, map()} | {:error, term()}
  def record(%{project: project} = context, result) do
    opts = [tenant: project.id, actor: PromptOn.SystemActor.new()]

    Generation
    |> Ash.Changeset.for_create(:record_playground, generation_attrs(context, result), opts)
    |> Ash.create()
    |> case do
      {:ok, generation} ->
        {:ok, generation}

      {:error, error} ->
        Logger.warning("use case arena: generation not recorded: #{inspect(error)}")
        {:error, error}
    end
  rescue
    error ->
      Logger.warning("use case arena: generation not recorded: #{Exception.message(error)}")
      {:error, error}
  end

  defp generation_attrs(%{use_case: use_case, model: model} = context, result) do
    %{
      id: Ash.UUIDv7.generate(),
      use_case_id: use_case.id,
      use_case_key: use_case.key,
      prompt_version_id: Map.get(context, :prompt_version_id),
      model_id: model.id,
      model: model.model_id,
      provider: model.provider,
      kind: use_case.kind,
      latency_ms: latency_ms(result),
      started_at: result.started_at,
      received_at: result.received_at,
      params: result.params,
      payload_state: :dropped,
      metadata: metadata(result)
    }
    |> Map.merge(outcome_attrs(result))
  end

  defp outcome_attrs(%{status: :ok, outcome: outcome}) do
    %{
      status: :ok,
      finish_reason: outcome.finish_reason,
      stop_kind: outcome.stop_kind,
      input_tokens: outcome.usage[:input_tokens],
      output_tokens: outcome.usage[:output_tokens],
      cost_usd: outcome.cost_usd,
      cost_source: if(is_nil(outcome.cost_usd), do: nil, else: :provider)
    }
  end

  defp outcome_attrs(%{status: :error} = result) do
    %{status: :error, error_kind: error_kind(result), error_message: result.message}
  end

  defp error_kind(%{stage: :render}), do: :app
  defp error_kind(%{reason: :no_provider_key}), do: :app

  defp error_kind(%{reason: {:http_error, status, body, _headers}} = result),
    do: error_kind(%{result | reason: {:http_error, status, body}})

  defp error_kind(%{reason: {:http_error, 429, _body}}), do: :rate_limited
  defp error_kind(%{reason: {:http_error, status, _body}}) when status in 400..499, do: :http_4xx
  defp error_kind(%{reason: {:http_error, status, _body}}) when status >= 500, do: :http_5xx
  defp error_kind(%{reason: {:invalid_response, _body}}), do: :parse
  defp error_kind(%{reason: {:request_failed, %{reason: :timeout}}}), do: :timeout
  defp error_kind(%{reason: {:request_failed, _reason}}), do: :transport
  defp error_kind(_result), do: :app

  defp latency_ms(%{status: :ok, outcome: %{latency_ms: ms}}) when is_integer(ms), do: ms

  defp latency_ms(%{started_at: started_at, received_at: received_at}),
    do: max(DateTime.diff(received_at, started_at, :millisecond), 0)

  defp metadata(%{status: :ok, outcome: outcome}),
    do: %{"model_used" => outcome.model_used, "screen" => "use_case_arena"}

  defp metadata(_result), do: %{"screen" => "use_case_arena"}
end
