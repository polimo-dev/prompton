defmodule PromptOnWeb.AuthComponents do
  @moduledoc """
  Shared shell for the sign-in screens (the two templates of `PromptOnWeb.SignInHTML`): a black
  canvas, the wordmark top-left, a centered 400px card, and the flash top-right. The classes are all
  the `.auth-*` recipes in `assets/css/app.css` (`design/resend-brief.md` §Logged-in app carried
  over to sign-in: the card recipe, one input plus one primary button, no banner image).

  **For dead pages (controller renders)** — the flash disappears on the next request, so there is no
  close action.
  """

  use Phoenix.Component

  @doc "Black canvas + wordmark + card. The card content is a slot."
  attr :id, :string, required: true
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def auth_page(assigns) do
    ~H"""
    <div class="auth-root">
      <.auth_flash flash={@flash} kind={:info} />
      <.auth_flash flash={@flash} kind={:error} />
      <div class="auth-brand">
        <a class="auth-wordmark" href="/">PromptOn</a>
      </div>
      <div id={@id} class="auth-card">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc "One kind of flash — rendered only when present."
  attr :flash, :map, required: true
  attr :kind, :atom, values: [:info, :error], required: true

  def auth_flash(assigns) do
    assigns = assign(assigns, :message, Phoenix.Flash.get(assigns.flash, assigns.kind))

    ~H"""
    <p
      :if={@message}
      id={"auth-flash-#{@kind}"}
      class={["auth-flash", "auth-flash-#{@kind}"]}
      role="alert"
    >
      {@message}
    </p>
    """
  end
end
