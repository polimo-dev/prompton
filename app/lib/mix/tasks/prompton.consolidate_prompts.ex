defmodule Mix.Tasks.Prompton.ConsolidatePrompts do
  @shortdoc "Consolidates named prompts into variables (--dry-run reports without writing)"
  @moduledoc """
  Run `mix prompton.consolidate_prompts --dry-run` to preflight old named prompts, then run
  without the flag to upgrade. The release migration task also runs this idempotent upgrade.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, [], []} = OptionParser.parse(args, strict: [dry_run: :boolean])
    Mix.Task.run("app.start")
    PromptOn.PromptConsolidation.run!(opts) |> inspect(pretty: true) |> Mix.shell().info()
  end
end
