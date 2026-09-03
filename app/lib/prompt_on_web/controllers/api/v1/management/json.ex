defmodule PromptOnWeb.API.V1.Management.JSON do
  @moduledoc """
  Management API response serialization (`docs/management-api.md`).

  The conventions are the same as the public API's (`docs/api.md`, common conventions): **keys are
  snake_case strings**, ids are UUID strings without a prefix, timestamps are ISO8601 (UTC), and
  responses are **bare objects** with no wrapper like `{"data": …}` - `POST /resolve`,
  `GET /snapshot`, and `POST /generations` already work this way, and two envelopes in one API
  would make the client (a coding AI) ask which one it is every time. A list is an object with a
  single plural key (`{"projects": [...]}`) - a top-level array leaves no room to add paging
  information later.

  Domain field names are used as-is, except that **the question mark is dropped** (`personal?` ->
  `"personal"`, `required?` -> `"required"`): JSON has no convention of keys ending in `?`. Writes
  accept the same names.
  """

  alias PromptOn.Accounts.ProviderKey
  alias PromptOn.Prompts.Prompt
  alias PromptOn.Prompts.PromptVersion

  @doc "User - the person a CLI session token points at (`GET /me`, device approval response)."
  def user(user) do
    %{"id" => user.id, "email" => to_string(user.email)}
  end

  @doc "Organization (`GET /orgs`, `GET /orgs/:org`)."
  def organization(org) do
    %{
      "id" => org.id,
      "name" => org.name,
      "slug" => org.slug,
      "personal" => org.personal?,
      "created_at" => timestamp(org.inserted_at)
    }
  end

  @doc """
  Project. `environments` is passed in by whoever loaded it (it is a tenant resource, so every
  project has a different tenant).
  """
  def project(project, environments \\ nil) do
    base = %{
      "id" => project.id,
      "slug" => project.slug,
      "name" => project.name,
      "timezone" => project.timezone,
      "created_at" => timestamp(project.inserted_at)
    }

    case environments do
      nil -> base
      envs -> Map.put(base, "environments", Enum.map(envs, &environment/1))
    end
  end

  @doc "Environment. Deployment pins are selected by this `slug`."
  def environment(env) do
    %{
      "id" => env.id,
      "slug" => env.slug,
      "name" => env.name,
      "protected" => env.protected?
    }
  end

  @doc "Use case (the body of list, create, and update)."
  def use_case(use_case) do
    %{
      "id" => use_case.id,
      "key" => use_case.key,
      "name" => use_case.name,
      "description" => use_case.description,
      "kind" => to_string(use_case.kind),
      "input_schema" => Enum.map(use_case.input_schema || [], &variable/1),
      "default_params" => use_case.default_params || %{},
      "tags" => use_case.tags || [],
      "created_at" => timestamp(use_case.inserted_at)
    }
  end

  @doc "An `input_schema` entry - declarative and for documentation; values are not validated (P0)."
  def variable(variable) do
    %{
      "name" => variable.name,
      "type" => to_string(variable.type),
      "required" => variable.required?,
      "description" => variable.description,
      "example" => variable.example
    }
  end

  @doc "Prompt. `versions` is passed in by the caller as a summary list."
  def prompt(%Prompt{} = prompt, versions \\ nil) do
    base = %{
      "id" => prompt.id,
      "name" => prompt.name,
      "description" => prompt.description,
      "created_at" => timestamp(prompt.inserted_at)
    }

    case versions do
      nil ->
        base

      list ->
        Map.merge(base, %{
          "version_count" => length(list),
          "versions" => Enum.map(list, &prompt_version_summary/1)
        })
    end
  end

  @doc "The full committed version (commit response)."
  def prompt_version(%PromptVersion{} = version) do
    %{
      "id" => version.id,
      "prompt_id" => version.prompt_id,
      "number" => version.number,
      "engine" => to_string(version.engine),
      "messages" => Enum.map(version.messages || [], &message/1),
      "text_template" => version.text_template,
      "detected_variables" => version.detected_variables || [],
      "message" => version.commit_message,
      "content_sha256" => version.content_sha256,
      "created_at" => timestamp(version.inserted_at)
    }
  end

  @doc "Version summary (a history row in the use case detail)."
  def prompt_version_summary(%PromptVersion{} = version) do
    %{
      "id" => version.id,
      "number" => version.number,
      "message" => version.commit_message,
      "detected_variables" => version.detected_variables || [],
      "created_at" => timestamp(version.inserted_at)
    }
  end

  @doc "One message template line. `name` is included only when present (as in `POST /resolve`)."
  def message(message) do
    base = %{"role" => to_string(message.role), "content" => message.content}

    case message.name do
      nil -> base
      name -> Map.put(base, "name", name)
    end
  end

  @doc """
  Catalog model. `model_id` is the provider-side string; `id` is the UUID a deployment pin points
  at.
  """
  def model(model) do
    %{
      "id" => model.id,
      "provider" => to_string(model.provider),
      "model_id" => model.model_id,
      "display_name" => model.display_name,
      "metadata" => model.metadata || %{},
      "provider_options" => model.provider_options || %{},
      "pricing" => model.pricing || %{},
      "context_length" => model.context_length,
      "capabilities" => Enum.map(model.capabilities || [], &to_string/1),
      "status" => to_string(model.status),
      "created_at" => timestamp(model.inserted_at)
    }
  end

  @doc """
  Deployment revision = **pin**. `model_id` means the same as in snapshot v3 (the UUID of the
  catalog Model), and `model` is that model's provider string (only when available).
  """
  def deployment(deployment, environment_slug, model \\ nil) do
    base = %{
      "id" => deployment.id,
      "revision" => deployment.revision,
      "environment" => environment_slug,
      "model_id" => deployment.model_id,
      "params" => deployment.params || %{},
      "provider_options" => deployment.provider_options || %{},
      "prompt_pins" => deployment.prompt_pins || %{},
      "created_at" => timestamp(deployment.inserted_at)
    }

    case model do
      nil -> base
      model -> Map.put(base, "model", model.model_id)
    end
  end

  @doc """
  Runtime API key. **The raw key (`key`) is included only in the issue response** - only the sha256
  hash is stored, so it can never be seen again.
  """
  def api_key(key, raw \\ nil) do
    base = %{
      "id" => key.id,
      "name" => key.name,
      "key_prefix" => key.key_prefix,
      "scopes" => Enum.map(key.scopes || [], &to_string/1),
      "last_used_at" => timestamp(key.last_used_at),
      "created_at" => timestamp(key.inserted_at)
    }

    case raw do
      nil -> base
      raw -> Map.put(base, "key", raw)
    end
  end

  @doc "Organization provider key status - **the raw secret never goes out** (masked `hint` only)."
  def provider_key(nil), do: %{"connected" => false, "provider" => "openrouter"}

  def provider_key(%ProviderKey{} = key) do
    %{
      "connected" => true,
      "id" => key.id,
      "provider" => to_string(key.provider),
      "label" => key.label,
      "hint" => key.secret_hint,
      "last_used_at" => timestamp(key.last_used_at),
      "created_at" => timestamp(key.inserted_at)
    }
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
