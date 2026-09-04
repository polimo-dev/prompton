defmodule PromptOnWeb.API.V1.UseCasePromptController do
  @moduledoc """
  `POST /api/v1/use-cases/:key/prompt` - the reference implementation of prompt filling (plan.md
  §6.3, ADR 0007 revision 2026-09-01). Runs the **same code** as the SDK
  (`PromptOnSDK.Resolver`) on the server for non-SDK clients, debugging, and render-equivalence
  checks.

  Request `{"environment": "production", "prompt": "default", "variables": {}}` - with
  `variables` present the templates are rendered as well. With deployments turning from routers
  into **pins**, `ctx`, `target_id`, and `subject_key` are gone - the use case key is the URL
  segment and the only remaining selection axis is the prompt name.

  Response: `key`, `deployment{id,revision}`, `prompt`, `model`/`params`/
  `provider_options`, `prompt_version{id,number}`, `messages` or `text`, `prompt_names[]` (the
  names this deployment pinned), and `etag`.

  Errors: unknown use case/environment -> 404, no deployment -> 404 (`details.reason =
  "unresolved"`), a prompt name that is not pinned -> 404 (`details.reason = "unknown_prompt"` +
  `details.prompt_names`), missing variable -> 400 (`details.missing_variable`).

  This endpoint is **not cached** (unlike `GET /use-cases`): it is the smoke test a person hits right
  after deploying and the debugging window, so "the use case just created, the revision just
  committed" must show up immediately. The side that pays the polling cost is the use-case document,
  and only that side goes through `PromptOn.Deployments.SnapshotCache`.
  """

  use PromptOnWeb, :controller

  alias PromptOn.Deployments.Snapshot
  alias PromptOnSDK.{Resolver, Template, UseCaseDocument}
  alias PromptOnWeb.API.V1.RequestEnvironment

  plug PromptOnWeb.Plugs.RequireScope, :read

  action_fallback PromptOnWeb.API.V1.FallbackController

  def create(conn, %{"key" => use_case_key} = params) do
    api_key = conn.assigns.api_key

    with {:ok, use_case_key} <- validate_use_case_key(use_case_key),
         {:ok, prompt} <- fetch_prompt(params),
         {:ok, variables} <- fetch_optional_map(params, "variables"),
         {:ok, environment} <- RequestEnvironment.fetch(conn, params),
         {:ok, snapshot} <-
           Snapshot.build(environment, actor: api_key, tenant: api_key.project_id),
         {:ok, data, _warnings} <- UseCaseDocument.decode(snapshot.map),
         {:ok, resolution} <-
           resolve(data, use_case_key, prompt: prompt, etag: snapshot.etag),
         {:ok, rendered} <- render_templates(resolution, variables) do
      {:ok, prompts} = Resolver.prompt_names(data, use_case_key)
      json(conn, response(use_case_key, resolution, rendered, prompts, snapshot.etag))
    end
  end

  # ---------------------------------------------------------------------------
  # params

  defp validate_use_case_key(key) when is_binary(key) and key != "", do: {:ok, key}
  defp validate_use_case_key(_), do: {:error, {:invalid_request, "use case key is required"}}

  defp fetch_prompt(params) do
    case Map.get(params, "prompt") do
      nil -> {:ok, nil}
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, {:invalid_request, "prompt must be a non-empty string"}}
    end
  end

  defp fetch_optional_map(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      map when is_map(map) -> {:ok, map}
      _ -> {:error, {:invalid_request, "#{key} must be an object"}}
    end
  end

  # ---------------------------------------------------------------------------
  # resolve + render

  defp resolve(data, use_case_key, opts) do
    case Resolver.resolve(data, use_case_key, opts) do
      {:ok, resolution} ->
        {:ok, resolution}

      {:error, :unknown_use_case} ->
        {:error, {:not_found, "unknown use case: #{use_case_key}", %{"key" => use_case_key}}}

      {:error, :unresolved} ->
        {:error,
         {:not_found, "this use case has no live deployment in this environment",
          %{"reason" => "unresolved"}}}

      {:error, :unknown_prompt} ->
        {:error, unknown_prompt(data, use_case_key, opts[:prompt])}
    end
  end

  # The 404 envelope for a prompt name that is not pinned. **Lists every name that could have been
  # chosen** - in exchange for having no silent fallback (ADR 0007 revision), the app must be able
  # to tell a typo from a missing deployment right away.
  defp unknown_prompt(data, use_case_key, requested) do
    name = requested || Resolver.default_prompt()

    available =
      case Resolver.prompt_names(data, use_case_key) do
        {:ok, names} -> names
        {:error, _reason} -> []
      end

    {:not_found,
     "the live deployment pins no prompt named #{inspect(name)}#{available_note(available)}",
     %{
       "reason" => "unknown_prompt",
       "key" => use_case_key,
       "prompt" => name,
       "prompt_names" => available
     }}
  end

  defp available_note([]), do: " (it pins no prompt at all)"
  defp available_note(names), do: " — pinned prompt names: " <> Enum.join(names, ", ")

  # No variables -> the raw templates as-is
  defp render_templates(resolution, nil),
    do: {:ok, %{messages: resolution.messages, text: resolution.text_template}}

  defp render_templates(%{kind: :chat, messages: messages} = resolution, variables)
       when is_list(messages) do
    case Template.render_messages(messages, variables, engine: resolution.engine || :liquid) do
      {:ok, rendered} -> {:ok, %{messages: rendered, text: nil}}
      {:error, reason} -> {:error, render_error(reason)}
    end
  end

  defp render_templates(%{kind: :text, text_template: text} = resolution, variables)
       when is_binary(text) do
    case Template.render(text, variables, engine: resolution.engine || :liquid) do
      {:ok, rendered} -> {:ok, %{messages: nil, text: rendered}}
      {:error, reason} -> {:error, render_error(reason)}
    end
  end

  defp render_templates(resolution, _variables),
    do: {:ok, %{messages: resolution.messages, text: resolution.text_template}}

  defp render_error({:missing_variable, name}),
    do: {:invalid_request, "missing variable: #{name}", %{"missing_variable" => name}}

  defp render_error({:parse, error}),
    do: {:invalid_request, "template parse error: #{inspect(error)}"}

  defp render_error({:render, error}),
    do: {:invalid_request, "template render error: #{inspect(error)}"}

  defp render_error(other), do: {:invalid_request, "template error: #{inspect(other)}"}

  # ---------------------------------------------------------------------------
  # response (docs/api.md)

  defp response(use_case_key, resolution, rendered, prompts, etag) do
    base = %{
      "key" => use_case_key,
      "kind" => to_string(resolution.kind),
      "deployment" => %{
        "id" => resolution.deployment_id,
        "revision" => resolution.deployment_revision
      },
      "prompt" => resolution.prompt,
      "prompt_names" => prompts,
      "model_id" => resolution.model_id,
      "model" => resolution.model,
      "provider" => resolution.provider && to_string(resolution.provider),
      "params" => resolution_params(resolution),
      "provider_options" => resolution_provider_options(resolution),
      "source" => resolution.source && to_string(resolution.source),
      "prompt_version" =>
        resolution.prompt_version_id &&
          %{"id" => resolution.prompt_version_id, "number" => resolution.prompt_version_number},
      "warnings" => Enum.map(resolution.warnings, &warning_string/1),
      "etag" => etag
    }

    case resolution.kind do
      :chat -> Map.put(base, "messages", Enum.map(rendered.messages || [], &message_map/1))
      :text -> Map.put(base, "text", rendered.text)
      _ -> base
    end
  end

  defp message_map(message) do
    base = %{
      "role" => to_string(message[:role] || message["role"]),
      "content" => message[:content] || message["content"]
    }

    case message[:name] || message["name"] do
      nil -> base
      name -> Map.put(base, "name", name)
    end
  end

  defp warning_string({tag, detail}), do: "#{tag}: #{detail}"
  defp warning_string(other), do: inspect(other)

  defp resolution_params(resolution),
    do: Map.get(resolution, :params) || %{}

  defp resolution_provider_options(resolution),
    do:
      Map.get(resolution, :provider_options) ||
        %{}
end
