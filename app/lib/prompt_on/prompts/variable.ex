defmodule PromptOn.Prompts.Variable do
  @moduledoc """
  A variable declaration in the UseCase `input_schema` (embedded, plan.md §5.5). It is compared
  with the variables the templates reference (`detected_variables`) to raise the "variable not in
  schema" warning (`PromptVersion.missing_in_schema`), and it is included in the snapshot so the
  SDK/app UI know the input shape. Values are not validated (P0): declaration and documentation
  only.
  """

  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :name, :string do
      allow_nil? false
      public? true
      constraints match: ~r/^[a-z_][a-z0-9_]*$/
    end

    attribute :type, :atom do
      allow_nil? false
      public? true
      default :string
      constraints one_of: [:string, :number, :boolean, :list, :map]
    end

    attribute :required?, :boolean, allow_nil?: false, public?: true, default: false
    attribute :description, :string, public?: true
    attribute :example, :string, public?: true
  end
end
