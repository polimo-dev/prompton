defmodule PromptOn.Catalog.ModelTest do
  use PromptOn.DataCase, async: true

  import PromptOn.Fixtures

  alias PromptOn.Catalog
  alias PromptOn.Catalog.Model

  test "register stores metadata, provider_options (nil values preserved) and pricing" do
    project = project_fixture()

    model =
      model_fixture(project, %{
        provider_options: %{"only" => nil, "allow_fallbacks" => false},
        pricing: %{input_per_m: 3, output_per_m: 15, currency: "USD", unit: "token"}
      })

    {:ok, reloaded} = Catalog.get_model(model.id, scope(project))
    assert reloaded.provider_options == %{"only" => nil, "allow_fallbacks" => false}
    assert reloaded.metadata["description_key"] == "chat_model.sonnet4"
    assert reloaded.status == :active
    assert reloaded.pricing["input_per_m"] == 3
    assert reloaded.capabilities == [:tools, :streaming]
  end

  test "identity: same (provider, model_id) twice in a project is rejected, other project is fine" do
    p1 = project_fixture()
    p2 = project_fixture()
    model_fixture(p1, %{model_id: "openai/gpt-5-mini"})

    assert {:error, %Ash.Error.Invalid{}} =
             Catalog.register_model(
               %{provider: :openrouter, model_id: "openai/gpt-5-mini", display_name: "dup"},
               scope(p1)
             )

    assert %Model{} = model_fixture(p2, %{model_id: "openai/gpt-5-mini"})
  end

  test "pricing validation rejects unknown unit and negative rates" do
    project = project_fixture()

    assert {:error, %Ash.Error.Invalid{}} =
             Catalog.register_model(
               %{
                 provider: :groq,
                 model_id: "whisper",
                 display_name: "w",
                 pricing: %{"unit" => "minute"}
               },
               scope(project)
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Catalog.register_model(
               %{
                 provider: :groq,
                 model_id: "whisper",
                 display_name: "w",
                 pricing: %{"input_per_m" => -1}
               },
               scope(project)
             )

    model = model_fixture(project)

    assert {:ok, %Model{pricing: %{"unit" => "audio_second"}}} =
             Catalog.set_model_pricing(
               model,
               %{pricing: %{"input_per_m" => 0.1, "unit" => "audio_second"}},
               scope(project)
             )
  end

  test "estimate_cost uses per-million pricing; nil when no pricing" do
    project = project_fixture()
    model = model_fixture(project, %{pricing: %{"input_per_m" => 3.0, "output_per_m" => 15.0}})

    assert Decimal.equal?(Model.estimate_cost(model, 1_000_000, 100_000), Decimal.new("4.5"))
    assert Decimal.equal?(Model.estimate_cost(model, 0, 0), Decimal.new(0))
    assert Model.estimate_cost(%{pricing: %{}}, 10, 10) == nil
    assert Model.estimate_cost(%{pricing: %{"currency" => "USD"}}, 10, 10) == nil

    assert Decimal.equal?(
             Model.estimate_cost(%{pricing: %{"input_per_m" => 2}}, 500_000, 500_000),
             Decimal.new(1)
           )
  end

  test "edit_metadata / set_provider_options / deprecate / archive and read :active" do
    project = project_fixture()
    model = model_fixture(project)

    {:ok, model} =
      Catalog.edit_model_metadata(
        model,
        %{display_name: "Sonnet", metadata: %{"x" => 1}, context_length: 200_000},
        scope(project)
      )

    assert model.display_name == "Sonnet"
    assert model.context_length == 200_000

    {:ok, model} =
      Catalog.set_model_provider_options(
        model,
        %{provider_options: %{"only" => nil}},
        scope(project)
      )

    assert model.provider_options == %{"only" => nil}

    {:ok, deprecated} = Catalog.deprecate_model(model, scope(project))
    assert deprecated.status == :deprecated
    assert {:ok, []} = Catalog.list_models(scope(project))
    assert {:ok, [_]} = Catalog.list_all_models(scope(project))

    other = model_fixture(project)
    {:ok, _} = Catalog.archive_model(other, scope(project))
    assert {:ok, []} = Catalog.list_models(scope(project))
  end

  test "by_provider_model lookup" do
    project = project_fixture()
    model = model_fixture(project, %{provider: :groq, model_id: "whisper-large-v3"})

    assert {:ok, %Model{id: id}} =
             Catalog.get_model_by_provider_model(:groq, "whisper-large-v3", scope(project))

    assert id == model.id
    assert {:ok, nil} = Catalog.get_model_by_provider_model(:groq, "nope", scope(project))
  end

  test "policies: member reads/writes, stranger sees nothing, api key reads active only" do
    owner = user_fixture()
    project = project_fixture(%{user: owner})
    stranger = user_fixture()
    {api_key, _raw} = api_key_fixture(project)

    {:ok, model} =
      Catalog.register_model(
        %{provider: :openrouter, model_id: "anthropic/claude-sonnet-4", display_name: "Sonnet 4"},
        scope(project, owner)
      )

    deprecated = model_fixture(project)
    {:ok, _} = Catalog.deprecate_model(deprecated, scope(project, owner))
    archived = model_fixture(project)
    {:ok, _} = Catalog.archive_model(archived, scope(project, owner))

    assert {:ok, models} = Catalog.list_all_models(scope(project, owner))
    assert length(models) == 3

    assert {:ok, []} = Catalog.list_all_models(scope(project, stranger))

    assert {:error, %Ash.Error.Forbidden{}} =
             Catalog.register_model(
               %{provider: :openrouter, model_id: "x", display_name: "x"},
               scope(project, stranger)
             )

    assert {:ok, [visible]} = Catalog.list_all_models(scope(project, api_key))
    assert visible.id == model.id

    assert {:error, %Ash.Error.Forbidden{}} =
             Catalog.register_model(
               %{provider: :openrouter, model_id: "y", display_name: "y"},
               scope(project, api_key)
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Catalog.deprecate_model(model, scope(project, api_key))
  end
end
