defmodule PromptOnWeb.SignInHTML do
  @moduledoc """
  Templates for `PromptOnWeb.SignInController` - `sign_in_html/email.html.heex` (the email field)
  and `sign_in_html/code.html.heex` (the code field). The shell is
  `PromptOnWeb.AuthComponents.auth_page/1`, the classes are the `.auth-*` recipe in
  `assets/css/app.css` (black canvas, a centered 400px card, 40px inputs, one white primary button).

  Both templates take the assigns `@email`, `@error` (`nil` when there is none), and `@flash`.
  """

  use PromptOnWeb, :html

  import PromptOnWeb.AuthComponents

  embed_templates "sign_in_html/*"
end
