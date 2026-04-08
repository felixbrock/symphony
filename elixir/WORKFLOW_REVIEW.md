---
tracker:
  kind: linear
  project_slug: "symphony-0c79b11b75ea"
  active_states:
    - Agent Review
    - Merging
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
    - Rework
    - Human Review
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  provider: $SYMPHONY_AGENT_PROVIDER
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
claude:
  command: claude --dangerously-skip-permissions --print --output-format stream-json --verbose --model claude-sonnet-4-6
---

You are running the **review workflow** for Linear ticket `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed review steps unless new changes require it.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets).
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent should be able to talk to Linear, either via a configured Linear MCP server or injected `linear_graphql` tool. If none are present, stop and ask the user to configure Linear.

## Role

This workflow handles only the review half of the ticket lifecycle. The implementation agent has already finished work and moved the ticket to `Agent Review`. Your job is to verify the work and route the ticket to its next state.

**Do not implement features or make unrelated changes. Do not invoke `work-linear-ticket`.**

## Related skills

- `linear`: interact with Linear.
- `review-linear-ticket`: orientation, review criteria, and routing logic for `Agent Review` tickets.
- `close-linear-ticket`: full merge+delete+Done flow when review passes; internally uses `land` for the merge step.

## Status map

- `Agent Review` -> review the prior agent's implementation and route to the appropriate next state.
- `Merging` -> implementation passed review; use `close-linear-ticket` to complete the merge, delete the remote branch, and move to `Done`.
- `Rework` -> terminal for this workflow session; implementation workflow picks it up next.
- `Human Review` -> terminal for this workflow session; human must intervene and move it back.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Agent Review` -> run the review flow (Step 1).
   - `Merging` -> use the `close-linear-ticket` skill to complete the merge, delete the remote branch, and move to `Done`.
   - `Done` / `Rework` / `Human Review` -> do nothing and shut down.

## Step 1: Review flow (Agent Review)

Open the `review-linear-ticket` skill and follow it in full. In summary:

1. **Orient** — read the Linear issue (description, all comments, prior agent's completion note), the Exec Plan if present, the branch diff against `main`, and the relevant source files. Do not rely solely on the prior agent's summary.

2. **Review** — assess against these criteria:
   - **Correctness**: does the change address the ticket's problem or requirement?
   - **Completeness**: are acceptance criteria met and obvious edge cases handled?
   - **Validation**: was meaningful validation run? If not, run it yourself.
   - **Safety**: does the change introduce regressions, security issues, or data risks?

3. **Route** — choose one outcome:

   **Resolved** — implementation is correct and complete:
   - Leave a Linear comment confirming the review outcome.
   - Use the `close-linear-ticket` skill to move the ticket through `Merging` to `Done`.

   **Not resolved** — bugs, unmet requirements, or failing validation:
   - Leave a Linear comment describing exactly what is wrong and what must be fixed (name files, behaviours, failing cases).
   - Update the Exec Plan with the identified issues and required next step.
   - Move the ticket to `Rework`.
   - Shut down.

   **Blocked on human** — completing the review requires human judgment, access, or approval the agent cannot provide:
   - Leave a Linear comment stating exactly what the human must do, why the agent cannot do it, and any command, credential, or decision needed.
   - Move the ticket to `Human Review`.
   - Shut down.

## Step 2: Merge handling (Merging)

When the ticket is in `Merging`, use the `close-linear-ticket` skill. It handles the full flow: find/create the PR, merge via the `land` skill, delete the remote branch, and move to `Done`.

## Blocked-access escape hatch

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `Human Review` with a short blocker brief that includes what is missing, why it blocks, and the exact human action needed to unblock.

## Guardrails

- Do not pick `Todo`, `In Progress`, or `Rework` tickets. This workflow only acts on `Agent Review` and `Merging`.
- Do not implement new features or expand scope.
- Do not invoke `work-linear-ticket`.
- If state is `Done`, `Rework`, or `Human Review`, do nothing and shut down.
- Do not move to `Human Review` unless a human is genuinely required to unblock — see criteria in the review flow above.
