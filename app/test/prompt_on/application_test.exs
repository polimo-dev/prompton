defmodule PromptOn.ApplicationTest do
  @moduledoc """
  Supervision tree mode contract: `:library` is only the three data-layer children, and `:server`
  stacks the endpoint and Oban on top of them.
  """
  use ExUnit.Case, async: true

  alias PromptOn.Application, as: App

  @data_layer [PromptOn.Repo, PromptOn.Vault, {Phoenix.PubSub, name: PromptOn.PubSub}]

  test ":library mode starts only Repo, Vault and PubSub — no endpoint, no Oban, no caches" do
    assert App.children(:library) == @data_layer
  end

  test ":server mode stacks the endpoint, Oban, caches and rate limiting onto the data layer" do
    server = App.children(:server)

    for child <- @data_layer, do: assert(child in server)

    assert PromptOnWeb.Endpoint in server
    assert PromptOnWeb.Telemetry in server
    assert PromptOn.Deployments.SnapshotCache in server
    assert PromptOn.Accounts.ProviderKeyCache in server
    assert Enum.any?(server, &match?({Oban, _config}, &1))
    assert Enum.any?(server, &match?({PromptOn.RateLimit, _opts}, &1))
    assert Enum.any?(server, &match?({AshAuthentication.Supervisor, _opts}, &1))
  end

  test "Repo starts before Vault in every mode (no vault, no reading encrypted attributes)" do
    for mode <- [:library, :server] do
      children = App.children(mode)
      repo_index = Enum.find_index(children, &(&1 == PromptOn.Repo))
      vault_index = Enum.find_index(children, &(&1 == PromptOn.Vault))
      assert repo_index < vault_index, "mode #{mode}: Repo must precede Vault"
    end
  end

  test "mode/0 is :server when nothing is configured (the test environment does not set :mode)" do
    assert App.mode() == :server
  end
end
