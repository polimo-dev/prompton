defmodule PromptOnWeb.UseCasesLive do
  @moduledoc """
  Use case list (`/:org_slug/:project_slug/use-cases`, mockup `s_usecases.jsx` UseCasesScreen).

  All screen state travels in the URL as **query parameters** (CLAUDE.md zero-downtime deployment
  discipline):

  - `?q=` — key filter (debounced `phx-change` → `push_patch`)
  - `?new=1` — the "Define use case" modal

  When a deploy drops the socket and remounts, the user comes back to the same filter and the same
  modal.

  The list is drawn with three queries: the use cases once (including the `prompt_count`
  aggregate), the live Deployments of the production environment once (not per row), and the model
  catalog once (the names of the models the deployments point at). Everything else is an assign
  `LiveProjectScope` already provided.

  Clicking a row goes to the **use case hub** (`/use-cases/:key/prompt`), where the model · prompt ·
  arena · deployments all live.
  """
  use PromptOnWeb, :live_view

  import PromptOnWeb.UseCaseComponents

  alias PromptOn.Catalog
  alias PromptOn.Deployments
  alias PromptOn.Prompts
  alias PromptOn.Prompts.UseCase

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Use Cases · #{socket.assigns.project.slug}",
       q: "",
       form: nil
     )
     |> load_use_cases()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:q, filter_param(params["q"]))
     |> assign_form(params["new"])}
  end

  # The URL is a shared contract, so the screen must come up whatever arrives: `?q[]=x` decodes as
  # a list.
  defp filter_param(q) when is_binary(q), do: q
  defp filter_param(_q), do: ""

  @impl Phoenix.LiveView
  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply,
     push_patch(socket, to: list_path(socket.assigns.org_slug, socket.assigns.project, q))}
  end

  def handle_event("validate", %{"use_case" => params}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"use_case" => params}, socket) do
    params = Map.put(params, "name", display_name(params["key"]))

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, use_case} ->
        {:noreply,
         socket
         |> put_flash(:info, created_flash(use_case))
         |> push_navigate(
           to: created_path(socket.assigns.org_slug, socket.assigns.project, use_case)
         )}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  # Once defined, go straight to the **use case hub**: whatever the kind, everything to do next is
  # there. (`:embedding` has no prompt to write, so the hub shows only the model and Deploy.)
  defp created_path(org_slug, project, use_case),
    do: ~p"/#{org_slug}/#{project.slug}/use-cases/#{use_case.key}/prompt"

  defp created_flash(%{kind: :embedding} = use_case),
    do: "Use case #{use_case.key} defined — add models, then deploy."

  defp created_flash(_use_case),
    do: "Use case created — add models, write the prompt, then deploy."

  # ---------------------------------------------------------------------------
  # Data

  defp load_use_cases(socket) do
    project = socket.assigns.project
    actor = socket.assigns.current_user
    opts = [tenant: project.id, actor: actor]

    use_cases =
      case Prompts.list_use_cases(Keyword.put(opts, :load, [:prompt_count])) do
        {:ok, list} -> Enum.sort_by(list, & &1.key)
        {:error, _error} -> []
      end

    assign(socket,
      use_cases: use_cases,
      production: production_summary(socket.assigns.envs, opts)
    )
  end

  # Read the production environment's live deployments **once** and fold them into use_case_id →
  # `%{revision:, model:, extra:}` (`current_for_environment` returns one row per use case, its
  # highest revision). Querying per row would be N queries. Model names come from reading the
  # catalog once and attaching id → display_name.
  defp production_summary(envs, opts) do
    with %{id: env_id} <- Enum.find(envs, &(&1.slug == "production")),
         {:ok, deployments} <- Deployments.current_deployments_for_environment(env_id, opts) do
      names = model_names(opts)
      Map.new(deployments, &{&1.use_case_id, deployment_summary(&1, names)})
    else
      _other -> %{}
    end
  end

  defp model_names(opts) do
    case Catalog.list_models(opts) do
      {:ok, models} -> Map.new(models, &{&1.id, &1.display_name})
      {:error, _error} -> %{}
    end
  end

  # A revision is a **pin** (ADR 0007 revision 2026-09-01): all that fits on one line is the
  # revision number, the one pinned model and the number of pinned prompts (with a single prompt
  # the count is not stated; that is the usual case).
  defp deployment_summary(deployment, names) do
    %{
      revision: deployment.revision,
      model: Map.get(names, deployment.model_id) || "unknown model",
      prompts: map_size(deployment.prompt_pins || %{})
    }
  end

  defp filtered(use_cases, ""), do: use_cases

  defp filtered(use_cases, q) do
    needle = String.downcase(q)
    Enum.filter(use_cases, &String.contains?(String.downcase(&1.key), needle))
  end

  # ---------------------------------------------------------------------------
  # Modal form

  defp assign_form(socket, nil), do: assign(socket, :form, nil)

  defp assign_form(socket, _new) do
    if socket.assigns[:form], do: socket, else: assign(socket, :form, build_form(socket))
  end

  defp build_form(socket) do
    UseCase
    |> AshPhoenix.Form.for_create(:define,
      domain: PromptOn.Prompts,
      as: "use_case",
      actor: socket.assigns.current_user,
      tenant: socket.assigns.project.id,
      params: %{"kind" => "chat"}
    )
    |> to_form()
  end

  # `name` is required but the mockup modal asks only for the key, so the key is turned into a
  # human-readable name to fill it.
  defp display_name(key) when is_binary(key) do
    case String.trim(key) do
      "" -> "Use case"
      trimmed -> trimmed |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp display_name(_key), do: "Use case"

  # ---------------------------------------------------------------------------
  # Paths

  defp list_path(org_slug, project, q) do
    if q in [nil, ""] do
      ~p"/#{org_slug}/#{project.slug}/use-cases"
    else
      ~p"/#{org_slug}/#{project.slug}/use-cases?#{[q: q]}"
    end
  end

  defp new_path(org_slug, project, q) do
    params = if q in [nil, ""], do: [new: 1], else: [q: q, new: 1]
    ~p"/#{org_slug}/#{project.slug}/use-cases?#{params}"
  end

  defp cols do
    [
      %{label: "key", w: "1.6fr"},
      %{label: "kind", w: "84px"},
      %{label: "variables", w: "1fr"},
      %{label: "prompts", w: "70px", align: "right"},
      %{label: "live in production", w: "200px"},
      %{label: "", w: "30px"}
    ]
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :rows, filtered(assigns.use_cases, assigns.q))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      org_slug={@org_slug}
      project={@project}
      projects={@projects}
      organization={@organization}
      organizations={@organizations}
      nav={:usecases}
    >
      <DS.screen
        id="use-cases-screen"
        title="Use Cases"
        sub="LLM call sites in the app"
        max_w={1000}
      >
        <:crumb label={Layouts.org_label(@organization)} navigate={~p"/#{@org_slug}"} />
        <:crumb label={@project.slug} />
        <:actions>
          <form phx-change="filter" phx-submit="filter" id="use-case-filter-form">
            <DS.ds_input
              id="use-case-filter"
              name="q"
              value={@q}
              placeholder="Filter by key…"
              icon="search"
              mono
              w={200}
              phx-debounce="200"
              autocomplete="off"
            />
          </form>
          <DS.btn_link
            id="new-use-case"
            variant="primary"
            icon="plus"
            patch={new_path(@org_slug, @project, @q)}
          >
            Define use case
          </DS.btn_link>
        </:actions>

        <%= if @rows == [] do %>
          <DS.empty
            id="use-cases-empty"
            icon="target"
            title={if @q == "", do: "No use cases yet", else: "No matching use case"}
            sub={
              if @q == "",
                do: "Define one use case for every place your app calls an LLM.",
                else: "No key matches the filter \"#{@q}\"."
            }
          >
            <:action>
              <DS.btn_link variant="primary" icon="plus" patch={new_path(@org_slug, @project, @q)}>
                Define use case
              </DS.btn_link>
            </:action>
          </DS.empty>
        <% else %>
          <DS.table id="use-cases-table" cols={cols()}>
            <DS.row
              :for={{uc, i} <- Enum.with_index(@rows)}
              id={"use-case-#{uc.key}"}
              cols={cols()}
              index={i}
              navigate={~p"/#{@org_slug}/#{@project.slug}/use-cases/#{uc.key}/prompt"}
            >
              <span style="display:flex;align-items:center;gap:8px;min-width:0;">
                <DSIcons.icon name={kind_icon(uc.kind)} size={13} class="tx3" />
                <span
                  class="font-mono"
                  style="font-size:13.5px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;"
                >
                  {uc.key}
                </span>
                <DS.badge :if={log_only?(uc)} tone={:neutral} style="font-size:10px;">
                  LOG ONLY
                </DS.badge>
              </span>
              <DS.badge
                tone={if uc.kind == :chat, do: :accent, else: :neutral}
                mono
                style="font-size:10.5px;"
              >
                {uc.kind}
              </DS.badge>
              <.variable_chips variables={uc.input_schema} limit={3} />
              <span class="font-mono" style="font-size:12.5px;text-align:right;color:var(--tx-1);">
                {count_text(uc.prompt_count)}
              </span>
              <span
                id={"use-case-live-#{uc.key}"}
                class="font-mono"
                style="font-size:12.5px;color:var(--tx-1);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;"
              >
                {deployment_text(@production[uc.id])}
              </span>
              <span style="display:flex;justify-content:flex-end;">
                <DSIcons.icon name="chevRight" size={13} class="tx3" />
              </span>
            </DS.row>
          </DS.table>
        <% end %>

        <DS.modal
          :if={@form}
          id="define-use-case-modal"
          on_close={list_path(@org_slug, @project, @q)}
          title="Define use case"
          icon="target"
        >
          <.form for={@form} id="define-use-case-form" phx-change="validate" phx-submit="save">
            <.field_label>key</.field_label>
            <DS.ds_input
              id="use-case-key"
              field={@form[:key]}
              placeholder="support_reply"
              mono
              phx-debounce="200"
              autocomplete="off"
            />
            <.field_error field={@form[:key]} />

            <div style="margin-top:14px;">
              <.field_label>kind</.field_label>
              <.seg_radio
                id="use-case-kind"
                name="use_case[kind]"
                value={@form[:kind].value}
                options={[{"chat", "chat"}, {"text", "text"}, {"embedding", "embedding"}]}
              />
            </div>
          </.form>

          <:footer>
            <span style="font-size:12.5px;color:var(--tx-2);margin-right:auto;">
              key must be unique within the project
            </span>
            <DS.btn_link variant="ghost" patch={list_path(@org_slug, @project, @q)}>Cancel</DS.btn_link>
            <DS.btn
              id="submit-use-case"
              variant="primary"
              icon="check"
              type="submit"
              form="define-use-case-form"
            >
              Define
            </DS.btn>
          </:footer>
        </DS.modal>
      </DS.screen>
    </Layouts.app>
    """
  end

  defp count_text(0), do: "—"
  defp count_text(nil), do: "—"
  defp count_text(n), do: to_string(n)

  # The one-line "what runs in production right now": revision number + pinned model (and the
  # count when there are several prompts).
  defp deployment_text(nil), do: "not deployed"

  defp deployment_text(%{revision: revision, model: model, prompts: prompts})
       when prompts > 1,
       do: "##{revision} · #{model} · #{prompts} prompts"

  defp deployment_text(%{revision: revision, model: model}),
    do: "##{revision} · #{model}"
end
