---
name: orchestrate-plan
description: Use when executing a locked, reviewed PLAN.md by delegating the implementation to cmux worker pane(s) ONE PHASE at a time — splitting the plan into context-window-sized phases, fully clearing the worker's context between phases, and (when the plan touches INDEPENDENT repos) running one worker pane per repo IN PARALLEL with a ~45s monitor/unblock loop. Triggers on "run the plan with a worker", "execute the plan in the other pane", "split the plan into phases and build it with workers", "build the backend and frontend in parallel panes". Builds on cmux-orchestrate. Not for edits you can finish inline, and not outside a cmux workspace (use the orchestrate skill there).
---

# Orchestrate Plan — execute a PLAN.md via fresh-context worker(s), one PHASE at a time

You are the **orchestrator** (manager). You do NOT write the implementation yourself.
You split a locked plan into **context-window-sized phases** and drive one or more **worker**
agents in separate cmux panes: feed each worker one phase at a time, **`/clear` its context
before every phase**, verify each phase, then move on — while keeping your *own* context clean
so you can run the whole plan without drowning in tool output.

When the plan touches **independent repos** (e.g. a backend `api` service + a `web`
frontend that both code to a contract the plan already fixes), run **one worker pane per repo
in parallel** and babysit them all with a single ~45s monitor loop.

Three non-negotiables:
1. **One phase per context window.** A phase is a coherent slice of the plan sized to fit one
   worker context (it may be several commits). Split anything bigger; cluster anything trivially small.
2. **Fully clear the worker before each phase** (`/clear`, never `/compact`). Every phase starts
   pristine; the worker re-grounds from disk (PLAN.md + the brief + `git log`). Strictly more
   deterministic than carrying a lossy summary.
3. **Keep the orchestrator's context clean.** Never Read worker source files or full scrollback
   into your window. Verify with git plumbing + narrow greps. Summarize to the human; never paste screens.

**Prerequisites:** a locked plan file exists (written AND reviewed — not a vague idea; if there is
no plan, write one and get it approved first). You are inside a cmux workspace — this skill drives
cmux panes; the CLI cheat sheet lives in the `cmux-orchestrate` skill (its `references/cmux-cli.md`,
resolved relative to that skill's own directory). Verbatim templates are in this skill's
`references/templates.md`.

## Worker engine — Claude Code (default) or Codex (optional)

The worker pane runs **Claude Code** (default) or **OpenAI Codex**. The user picks. Everything
about the orchestration (one phase per `/clear`, verify each phase, keep your context clean, GATE
irreversible phases, the `=== PHASE N DONE ===` marker, parallel lanes) is identical — only the
launch command and effort mechanics differ.

| | **Claude Code worker** (default) | **Codex worker** (optional) |
|---|---|---|
| Launcher (default) | `claude` | `codex -c model_reasoning_effort=medium` |
| Medium effort | `/effort medium` slash command, **re-applied after every `/clear`** (Claude reverts effort on clear) | **launch flag** `codex -c model_reasoning_effort=medium` — Codex has **no `/effort` command**; the flag is process-level so it **persists across `/clear`**. Valid: `minimal\|low\|medium\|high\|xhigh`. |
| Clear between phases | `/clear` | `/clear` (works in Codex too) |
| Perms prompts | answered by the Phase 4 monitor (NEEDS-INPUT) | answered by the Phase 4 monitor (NEEDS-INPUT) |

**The plain launch is the default.** Workers will pause on permission/approval prompts; the Phase 4
monitor loop answers them (that is what NEEDS-INPUT handling is for). Skip-permissions launchers
(`claude --dangerously-skip-permissions` / `codex --dangerously-bypass-approvals-and-sandbox`)
remove that stall but let a worker run ANY command unattended — a malicious repo instruction or
hook can then delete data or exfiltrate credentials. Use them **only with the user's explicit
opt-in**, and only in a sandboxed/disposable environment or a repo where that blast radius is
acceptable. Never pick them silently. If the user has shell aliases for these launchers, use theirs —
but check what the alias expands to first (`type claude`): a plain-looking `claude` aliased to the
skip-perms flag would silently defeat the plain-launch default.

**Effort is ALWAYS `medium` for implementation.** Building against a locked, well-specified plan
does NOT need `high`/`xhigh` — they are markedly slower for negligible gain here.

---

## Phase 0 — Gate & inputs

```bash
[ -n "$CMUX_SURFACE_ID" ] && echo "manager surface=$CMUX_SURFACE_ID" || echo "NOT in cmux — stop"
```
If not in cmux, tell the user and stop (the worker-pane model requires it; see Fallback).
Resolve inputs: **`PLAN_FILE` as an ABSOLUTE path** (the per-phase prompt hands this path to the
worker, so it must be absolute), the target repo dir(s), and read the plan (and any companion
context docs) ONCE to derive the phase list — then rely on disk, not memory.

## Phase 1 — Split the plan into phases (+ detect parallel repo lanes)

Parse the plan into an **ordered list of phases, each sized to fit ONE worker context window**
(a coherent slice — usually one feature-area or one repo's slice; may be several commits). Don't
over-fragment into one-commit micro-tasks, and don't bundle two unrelated areas into one phase.
For each phase record:
- **number + one-line title** + which plan section(s) it covers;
- **repo** it touches (the lane it belongs to);
- a **phase description**: the concrete scope + an explicit **stop point** ("…and nothing else") so
  the worker knows where this phase ends;
- **GATED?** — true if irreversible/outward-facing (deletes code, pushes, deploys, runs migrations,
  hits staging/prod). Gated phases need explicit human OK before they run;
- any **watch-items** (risks to carry forward).

**Detect parallel lanes.** Group phases by repo. If the plan spans **multiple repos that can progress
independently** — each side codes to a contract the plan already pins down (e.g. the wire shapes for
a new endpoint), with no phase in repo A needing a not-yet-built phase in repo B — mark them as
**parallel lanes: one worker pane per repo**. If phases have cross-repo ordering dependencies (B can't
start until A's API exists and isn't yet contract-frozen), keep them **sequential** (single lane, or
stage the dependent lane to start later). When unsure, default to sequential and tell the human why.

**Track progress.** Create one todo/task per phase, in execution order, so progress is visible and
survives compaction. Within a lane, wire each phase to block the next so order is enforced; phases
in *different parallel lanes* are NOT blocked on each other. If a list already exists (you were
resumed mid-run), reuse it — never duplicate.

Then **present the phase breakdown + the lane plan (sequential vs N parallel panes) to the human and
get confirmation before spawning anything** (human-led planning before fan-out — cmux-orchestrate
golden rule 7). Keep the list in lockstep with reality: mark a phase `in_progress` when you hand it
to a worker, and `completed` only after it's verified — at most one `in_progress` PER LANE.

## Phase 2 — Repo prep & spawn worker(s)

**Pick the branch base by topology, NOT by label** (per repo). The "main branch" label is often wrong;
base on the *live trunk* (recent integration commits / the code the plan references):
```bash
git rev-list --count <labelMain>..<candidate>   # candidate ahead of labelMain?
git rev-list --count <candidate>..<labelMain>   # …and behind?
```
A candidate thousands of commits ahead and zero behind IS the trunk regardless of its name.

**For EACH lane** (one repo → one pane; a single-repo plan is just one lane):
1. **Require a clean worktree and record a baseline.** `git status --porcelain` must show no
   entries except untracked planning artifacts you know about (`PLAN.md`, `WORKER-BRIEF.md`,
   review logs). Any tracked modification, staged change, or unexpected untracked file → STOP
   and ask the user to commit or stash —
   never let a worker build on top of, overwrite, or commit someone's uncommitted changes.
   Then **create the feature branch** off the verified base and, ON the new branch, record the
   baseline: `git rev-parse HEAD`. **Write the literal hash into your lane ledger/todo** — shell
   variables do NOT survive between your tool calls, so every later verification must inline the
   literal hash (never a `$BASE` you set in an earlier call, which would silently expand empty and
   turn `$BASE..HEAD` into `..HEAD`/`HEAD..HEAD`). Never work on main/master; never force-push.
2. **Write `WORKER-BRIEF.md`** in that repo (template T1). If a `WORKER-BRIEF.md` already exists
   (from an earlier run or the user's own), do NOT silently overwrite it — confirm with the user,
   or pick a distinct name and use that name consistently in T1/T2. It's standing orders the worker re-reads every
   phase (repo+branch, what's done/out-of-scope, conventions, per-phase workflow, stop points,
   the `=== PHASE N DONE ===` marker, watch-items). Keep it untracked; it is never committed.
   **Discover the repo's REAL pre-push gate before writing the brief** — read the pre-push hook /
   husky config / package.json scripts (`prepush`, `check`, knip, lint-staged) and put the exact
   full command into T1's self-verify step. A brief that names a subset (e.g. a `check` script
   without knip) lets every phase pass locally and then bounce at push.
3. **Spawn + name the pane**, capture its surface ref:
   ```bash
   W=$(cmux --json new-split right --focus false | sed -n 's/.*"surface_ref"[[:space:]]*:[[:space:]]*"\(surface:[0-9]*\)".*/\1/p')
   case "$W" in
     surface:[0-9]*) echo "worker surface: $W"; cmux rename-tab --surface "$W" "worker-<repo>" ;;
     *) echo "ABORT: no surface ref captured" ;;
   esac
   ```
   **The guard is mandatory — on ABORT, STOP: do not send ANYTHING.** If the JSON shape differs
   from what the `sed` expects, `$W` comes out empty — and an empty/omitted `--surface` targets
   YOUR OWN pane, so every later `send` (including the worker launch) would land in the manager.
   On ABORT, run `cmux --json tree` and take the new surface's ref from there instead.
   **Record the literal ref (e.g. `surface:21`) in your lane ledger and inline it in every later
   command** — shell variables don't persist between your tool calls, and an unset `$W` silently
   targets the manager (the `"$W"` in the snippets below stands for that literal ref). `surface:N`
   refs can also SHIFT as panes open/close (cmux-orchestrate golden rule 3): for long or parallel
   runs prefer durable UUIDs (`cmux --id-format uuids ...`), or re-confirm each lane's ref via
   `cmux --json tree` (match the `worker-<repo>` tab title) before targeting it — especially
   after any pane is opened or closed.
4. **Prep the shell + launch the worker** (plain launch — see the engine section for the
   skip-perms opt-in):
   ```bash
   cmux send --surface "$W" -- 'cd <repo> && <env setup e.g. nvm use>\n'
   cmux send --surface "$W" -- 'pwd\n'
   cmux read-screen --surface "$W" | tail -4        # MUST show <repo> — do not launch on a failed cd
   cmux send --surface "$W" -- 'claude\n'                              # Claude engine (default)
   # cmux send --surface "$W" -- 'codex -c model_reasoning_effort=medium\n'   # Codex engine
   ```
   Quote `<repo>` inside the worker command if the path contains spaces/metacharacters; launch the
   agent ONLY after the `pwd` check confirms the right repo.
   Confirm boot: `cmux read-screen --surface "$W" | tail -8` (agent banner + input prompt).
5. **Set `medium` effort (Claude engine only** — Codex already got it as a launch flag and has no
   `/effort` command):
   ```bash
   cmux send --surface "$W" -- '/effort medium'; cmux send-key --surface "$W" enter
   ```
   `/effort` may pop a cache-warning confirm — `send-key enter` on the highlighted "Yes". Confirm the
   bottom-right reads `● medium · /effort`. **Gotcha:** `/clear` reverts effort to the launch default,
   so re-apply `/effort medium` after every clear (Phase 3 step 2).

For parallel lanes, do steps 1–5 for each pane before starting Phase 3, so all workers are armed.

## Phase 3 — The per-phase loop (repeat per phase, per lane)

Run this loop for each lane. Lanes run **concurrently** — drive them round-robin and let the Phase 4
monitor tell you which one needs attention.

1. **Confirm idle** — `read-screen | tail -8`; no spinner.
2. **Fully clear, then re-set effort:** `cmux send --surface "$W" -- '/clear\n'`, `read-screen | tail`
   to confirm a fresh transcript (if a `/` palette shows, an extra `send-key enter` runs `/clear`).
   **Claude engine: `/clear` reverts effort — immediately re-apply** `/effort medium` + `send-key enter`;
   confirm `● medium`. (Codex engine: skip this — its launch-flag effort persists across `/clear`.)
3. **Send the per-phase prompt** (template T2). It carries **(a) the ABSOLUTE path to the full plan
   and (b) this phase's description + stop point**, so the worker reads the whole plan from disk but
   builds ONLY this phase. The prompt instructs the worker to implement the **simplest thing that
   satisfies the plan** (no speculative abstractions, no essay-length comments) and to **run a
   simplification pass over its changes before finishing** (the brief, T1, makes both a standing
   gate). It also ends with a HARD STOP: build this phase, print the done marker, and **STOP — do
   NOT begin the next phase** (the orchestrator advances the lane, not the worker).
   Because it's long, send the text THEN a *separate* Enter:
   ```bash
   cmux send --surface "$W" -- '<phase prompt text, single line, no apostrophes/double-quotes/tabs>'
   cmux send-key --surface "$W" enter
   ```
   - **Ghost autocomplete:** a greyed Tab-suggestion is NOT typed text — backspace/Esc/Ctrl+U won't
     clear it; type your prompt over it. **Never send `\t`/Tab** (it accepts the ghost).
4. **Confirm it submitted** — `read-screen | tail` shows the spinner running (not the prompt sitting in the box).
5. **Wait for idle** — single lane: arm the idle watcher (snippet W1, `run_in_background: true`).
   Multiple lanes: rely on the Phase 4 multi-pane monitor instead of one watcher per pane.
6. **On idle: confirm the phase-done marker.** Read the worker's tail
   (`read-screen --scrollback --lines 60 | tail -40`) and look for the exact line
   **`=== PHASE <N> DONE ===`**. If present, **verify independently and lightly** (snippet V1:
   `git log`, `git show --stat`, narrow `grep -n`). Do NOT Read source files into your context.
7. **Verified →** mark the phase `completed`, set the lane's next phase `in_progress`,
   loop to phase N+1 in that lane. **No marker / problem →** see Phase 4 (nudge / correct / escalate).
   **Lane out of phases →** that worker is done; leave it idle or close the pane.

## Phase 4 — Monitor & unblock loop (the babysitter; essential for parallel lanes)

**The background monitor is a WAKEUP, not ground truth.** It tells you *which lane to look at*; it
does NOT tell you what to do. On every wake — a monitor event OR your own ~45s cadence, whichever
comes first — you MUST `read-screen --surface "$W" | tail -16` **each active lane yourself** and
classify it from what you actually see, before you rest. **Never advance, idle, nudge, or skip a lane
on the monitor's label alone.** If you notice you are *waiting passively for the monitor to re-fire* —
STOP. That is the failure mode: a worker waiting on a question is a persistent *state*, not a fresh
*event*, so an edge-triggered poller can sit on it forever. Sweep the panes directly. (Walk current
refs with `cmux --json tree`.)

**Service every lane to resolution each cycle — keep a ledger.** A lane that is DONE, NEEDS-INPUT,
BLOCKED, or STALLED is **unserviced** until you act on it. Before you rest, every lane must be either
BUSY (spinner running) or serviced this cycle. The W2 monitor exits when any lane needs attention
(background Bash only reports on exit) — re-arm a fresh one after servicing; if the re-armed monitor
immediately exits with the *same* unserviced state for a lane, you missed it the first time — act now. Two lanes needing attention in the same
window is the common case (one finishes as another asks); handle them round-robin, never "I handled
one, cycle done."

Classify each lane into exactly one state and act. **Check in THIS priority order** — NEEDS-INPUT
first, because a worker awaiting input is fully stalled and burning wall-clock:

- **NEEDS-INPUT — worker is asking a question** (an "ask user"-style prompt, a clarification, a
  numbered TUI menu, a `Do you want…`/`(y/n)` confirm despite bypass, or assistant text ending in `?`
  with an empty input box and no spinner) → **highest priority, act first.** Read the actual prompt.
  If it's safely answerable from the plan / the brief / obvious convention, **pick the most appropriate
  answer and send it** to unblock (free-text `send`, or `send-key` for a TUI menu — see
  cmux-orchestrate "Answering agents in workers"). If it's a **real decision, a gated step, or
  otherwise not safely unblockable → escalate to the human** (`cmux notify` + pause that lane; keep
  its phase `in_progress`). Do not guess on irreversible/ambiguous choices. **Never let this state sit
  classified as plain "idle" — a quiet pane with a pending prompt is NOT done.**
- **DONE — `=== PHASE N DONE ===` present + idle** → verify (V1), advance that lane: `/clear` →
  re-apply effort → send next phase prompt. If the lane has no more phases, mark it complete.
- **BLOCKED — `BLOCKED:` line present** → read the reason; resolve from the plan/brief if you safely
  can, else escalate to the human. Keep the phase `in_progress`.
- **STALLED — quiet, no spinner, no DONE marker, no question, no BLOCKED** (crash, API failure, a
  "code is done" stall, or sitting idle mid-phase) → nudge: `cmux send --surface "$W" -- 'please
  continue\n'`. If it clearly lost its task (e.g. context got cleared unexpectedly), re-send the phase
  prompt instead.
- **BUSY — spinner running** → leave it; the only state that needs no action this cycle.
- **Runaway / wrong direction** → `cmux send-key --surface "$W" ctrl+c`, then redirect.

Keep looping until all lanes are complete or a hard escalation. Throughout, keep YOUR context clean
(tail reads only; never full scrollback). Surface progress to the human in a few lines, optionally via
`cmux set-progress` / `cmux notify`.

## Keeping the orchestrator's context clean (non-negotiable #3)

- Read screens with `| tail -N` (8–40 lines). Never dump full scrollback.
- Verify with `git show --stat`, `git log --oneline`, targeted `grep -n` — never `Read` whole source files.
- Trust the worker's own gates: the brief requires it to type-check + test + lint, **run a
  simplification pass and apply reasonable findings**, and self-report before printing the
  phase-done marker. You spot-check; you don't re-run everything.
- For heavy verification, spawn a throwaway read-only subagent to check a phase and return one-line
  PASS/FAIL — its file reads stay in *its* context, not yours.
- Summarize to the human; don't relay screens.

## Hard rules

- You orchestrate; you do not implement. **One phase per `/clear`** (full reset, never `/compact`);
  each phase prompt is self-contained = absolute plan path + this phase's description.
- **One phase per prompt — the worker NEVER advances itself.** Scope each prompt to exactly ONE phase
  ending at its stop point. NEVER bundle "do Phase N then Phase N+1" into one prompt, and never tell a
  worker to continue to the next phase on its own. Only the orchestrator advances a lane: verify the
  `=== PHASE N DONE ===` marker, then `/clear` and send the next phase. Self-advancing skips the verify
  step, the `/clear` reset, and the per-phase simplification/GATE checks — and burns context the reset frees.
- **Simplicity is a per-phase gate:** the worker builds the simplest thing that satisfies the plan
  (no speculative abstractions) and runs a simplification pass over its changes BEFORE the done
  marker. Long defensive comments are the smell this catches.
- The worker ends every phase by printing **exactly `=== PHASE <N> DONE ===`** so you can grep
  completion. The busy-watcher regex must match ONLY ephemeral spinner text (`[0-9]+s ·`,
  `esc to interrupt`, `thinking`) — **NEVER** the static status bar or the `=== PHASE N DONE ===`
  marker text (matching the marker fires the watcher instantly off the prompt echo). Detect the
  marker separately, after idle.
- Worker effort is **always `medium`** — on the Claude engine re-applied after every `/clear`
  (Claude reverts it); on Codex it's the launch flag and persists.
- **Parallel only for genuinely independent repo lanes.** If phases cross-depend, stay sequential.
  At most one `in_progress` phase PER LANE.
- GATE before any irreversible/outward-facing phase — explicit human confirmation. Don't trust branch
  labels; confirm topology. Don't fake convergence; report real failures. Worker stages only changed
  files; planning docs (the plan, WORKER-BRIEF.md, review logs) stay untracked.

## What NOT to do

- Don't read full files or scrollback into your context "just to be sure" — that defeats the point.
- Don't parallelize repos that actually cross-depend; don't let one lane outrun a gated step.
- Don't let a worker batch phases or skip its self-verification.
- Don't auto-answer a worker's question when it's a real/irreversible decision — escalate instead.
- **Don't wait passively for the background monitor to re-fire.** It's a wakeup, not a verdict — a
  worker stalled on a question emits no fresh event, so an edge-triggered wait sits on it forever.
  Each cycle, read every active lane's pane yourself and service all non-BUSY lanes before resting.
- Don't collapse "waiting on a question" into "idle/done." A quiet pane with a pending prompt is the
  MOST urgent state (worker fully stalled), not the least — check NEEDS-INPUT first, every cycle.

## Fallback when NOT in cmux

Use this plugin's `orchestrate` skill instead: each phase = one fresh in-session subagent (a new
subagent IS a pristine context, satisfying "clear before each phase"), and independent repo lanes =
subagents dispatched in parallel. You lose live pane visibility and mid-phase intervention, so prefer
the cmux path when available.
