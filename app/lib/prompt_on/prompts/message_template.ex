defmodule PromptOn.Prompts.MessageTemplate do
  @moduledoc """
  An element of PromptVersion `messages` (embedded, plan.md §5.5). `content` is **verbatim by
  contract**, hence `@raw_string` (empty string allowed, no trim): whitespace and newlines are
  stored and rendered exactly as written. `name` is the OpenAI-style participant name (optional).
  """

  use Ash.Resource, data_layer: :embedded

  @raw_string [allow_empty?: true, trim?: false]

  attributes do
    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:system, :user, :assistant]
    end

    attribute :content, :string do
      allow_nil? false
      public? true
      constraints @raw_string
    end

    attribute :name, :string, public?: true
  end
end
