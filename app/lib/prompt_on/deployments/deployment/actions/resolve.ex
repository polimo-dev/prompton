defmodule PromptOn.Deployments.Deployment.Actions.Resolve do
  @moduledoc """
  Internal generic action `:resolve`: reads the Deployment with the actor's permissions (an ApiKey
  sees only its own project, a member sees everything), assembles that environment's deployed
  use-case document
  (`PromptOn.Deployments.Snapshot.build/2`, with this revision slotted into the live position), then
  delegates to `PromptOnSDK.Resolver.resolve/3`, so the server and the SDK run **the same code**
  (ADR 0007).

  Context conditions and prompt selection are gone. The optional `prompt` argument exists for
  compatibility and must be omitted or set to `"default"`; non-default names are rejected before
  the SDK resolver runs. Passing a past revision id simulates that revision (it does not displace
  the live revision). The result is a `%PromptOnSDK.UseCase{}` unpacked into a map.
  """

  use Ash.Resource.Actions.Implementation

  alias PromptOn.Deployments.{Deployment, Snapshot}
  alias PromptOnSDK.{Resolver, UseCaseDocument}

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)
    deployment_id = input.arguments.deployment_id
    prompt = input.arguments[:prompt]

    with :ok <- default_prompt_only(prompt),
         {:ok, %Deployment{} = deployment} <- fetch_deployment(deployment_id, opts),
         {:ok, snapshot} <-
           Snapshot.build(
             deployment.environment_id,
             Keyword.put(opts, :override_deployments, [deployment])
           ),
         {:ok, data, _warnings} <- UseCaseDocument.decode(snapshot.map),
         {:ok, key} <- use_case_key(snapshot.map, deployment.use_case_id),
         {:ok, resolution} <-
           Resolver.resolve(data, key, prompt_opts(prompt) ++ [etag: snapshot.etag]) do
      {:ok, Map.from_struct(resolution)}
    else
      {:error, :unknown_use_case} ->
        {:error,
         invalid(:prompt, "use case of this deployment is archived or missing from the snapshot")}

      {:error, :unknown_prompt} ->
        {:error, invalid(:prompt, "this deployment pins no prompt named #{inspect(prompt)}")}

      {:error, :unresolved} ->
        {:error, invalid(:deployment_id, "unresolved: this use case has no live deployment")}

      {:error, :not_found} ->
        {:error,
         Ash.Error.Query.NotFound.exception(resource: Deployment, primary_key: deployment_id)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp default_prompt_only(nil), do: :ok
  defp default_prompt_only("default"), do: :ok

  defp default_prompt_only(prompt),
    do: {:error, invalid(:prompt, "only the default prompt is supported: #{inspect(prompt)}")}

  defp prompt_opts(nil), do: []
  defp prompt_opts(prompt), do: [prompt: prompt]

  defp fetch_deployment(id, opts) do
    case Ash.get(Deployment, id, Keyword.take(opts, [:actor, :tenant, :authorize?])) do
      {:ok, %Deployment{} = deployment} -> {:ok, deployment}
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp use_case_key(map, use_case_id) do
    map
    |> Map.get("use_cases", %{})
    |> Enum.find(fn {_key, use_case} -> use_case["id"] == use_case_id end)
    |> case do
      {key, _} -> {:ok, key}
      nil -> {:error, :unknown_use_case}
    end
  end

  defp invalid(field, message),
    do: Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)
end
