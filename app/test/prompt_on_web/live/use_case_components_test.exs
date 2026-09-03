defmodule PromptOnWeb.UseCaseComponentsTest do
  @moduledoc """
  Pure helpers of the components specific to the use case list screen (counterparts of
  `KIND_ICON` and `logOnly` in `s_usecases.jsx`).
  """
  use ExUnit.Case, async: true

  import PromptOnWeb.UseCaseComponents

  doctest PromptOnWeb.UseCaseComponents, import: true

  describe "kind_icon/1" do
    test "carries the mockup KIND_ICON over as is" do
      assert kind_icon(:chat) == "note"
      assert kind_icon(:text) == "code"
      assert kind_icon(:embedding) == "variable"
      assert kind_icon("chat") == "note"
    end

    test "an unknown kind gets the default icon" do
      assert kind_icon(:nope) == "layers"
    end
  end

  describe "log_only?/1" do
    test "only embedding is log only" do
      assert log_only?(%{kind: :embedding})
      assert log_only?(%{kind: "embedding"})
      refute log_only?(%{kind: :chat})
      refute log_only?(%{kind: :text})
    end
  end
end
