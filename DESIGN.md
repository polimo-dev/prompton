# Design

## Source of truth
- Status: Active
- Last refreshed: 2026-09-09
- Primary product surfaces: organization and project console; use case Editor, Arena, Deployments, and Evals.
- Evidence reviewed: `app/assets/css/app.css`, `app/lib/prompt_on_web/components/ds.ex`, `app/lib/prompt_on_web/live/prompt_editor_components.ex`, `app/lib/prompt_on_web/live/integration_components.ex`, and the existing Resend-inspired design brief in the primary checkout's `design/` directory.

## Brand
- Quiet, precise developer tooling. Make actual inputs and execution state inspectable.
- Trust comes from accurate history, clear scope, and explicit empty/error states.
- Avoid decorative gradients, large marketing headings, and invented sample data presented as real data.

## Product goals
- Reduce repetitive Arena variable entry by reusing actual monitoring inputs.
- Explain each historical turn using its immutable dispatch-time prompt, typed variables, and rendered request.
- Keep manual testing available before monitoring is connected.
- Success: typing never closes the variables panel; importing a log fills matching variables without sending a request; old and failed turns remain understandable.

## Personas and jobs
- Developers compare prompt behavior across models, then deploy and monitor real calls.
- Prompt authors reproduce real inputs and inspect why a past answer differed.
- Both need compact workflows that remain usable with many variables and long prompts.

## Information architecture
- Preserve the organization/project sidebar and use case tabs.
- Arena variables contain a “Load from logs” action. A modal lists recent monitoring calls for this use case, then previews matching variables before application.
- Every Arena turn exposes “View input”. Its modal shows prompt identity, variables, template, rendered request, and model settings.
- Modal selection belongs in the URL; raw variable values and prompt content do not.

## Design principles
- Reuse stored facts; never infer original variables from rendered messages.
- Keep the user's disclosure choice stable during typing and asynchronous updates.
- Fetch sensitive content only for the selected log or turn.
- Import only matching declared variables, preserve other entered values, and never execute automatically.

## Visual language
- Existing dark canvas, hairline borders, white primary actions, and text status colors.
- Inter for UI, existing monospace font for identifiers and code.
- Reuse existing spacing and radius tokens; compact controls and scrollable content.
- No new animation, illustration, shadow system, or theme layer.

## Components
- Reuse DS modal, buttons, collapsibles, empty states, key/value rows, and code styles.
- Add focused Arena log and input inspectors using those components.
- Show selected, unavailable, empty, error, and imported states explicitly.
- Existing DS and CSS remain the token owners.

## Accessibility
- Use semantic buttons, links, labeled textareas, and native disclosures.
- Preserve keyboard focus while typing; support modal close and Escape through the existing DS.
- Keep long code horizontally scrollable and text wrapping where appropriate.
- Convey state with text, not color alone; require no motion or hover-only action.

## Responsive behavior
- Retain Arena's horizontally scrolling model columns and full-screen mode.
- Modals fit the viewport and scroll vertically; actions remain reachable on narrow screens.
- Use the same controls for touch and pointer input.

## Interaction states
- Loading: existing LiveView navigation feedback; no automatic provider call.
- Empty: explain that monitoring logs with retained variables are needed and link to integration instructions.
- Error: unavailable/expired logs cannot be applied; access is checked again when loading.
- Success: report how many matching values were applied, then return to the open variables panel.
- Older history: explicitly state that input context was not recorded; do not reconstruct it from today's prompt.
- Disabled: importing requires at least one matching variable; sending retains existing model/key/required-variable checks.

## Content voice
- Concise English product copy, sentence case, concrete verbs.
- Use “prompt”, “variables”, “monitoring logs”, “View input”, and “Load from logs” consistently.
- Do not expose database or encryption implementation details in the main user flow.

## Implementation constraints
- Phoenix LiveView, Ash authorization and project tenancy, existing DS; no new dependencies.
- List bounded log metadata, then decrypt only the selected payload. Check retention again before applying.
- Store encrypted immutable request context with nullable compatibility for older Arena messages.
- Verify typed imports, history immutability, access boundaries, disclosure behavior, and normal/full-screen browser flows.

## Open questions
- Monitoring is optional by default. A pending user preference may make it a prerequisite; no existing workflow is blocked meanwhile.
