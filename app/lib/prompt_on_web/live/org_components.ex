defmodule PromptOnWeb.OrgComponents do
  @moduledoc """
  Pieces shared by the organization-level screens (`/:org_slug`,
  `/:org_slug/settings|members|usage`).

  The sidebar does not point at the organization screens yet (the sidebar overhaul is separate
  work); in the meantime the organization screens move between each other with the `org_nav/1`
  segment in the screen header. The links here are the only way into the organization screens, so
  **all four screens mount the same segment in the same place**.
  """
  use PromptOnWeb, :html

  @sections [
    {:projects, "Projects", ""},
    {:usage, "Usage", "/usage"},
    {:members, "Members", "/members"},
    {:settings, "Settings", "/settings"}
  ]

  @doc "Segment for moving between organization screens (goes in `DS.screen`'s `<:actions>`)."
  attr :org_slug, :string, required: true
  attr :active, :atom, required: true, values: [:projects, :usage, :members, :settings]

  def org_nav(assigns) do
    assigns = assign(assigns, :options, options(assigns.org_slug))

    ~H"""
    <DS.seg id="org-nav" value={to_string(@active)} options={@options} />
    """
  end

  defp options(org_slug) do
    Enum.map(@sections, fn {id, label, suffix} ->
      %{value: to_string(id), label: label, navigate: "/#{org_slug}#{suffix}"}
    end)
  end

  @doc """
  One set of provider key inputs (shared by register and rotate). The form itself is built by the
  caller, because `phx-submit` differs per screen.
  """
  attr :form, :map, required: true
  attr :label?, :boolean, default: true

  def provider_secret_fields(assigns) do
    ~H"""
    <div class="mono-label" style="margin-bottom:7px;">api key</div>
    <DS.ds_input field={@form[:secret]} mono icon="lock" placeholder="sk-…" required />
    <div :if={@label?}>
      <div class="mono-label" style="margin:14px 0 7px;">label</div>
      <DS.ds_input field={@form[:label]} mono placeholder="default" />
    </div>
    """
  end

  @doc """
  Display value of a registered key. The raw secret never reaches the screen; only `secret_hint`
  (a plaintext mask) is read (zero decryptions, see the `PromptOn.Accounts.ProviderKey` module
  docs).

      iex> PromptOnWeb.OrgComponents.masked(nil)
      "— no key —"

      iex> PromptOnWeb.OrgComponents.masked(%{secret_hint: "sk-or-v1-••••4Xa2"})
      "sk-or-v1-••••4Xa2"

      iex> PromptOnWeb.OrgComponents.masked(%{secret_hint: nil})
      "••••"
  """
  @spec masked(map() | nil) :: String.t()
  def masked(nil), do: "— no key —"
  def masked(%{secret_hint: hint}) when is_binary(hint), do: hint
  def masked(_key), do: "••••"
end
