defmodule PromptOn.Catalog.ProviderCatalogTest do
  use ExUnit.Case, async: false

  alias PromptOn.Catalog.ProviderCatalog

  setup do
    ProviderCatalog.reset_cache()

    on_exit(fn ->
      Application.put_env(:prompton, :provider_catalog_req_options,
        plug: fn conn -> Req.Test.json(conn, %{"data" => []}) end
      )

      ProviderCatalog.reset_cache()
    end)
  end

  describe "list_openrouter_models/1 normalization" do
    test "does not die on odd prices and leaves unknown prices nil" do
      stub_openrouter(%{
        "data" => [
          %{
            "id" => "a/normal",
            "pricing" => %{"prompt" => "0.000003", "completion" => "0.000015"}
          },
          %{"id" => "b/sub-cent", "pricing" => %{"prompt" => "0.0000015"}},
          %{"id" => "c/dynamic", "pricing" => %{"prompt" => "-1", "completion" => "-1"}},
          %{"id" => "d/free", "pricing" => %{"prompt" => "0", "completion" => "0"}},
          %{"id" => "e/garbage", "pricing" => %{"prompt" => "abc", "completion" => nil}},
          %{"id" => "f/not-a-map", "pricing" => "cheap"},
          %{"id" => "g/absent"}
        ]
      })

      {:ok, models} = ProviderCatalog.list_openrouter_models(cache: false)
      pricing = Map.new(models, &{&1.model_id, &1.pricing})

      assert pricing["a/normal"] == %{input_per_m: 3.0, output_per_m: 15.0}
      assert pricing["b/sub-cent"] == %{input_per_m: 1.5, output_per_m: nil}
      assert pricing["c/dynamic"] == %{input_per_m: nil, output_per_m: nil}
      assert pricing["d/free"] == %{input_per_m: 0.0, output_per_m: 0.0}
      assert pricing["e/garbage"] == %{input_per_m: nil, output_per_m: nil}
      assert pricing["f/not-a-map"] == %{input_per_m: nil, output_per_m: nil}
      assert pricing["g/absent"] == %{input_per_m: nil, output_per_m: nil}
    end

    test "created is Unix seconds and nil when unknown" do
      stub_openrouter(%{
        "data" => [
          %{"id" => "a/created", "created" => 1_700_000_000},
          %{"id" => "b/string", "created" => "1700000001"},
          %{"id" => "c/zero", "created" => 0},
          %{"id" => "d/garbage", "created" => "soon"},
          %{"id" => "e/absent"}
        ]
      })

      {:ok, models} = ProviderCatalog.list_openrouter_models(cache: false)
      created = Map.new(models, &{&1.model_id, &1.created})

      assert created["a/created"] == 1_700_000_000
      assert created["b/string"] == 1_700_000_001
      assert created["c/zero"] == nil
      assert created["d/garbage"] == nil
      assert created["e/absent"] == nil
    end

    test "custom req_options bypass the shared cache" do
      stub_openrouter(%{"data" => [%{"id" => "cached/model"}]})

      assert {:ok, [%{model_id: "cached/model"}]} = ProviderCatalog.list_openrouter_models()

      assert {:ok, [%{model_id: "custom/model"}]} =
               ProviderCatalog.list_openrouter_models(
                 req_options: [
                   plug: fn conn ->
                     Req.Test.json(conn, %{"data" => [%{"id" => "custom/model"}]})
                   end
                 ]
               )

      assert {:ok, [%{model_id: "cached/model"}]} = ProviderCatalog.list_openrouter_models()
    end
  end

  defp stub_openrouter(payload) do
    ProviderCatalog.reset_cache()

    Application.put_env(:prompton, :provider_catalog_req_options,
      plug: fn conn -> Req.Test.json(conn, payload) end
    )
  end
end
