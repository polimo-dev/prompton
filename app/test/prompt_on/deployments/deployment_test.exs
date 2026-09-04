defmodule PromptOn.Deployments.DeploymentTest do
  @moduledoc """
  A Deployment is a **pin** (ADR 0007 revised 2026-09-01): one model + one version per prompt name.
  There are no rules, conditions, targets, weights or A/B. What to verify: revision numbering, pin
  consistency, rollback and the snapshot shape.
  """

  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Deployments
  alias PromptOn.Deployments.Deployment

  setup do
    project = project_fixture()
    production = environment(project, "production")
    staging = environment(project, "staging")
    use_case = use_case_fixture(project, %{key: "diary_generation"})
    version = prompt_version_fixture(use_case)
    model = model_fixture(project)

    %{
      project: project,
      production: production,
      staging: staging,
      use_case: use_case,
      prompt: default_prompt(use_case),
      version: version,
      model: model,
      opts: scope(project)
    }
  end

  defp pin(ctx, attrs) do
    Map.merge(%{model_id: ctx.model.id, prompt_pins: %{"default" => ctx.version.id}}, attrs)
  end

  defp commit(ctx, attrs), do: commit(ctx, attrs, ctx.opts)

  defp commit(ctx, attrs, opts) do
    Deployments.commit_deployment(
      Map.merge(
        %{use_case_id: ctx.use_case.id, environment_id: ctx.production.id},
        pin(ctx, attrs)
      ),
      opts
    )
  end

  defp commit!(ctx), do: commit!(ctx, %{}, ctx.opts)
  defp commit!(ctx, attrs), do: commit!(ctx, attrs, ctx.opts)

  defp commit!(ctx, attrs, opts) do
    {:ok, deployment} = commit(ctx, attrs, opts)
    deployment
  end

  defp errors(result) do
    {:error, %Ash.Error.Invalid{} = error} = result
    Exception.message(error)
  end

  # ---------------------------------------------------------------------------

  describe "commit" do
    test "stores the model pin and prompt pins and starts at revision 1", ctx do
      d = commit!(ctx)

      assert d.revision == 1
      assert d.project_id == ctx.project.id
      assert d.use_case_id == ctx.use_case.id
      assert d.environment_id == ctx.production.id
      assert d.model_id == ctx.model.id
      assert d.params == %{}
      assert d.provider_options == %{}
      assert d.prompt_pins == %{"default" => ctx.version.id}
      # no status column: the highest revision is live
      refute Map.has_key?(d, :status)
      # rules are gone
      refute Map.has_key?(d, :rules)
    end

    test "revision increments per (use_case, environment)", ctx do
      assert commit!(ctx).revision == 1
      assert commit!(ctx).revision == 2
      assert commit!(ctx).revision == 3

      # another environment has its own numbering
      assert commit!(ctx, %{environment_id: ctx.staging.id}).revision == 1

      # another use case has its own numbering too
      other = use_case_fixture(ctx.project)
      other_version = prompt_version_fixture(other)

      assert deployment_fixture(other, ctx.production, %{
               model_id: ctx.model.id,
               prompt_pins: %{"default" => other_version.id}
             }).revision == 1
    end

    test "accepts params and provider_options", ctx do
      d =
        commit!(ctx, %{
          params: %{"temperature" => 0.4},
          provider_options: %{"allow_fallbacks" => false}
        })

      assert d.params == %{"temperature" => 0.4}
      assert d.provider_options == %{"allow_fallbacks" => false}
    end

    test "records committed_by from a User actor and honours an explicit value", ctx do
      user = ctx.project |> Ash.load!([organization: [memberships: [:user]]], scope(ctx.project))
      [membership | _] = user.organization.memberships
      actor = membership.user

      d = commit!(ctx, %{}, tenant: ctx.project.id, actor: actor)
      assert d.committed_by == actor.id

      explicit = Ash.UUIDv7.generate()

      assert commit!(ctx, %{committed_by: explicit}, tenant: ctx.project.id, actor: actor).committed_by ==
               explicit

      # the system/ApiKey actor is not a person
      assert commit!(ctx).committed_by == nil
    end
  end

  describe "commit validations — model" do
    test "model is required", ctx do
      assert errors(
               Deployments.commit_deployment(
                 %{
                   use_case_id: ctx.use_case.id,
                   environment_id: ctx.production.id,
                   prompt_pins: %{"default" => ctx.version.id}
                 },
                 ctx.opts
               )
             ) =~ "model_id"
    end

    test "model must exist in this project", ctx do
      other = model_fixture(project_fixture())
      assert errors(commit(ctx, %{model_id: other.id})) =~ "not found in this project"
    end

    test "model must be active and not archived", ctx do
      {:ok, deprecated} = PromptOn.Catalog.deprecate_model(ctx.model, scope(ctx.project))
      assert errors(commit(ctx, %{model_id: deprecated.id})) =~ "is deprecated"

      archived = model_fixture(ctx.project)
      {:ok, archived} = PromptOn.Catalog.archive_model(archived, scope(ctx.project))
      assert errors(commit(ctx, %{model_id: archived.id})) =~ "is archived"
    end
  end

  describe "commit validations — prompt pins" do
    test "a chat use case must pin at least the default prompt", ctx do
      assert errors(commit(ctx, %{prompt_pins: %{}})) =~ "at least one prompt must be pinned"
    end

    test "the default prompt must be pinned when it exists", ctx do
      {:ok, ko} =
        PromptOn.Prompts.open_prompt(
          %{use_case_id: ctx.use_case.id, name: "ko"},
          ctx.opts
        )

      ko_version = prompt_version_fixture(ko)

      assert errors(commit(ctx, %{prompt_pins: %{"ko" => ko_version.id}})) =~
               ~s|the "default" prompt must be pinned|

      assert commit!(ctx, %{
               prompt_pins: %{"default" => ctx.version.id, "ko" => ko_version.id}
             }).prompt_pins == %{"default" => ctx.version.id, "ko" => ko_version.id}
    end

    test "an unknown prompt name is rejected", ctx do
      assert errors(
               commit(ctx, %{
                 prompt_pins: %{"default" => ctx.version.id, "ja" => ctx.version.id}
               })
             ) =~ ~s|no prompt named "ja"|
    end

    test "the pinned version must belong to the named prompt", ctx do
      {:ok, ko} =
        PromptOn.Prompts.open_prompt(%{use_case_id: ctx.use_case.id, name: "ko"}, ctx.opts)

      _ko_version = prompt_version_fixture(ko)

      # an attempt to pin "ko" to a version of the default prompt
      assert errors(
               commit(ctx, %{
                 prompt_pins: %{"default" => ctx.version.id, "ko" => ctx.version.id}
               })
             ) =~ ~s|does not belong to prompt "ko"|
    end

    test "a version from another project is rejected", ctx do
      other_project = project_fixture()
      other_use_case = use_case_fixture(other_project, %{key: "diary_generation"})
      other_version = prompt_version_fixture(other_use_case)

      assert errors(commit(ctx, %{prompt_pins: %{"default" => other_version.id}})) =~
               "not found in this project"
    end

    test "an embedding use case pins no prompt", ctx do
      embedding = use_case_fixture(ctx.project, %{key: "embed_it", kind: :embedding})

      d =
        deployment_fixture(embedding, ctx.production, %{
          model_id: ctx.model.id,
          prompt_pins: %{}
        })

      assert d.prompt_pins == %{}

      assert errors(
               Deployments.commit_deployment(
                 %{
                   use_case_id: embedding.id,
                   environment_id: ctx.production.id,
                   model_id: ctx.model.id,
                   prompt_pins: %{"default" => ctx.version.id}
                 },
                 ctx.opts
               )
             ) =~ "embedding use cases pin no prompt"
    end

    test "any committed version is deployable — ADR 0007 drops the publish gate", ctx do
      v2 = prompt_version_fixture(ctx.use_case, %{messages: [%{role: :user, content: "v2"}]})
      assert v2.number == 2
      assert commit!(ctx, %{prompt_pins: %{"default" => v2.id}}).prompt_pins["default"] == v2.id
    end
  end

  describe "commit validations — use case / environment" do
    test "use case and environment must be in this project and not archived", ctx do
      other_project = project_fixture()
      other_use_case = use_case_fixture(other_project)

      assert errors(commit(ctx, %{use_case_id: other_use_case.id})) =~
               "use case not found in this project"

      assert errors(commit(ctx, %{environment_id: environment(other_project).id})) =~
               "environment not found in this project"

      {:ok, archived_env} =
        PromptOn.Projects.archive_environment(ctx.staging, scope(ctx.project))

      assert errors(commit(ctx, %{environment_id: archived_env.id})) =~ "environment is archived"

      {:ok, archived_uc} = PromptOn.Prompts.archive_use_case(ctx.use_case, scope(ctx.project))
      assert errors(commit(ctx, %{use_case_id: archived_uc.id})) =~ "use case is archived"
    end
  end

  describe "current / history" do
    test "current is the highest revision of (use_case, environment)", ctx do
      commit!(ctx)
      second = commit!(ctx)

      assert {:ok, live} =
               Deployments.current_deployment(ctx.use_case.id, ctx.production.id, ctx.opts)

      assert live.id == second.id
      assert live.revision == 2

      assert {:ok, nil} =
               Deployments.current_deployment(ctx.use_case.id, ctx.staging.id, ctx.opts)
    end

    test "history returns every revision, newest first", ctx do
      a = commit!(ctx)
      b = commit!(ctx)
      c = commit!(ctx)

      assert {:ok, revisions} =
               Deployments.deployment_history(ctx.use_case.id, ctx.production.id, ctx.opts)

      assert Enum.map(revisions, & &1.id) == [c.id, b.id, a.id]
      assert Enum.map(revisions, & &1.revision) == [3, 2, 1]
    end

    test "current_for_environment returns one live deployment per use case", ctx do
      commit!(ctx)
      live_diary = commit!(ctx)

      other = use_case_fixture(ctx.project, %{key: "chat_response"})
      live_other = simple_deployment_fixture(other, ctx.production)

      # staging does not take part in this read
      commit!(ctx, %{environment_id: ctx.staging.id})

      assert {:ok, live} =
               Deployments.current_deployments_for_environment(ctx.production.id, ctx.opts)

      assert Enum.map(live, & &1.id) |> Enum.sort() ==
               Enum.sort([live_diary.id, live_other.id])
    end
  end

  describe "rollback" do
    test "copies the source pins into a fresh revision", ctx do
      v2 = prompt_version_fixture(ctx.use_case, %{messages: [%{role: :user, content: "v2"}]})

      first = commit!(ctx, %{params: %{"temperature" => 0.2}})
      _second = commit!(ctx, %{prompt_pins: %{"default" => v2.id}, params: %{}})

      assert {:ok, third} =
               Deployments.rollback_deployment(
                 first.id,
                 %{use_case_id: ctx.use_case.id, environment_id: ctx.production.id},
                 ctx.opts
               )

      assert third.revision == 3
      assert third.prompt_pins == first.prompt_pins
      assert third.params == %{"temperature" => 0.2}
      assert third.model_id == first.model_id

      assert {:ok, live} =
               Deployments.current_deployment(ctx.use_case.id, ctx.production.id, ctx.opts)

      assert live.id == third.id
    end

    test "the source must be in this project", ctx do
      other_project = project_fixture()
      other_use_case = use_case_fixture(other_project)
      foreign = simple_deployment_fixture(other_use_case, environment(other_project))

      assert errors(
               Deployments.rollback_deployment(
                 foreign.id,
                 %{use_case_id: ctx.use_case.id, environment_id: ctx.production.id},
                 ctx.opts
               )
             ) =~ "source deployment not found in this project"
    end

    test "rejects a source from a different use case or environment when both are given", ctx do
      staging_source = commit!(ctx, %{environment_id: ctx.staging.id})

      assert errors(
               Deployments.rollback_deployment(
                 staging_source.id,
                 %{use_case_id: ctx.use_case.id, environment_id: ctx.production.id},
                 ctx.opts
               )
             ) =~ "different environment"
    end

    test "re-validates the copied pins — a since-deprecated model blocks the rollback", ctx do
      source = commit!(ctx)
      {:ok, _} = PromptOn.Catalog.deprecate_model(ctx.model, scope(ctx.project))

      assert errors(
               Deployments.rollback_deployment(
                 source.id,
                 %{use_case_id: ctx.use_case.id, environment_id: ctx.production.id},
                 ctx.opts
               )
             ) =~ "is deprecated"
    end
  end

  describe "snapshot mapping and accessors" do
    test "to_snapshot_map/1 emits the v3 deployment shape", ctx do
      d =
        commit!(ctx, %{
          params: %{"temperature" => 0.4},
          provider_options: %{"allow_fallbacks" => false}
        })

      assert Deployment.to_snapshot_map(d) == %{
               "id" => d.id,
               "revision" => 1,
               "model_id" => ctx.model.id,
               "params" => %{"temperature" => 0.4},
               "provider_options" => %{"allow_fallbacks" => false},
               "prompt_pins" => %{"default" => ctx.version.id}
             }
    end

    test "accessors expose the referenced ids", ctx do
      d = commit!(ctx)

      assert Deployment.prompt_version_ids(d) == [ctx.version.id]
      assert Deployment.model_ids(d) == [ctx.model.id]
    end

    test "domain guards see only live revisions", ctx do
      v2 = prompt_version_fixture(ctx.use_case, %{messages: [%{role: :user, content: "v2"}]})

      commit!(ctx)
      commit!(ctx, %{prompt_pins: %{"default" => v2.id}})

      assert Deployments.referencing_prompt_version?(ctx.project.id, v2.id)
      # the version a past revision pointed at is no longer live
      refute Deployments.referencing_prompt_version?(ctx.project.id, ctx.version.id)
      assert Deployments.referencing_model?(ctx.project.id, ctx.model.id)
      refute Deployments.referencing_model?(ctx.project.id, Ash.UUIDv7.generate())
    end
  end

  describe "resolve action" do
    test "resolves the pinned model + prompt of a revision", ctx do
      d = commit!(ctx, %{params: %{"temperature" => 0.4}})

      assert {:ok, resolution} = Deployments.resolve_deployment(d.id, %{}, ctx.opts)

      assert resolution.deployment_id == d.id
      assert resolution.deployment_revision == 1
      assert resolution.prompt == "default"
      assert resolution.prompt_version_id == ctx.version.id
      assert resolution.model_id == ctx.model.id

      assert Map.get(resolution, :params) == %{
               "temperature" => 0.4
             }
    end

    test "selects a named prompt and errors on an unpinned name", ctx do
      {:ok, ko} =
        PromptOn.Prompts.open_prompt(%{use_case_id: ctx.use_case.id, name: "ko"}, ctx.opts)

      ko_version = prompt_version_fixture(ko)

      d =
        commit!(ctx, %{prompt_pins: %{"default" => ctx.version.id, "ko" => ko_version.id}})

      assert {:ok, resolution} =
               Deployments.resolve_deployment(d.id, %{prompt: "ko"}, ctx.opts)

      assert resolution.prompt == "ko"
      assert resolution.prompt_version_id == ko_version.id

      assert {:error, %Ash.Error.Invalid{} = error} =
               Deployments.resolve_deployment(d.id, %{prompt: "ja"}, ctx.opts)

      assert Exception.message(error) =~ "pins no prompt"
    end
  end
end
