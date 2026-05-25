---
name: best-of-n-planned
description: >-
  Compare models on the same task with a plan-first gate: each model drafts a
  plan, the user revises via the primary agent, then all runs execute in
  parallel in isolated worktrees. Use when the user invokes /best-of-n-planned,
  asks for planned best-of-n, or wants model comparison with reviewable plans
  before implementation.
---

# best-of-n-planned

Compare models on the same task — like `/best-of-n`, but with a **plan → revise → execute** gate before any implementation.

Run the same task in parallel across multiple model picks. Keep each run fully isolated in its own git worktree during execution.

**The primary worktree must remain completely unchanged while `best-of-n-planned` is running.** Never let a candidate read/write/edit/shell/git its way through the parent checkout once a dedicated worktree exists for that repo.

**This skill does not include applying or merging** any run onto the main worktree. Never copy patches to main or re-implement the winning attempt on the parent workspace as part of best-of-n-planned.

## Input Contract

Expected format:

```
/best-of-n-planned <model_csv> <task prompt>
```

Example:

```
/best-of-n-planned opus,codex,composer pls do foobar
```

- `model_csv`: first token after `/best-of-n-planned`, split by commas.
- `task prompt`: everything after `model_csv`.
- Preserve duplicates in `model_csv` (duplicates mean independent parallel runs).

## Phases

| Phase | Who acts | What happens |
|-------|----------|--------------|
| **Plan** | Primary launches one subagent per model (parallel) | Each subagent returns a plan only — no implementation, no worktree yet |
| **Revise** | User ↔ primary | User reviews plans; primary forwards edits to the matching run(s) until plans are accepted |
| **Execute** | Primary launches one subagent per model (parallel), only after explicit user go-ahead | Same isolation rules as `/best-of-n`: `/worktree` first, then implement the finalized plan |
| **Compare** | Primary | Consolidated comparison and recommendation; **stop** — no merge to main |

Do not start the **Execute** phase until the user explicitly says to proceed (e.g. "go", "start execution", "run the plans").

## Workflow

1. Parse `model_csv` and `task prompt`.
2. If either is missing, ask the user for model CSV and task prompt.
3. Build model runs from CSV (split, trim, drop empty, preserve order and duplicates). Assign each run a stable label: `run-1`, `run-2`, … (in CSV order).
4. The primary agent is only a coordinator. It must not do repo-local file reads, edits, shell commands, or git commands in the parent checkout for the task itself.
5. **Plan phase:** Launch one `best-of-n-runner` subagent per model token **in parallel**. Each subagent is **plan-only** (see Per-Subagent Prompt Pattern). Collect all plans and present them to the user in the Plan Review Format.
6. **Revise phase:** Wait for user feedback. For each revision request, update that run's stored plan (primary is the single source of truth). Optionally re-invoke that run's subagent with the revised brief so it can refresh its plan text; do not implement yet. Repeat until the user is satisfied.
7. **Execute phase:** Only when the user gives explicit go-ahead, launch one `best-of-n-runner` subagent per model token **in parallel**, each with its **finalized plan**.
8. Each executing subagent must invoke `/worktree` first to create or attach to its own dedicated git worktree for the task, run any required worktree setup, and then do all repo-local work inside that worktree only. Do not fall back to the parent worktree.
9. If a subagent cannot get its worktree into a usable state, that run should fail and report the blocker instead of continuing in the main checkout.
10. After all executions complete: consolidated comparison and recommendation.
11. **Stop.** Do not run apply scripts or merge any run onto main.

## Primary coordinator state

Track per run (primary holds this; subagents do not share memory):

- `run_id`, `model`, `task prompt`
- `plan` (current text; updated during Revise)
- `worktree path` (filled during Execute)
- `outcome` (filled after Execute)

## Per-Subagent Prompt Pattern

Use the `best-of-n-runner` subagent type.

### Plan phase (no worktree)

- **Plan only.** Explore the codebase as needed to draft an approach; do **not** edit files, run mutating shell/git commands, or create a worktree.
- Read-only repo access in the parent checkout is allowed for planning context.
- Return a concise plan using the Plan Template below.

### Execute phase (worktree required)

- Before doing task work, first invoke `/worktree` (the worktree command) for that run. Do not hand-roll an alternative worktree flow in the parent checkout.
- After `/worktree` succeeds, stay inside that dedicated worktree for all repo-local reads, edits, shell commands, and git commands for the task.
- Until `/worktree` succeeds, do not perform repo-local reads, edits, shell commands, or git commands against the parent checkout.
- Implement **only** the finalized plan passed by the primary.
- Return the worktree path and a concise outcome.
- If worktree creation or setup fails, stop that run and report the failure. Do not continue in the primary worktree.

### Plan Template (subagent returns)

```markdown
## Approach
[2–5 sentences]

## Steps
1. ...
2. ...

## Files / modules touched
- ...

## Risks / tradeoffs
- ...

## Verification
- [tests or checks to run]
```

## Plan Review Format (primary → user)

After the Plan phase, present:

- Parsed model runs (id, model)
- One **plan block** per run (use the Plan Template sections)
- A short note that the user can request edits per run before saying to start execution

During Revise, when forwarding user edits to a subagent, include: `run_id`, model, original task prompt, user feedback, and the current plan text.

## Output Format (after Execute)

- Parsed model runs
- Final plan summary per run (one line each)
- One **result block** per run (including duplicates, plus its worktree path)
- Final comparison and recommendation
