defmodule PromptOn.Accounts.DeviceAuthorization.Preparations.FilterByDeviceCode do
  @moduledoc """
  Turns the raw `device_code` into its sha256 and filters on a `device_code_hash` match.

  **Does not filter out expired rows**: polling must answer `expired_token` for an expired
  request, and if it could not tell "no row" from "expired" the CLI could not say "did I mistype
  the code" versus "did time run out".
  """

  use Ash.Resource.Preparation

  require Ash.Query

  alias PromptOn.Accounts.DeviceAuthorization

  @impl true
  def prepare(query, _opts, _context) do
    hash = query |> Ash.Query.get_argument(:device_code) |> DeviceAuthorization.hash()

    Ash.Query.filter(query, device_code_hash == ^hash)
  end
end
