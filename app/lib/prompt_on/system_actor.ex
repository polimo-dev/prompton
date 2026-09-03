defmodule PromptOn.SystemActor do
  @moduledoc """
  The actor used by mix tasks, seeds and background jobs. It passes the policies through the
  `PromptOn.Checks.SystemActor` bypass. The reason to use this actor instead of `authorize?: false`:
  the domains are `authorize :always`, and "who called" has to remain in the logs and in policy
  violation diagnostics.
  """

  defstruct []

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}
end
