defmodule PromptOnWeb.ErrorTextTest do
  @moduledoc """
  Shared error wording for screens (`PromptOnWeb.ErrorText`).

  With a separate formatter per screen, the same Ash error would look different on every screen;
  the shape is pinned down here.
  """
  use ExUnit.Case, async: true

  doctest PromptOnWeb.ErrorText

  alias PromptOnWeb.ErrorText

  defp invalid(fields) do
    Ash.Error.to_error_class(
      Enum.map(fields, fn {field, message} ->
        Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)
      end)
    )
  end

  test "several field errors are joined into one line with the same separator" do
    error = invalid(name: "is required", key: "has already been taken")

    assert ErrorText.message(error) == "name: is required · key: has already been taken"
  end

  test "does not leak raw Ash internals (`Invalid Error`, Bread Crumbs, stack traces)" do
    message = ErrorText.message(invalid(use_case_id: "has already been taken"))

    refute message =~ "Invalid Error"
    refute message =~ "Bread Crumbs"
    refute message =~ "\n"
  end

  test "the same message arriving twice is emitted once" do
    assert ErrorText.message(invalid(key: "is required", key: "is required")) ==
             "key: is required"
  end

  test "`%{...}` placeholders without vars are removed" do
    error = invalid(levels: "must have at least %{min} items")

    refute ErrorText.message(error) =~ "%{"
  end

  test "forbidden is one line instead of the policy internals" do
    assert ErrorText.message(%Ash.Error.Forbidden{}) == "You don't have permission to do that."
  end

  test "a value that is not an error also comes out as a one-line string" do
    assert is_binary(ErrorText.message(:boom))
  end
end
