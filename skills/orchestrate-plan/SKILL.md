---
name: orchestrate-plan
description: Use when executing a locked, reviewed PLAN.md by delegating the implementation to visible worker agents in Orca, herdr, or cmux ONE PHASE at a time — splitting the plan into context-window-sized phases, giving every phase a pristine worker context, and (when the plan touches INDEPENDENT repos) running one worker per repo IN PARALLEL. Triggers on "run the plan with a worker", "execute the plan in the other pane", "split the plan into phases and build it with workers", "build the backend and frontend in parallel panes". Not for edits you can finish inline; outside Orca, herdr, or cmux use tgc-skills:orchestrate.
disable-model-invocation: true
argument-hint: "[plan-path] [agent=claude|codex]"
---

# Orchestrate Plan — execute a PLAN.md through worker agents, one phase at a time

You are the **orchestrator**. You do NOT write the implementation. You split a locked plan into
**context-window-sized phases** and drive one or more **worker** agents in other terminals: hand
each worker one phase, give it a pristine context before every phase, verify each phase, then move
on, while keeping your own context clean enough to run the whole plan.

When the plan touches **independent repos** (e.g. an `api` service and a `web` frontend that both
code to a contract the plan already fixes), run **one worker per repo in parallel** and babysit
them all from one monitor loop.

Three non-negotiables:
1. **One phase per context window.** A phase is a coherent slice sized to fit one worker context
   (it may be several commits). Split anything bigger; cluster anything trivially small.
2. **Every phase starts on a pristine worker context**: `/clear` (never `/compact`) on herdr and
   cmux, a fresh worker process on Orca. The worker re-grounds from disk (plan, brief, `git log`).
3. **Keep your own context clean.** Never Read worker source files or full scrollback. Verify with
   git plumbing and narrow greps. Summarize to the user; never paste screens.

**Prerequisites:** a locked plan (written AND reviewed; if there is none, write one and get it
approved first), and a session inside Orca, herdr, or cmux. Orca users also need Orca's own
skills: `orca skills install --skill orca-cli --skill orchestration`.

## Phase 0 — Gate, backend, inputs

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/detect-backend.sh"
```

It prints `orca`, `herdr`, `cmux`, or `none`. On `none`, tell the user and stop (see Fallback).
Otherwise read **only** this skill's `references/<backend>.md` and `references/templates.md`, run
the backend's Gate section, and use that file for every backend command below: worktree, start,
send, read, wait, answer, next phase, close.

Resolve the inputs: **`PLAN_FILE` as an ABSOLUTE path** (every phase prompt hands it to a worker),
the target repo(s), and the worker engine (`agent=claude` by default, `agent=codex` on request).
Read the plan and any companion docs ONCE to derive the phases, then rely on disk, not memory.

## Worker engine

| | Claude Code (default) | Codex (on request) |
|---|---|---|
| Launch | `claude --model sonnet --effort high` | `codex -c model_reasoning_effort=medium` |
| Effort | Launch flag; `/clear` reverts to it, so it survives every phase | Launch flag, process-level; Codex has no `/effort` |
| Fresh context | `/clear` | `/clear` |

The backend file has the exact launch for each engine. **The plain launch is the default:**
workers pause on permission prompts and Phase 4 answers them. Skip-permission launchers
(`claude --dangerously-skip-permissions`, `codex --dangerously-bypass-approvals-and-sandbox`) let a
worker run any command unattended, so a malicious repo instruction or hook can delete data or leak
credentials. Use them only on the user's explicit opt-in, in a sandboxed or disposable
environment. Never pick them silently.

If the user has shell aliases, check what they expand to first (`type claude codex`): a
plain-looking `claude` aliased to a skip-permissions flag defeats the default. Never pass a flag
the alias already sets; Codex rejects a duplicated flag and the launch dies at the shell prompt.
Confirm the banner shows the intended model and effort before sending any work.

## Phase 1 — Split the plan into phases and lanes

Parse the plan into an **ordered list of phases, each sized to ONE worker context**. Don't
over-fragment into one-commit tasks, and don't bundle unrelated areas. For each phase record:
- **number + one-line title** and the plan section(s) it covers;
- the **repo** it touches (its lane);
- the **scope** and an explicit **stop point** ("…and nothing else");
- **GATED?**: true if irreversible or outward-facing (deletes code, deploys, runs migrations, hits
  staging or prod). A gated phase needs the user's explicit OK before it runs;
- **watch-items**: risks to carry into later phase prompts.

**Detect parallel lanes.** Group phases by repo. Repos that progress independently, each coding to
a contract the plan already pins down, become **parallel lanes, one worker per repo**. If a phase
in repo B needs a not-yet-built phase in repo A, keep them sequential or start lane B later. When
unsure, stay sequential and say why.

**Track progress.** One todo per phase, in execution order; inside a lane each phase blocks the
next, and lanes do not block each other. On Orca the backend file turns this into tasks with
`--deps`. If a list already exists because you were resumed, reuse it.

**Name the change, not the run.** Derive ONE kebab-case **change slug** from the plan's goal, two
to five words saying what the branch delivers (`invoice-pdf-export`, `oauth-token-refresh`). Every
branch and worktree uses it, and every lane shares it, so the pieces of one change stay
recognizable across repos. Two lanes in the SAME repo get `<slug>-<what-differs>`. Never name a
branch after the machinery (`lane-*`, `worker-*`, `phase-*`, the repo name, the plan file). Pane
and tab titles are the exception: `lane-<repo>` is right there. A branch name in the plan wins; a
name from the user wins over both.

Present the phase list and the lane plan (sequential or N parallel workers) and **get the user's
confirmation before starting any worker.** Mark a phase `in_progress` when you hand it over and
`completed` only after V1 passes; at most one `in_progress` per lane.

## Phase 2 — Repo prep and workers

**Pick the base by topology, not by label.** Resolve the default branch with
`gh repo view --json defaultBranchRef --jq .defaultBranchRef.name` and fetch it. If the plan names
another base, compare it with `git rev-list --count A..B` in both directions; a candidate far ahead
and zero behind is the live trunk whatever its name.

For EACH lane:
1. **Require a clean repo.** `git status --porcelain` shows nothing but known untracked planning
   files. Anything else → stop and ask the user to commit or stash. Run `git config push.default`;
   if it prints `upstream`, set it to `current` for this repo, since `upstream` sends a plain push
   to whatever the branch tracks.
2. **Create the lane worktree and branch** per the backend file: from the freshly fetched base,
   named with the change slug, created `--no-track` (or upstream unset afterwards). One worktree
   per lane is the default: dev servers and watchers run from the user's primary checkout, and a
   worker there would live-mutate what they serve. Work in the primary checkout only when the user
   says so and nothing long-running serves from it. A worktree does not protect the remote; the
   push rules still apply.
3. **Record the baseline.** `git -C '<worktree>' rev-parse HEAD`, written as the LITERAL hash into
   the lane ledger along with the worktree path and the worker handles. Shell variables do not
   survive between your tool calls.
4. **Write the brief.** Find the repo's REAL pre-push gate first (pre-push hook, husky, project
   scripts) and put the exact full command in it; a subset passes locally and bounces at push. Then
   write T1 as `WORKER-BRIEF.md` in the worktree root, untracked.
5. **Start the worker** per the backend file and confirm the model and effort it reports.

For parallel lanes, prepare every lane before Phase 3 so all workers are armed.

## Phase 3 — The per-phase loop (per lane; lanes run concurrently)

1. **Confirm idle** with the backend's read.
2. **Fresh context** for every phase after the first: the backend's Next phase section.
3. **Hand over the phase**: T2 through the backend's send on cmux, and through W0 on herdr,
   which sends and waits in one call; on Orca, the
   backend's start puts a fresh worker on the phase's T3 task. The prompt carries the absolute plan path and ONE phase's scope
   and stop point, tells the worker to build the simplest thing that satisfies the plan, run a
   simplification pass before finishing, print the done marker (Orca: `worker_done`), and STOP.
4. **Confirm it started**: a spinner or `working` state, not the prompt sitting in the input box.
5. **Wait** with the backend's wait (W0, W1, W2, or W3).
6. **On settle, classify** (Phase 4). On DONE, verify with V1 without reading source.
7. **Verified** → mark the phase completed and move the lane to its next phase. **Lane out of
   phases** → the backend's Close.

## Phase 4 — Monitor and unblock

**A wait or monitor return is a wakeup, not a verdict.** On every wake, read each active lane
yourself and classify what you actually see. A worker waiting on a question is a persistent state,
not a fresh event, so a monitor can sit on it forever; if you catch yourself waiting for one to
re-fire, sweep every lane now. Keep a ledger: before you rest, every lane is BUSY or serviced this
cycle. Two lanes needing you in the same window is normal; handle them all.

Check in this priority order:

- **NEEDS-INPUT**: a permission dialog, a numbered menu, a `(y/n)`, or a question with an empty
  input box. Act first: the worker is fully stalled. If the plan, the brief, or obvious convention
  answers it, answer with the backend's Answer section. Deny any push, merge, or action outside the
  lane's scope. A real decision, a gated step, or anything irreversible → escalate to the user,
  pause the lane, and keep its phase `in_progress`. A quiet lane with a pending prompt is never
  DONE.
- **DONE**: the done marker (Orca: `worker_done`) and idle → V1, then advance the lane.
- **BLOCKED**: a `BLOCKED:` line (Orca: `--outcome failed` or an escalation) → resolve from the plan
  or brief if you safely can, else escalate.
- **STALLED**: quiet with no marker, question, or `BLOCKED:` → send `please continue`. If it lost
  its task, re-send the phase prompt.
- **BUSY**: working → leave it.
- **Runaway or wrong direction** → interrupt it (the backend's Answer section), then redirect.

Loop until every lane is complete or a hard escalation. Report progress in a few lines.

## Phase 5 — Ship the lanes

When every lane is verified, ask the user once: "all <N> lanes verified, ship them?". On yes, ship
each lane yourself. First delete the lane's untracked brief (`rm '<worktree>/WORKER-BRIEF.md'`)
and require `git -C '<worktree>' status --porcelain` to print nothing, because ship refuses a
dirty tree. Then one fresh `general-purpose` subagent per lane reads and follows
`${CLAUDE_PLUGIN_ROOT}/skills/ship/SKILL.md` from that lane's worktree. Ship is explicit-only, so
it cannot be invoked as a skill, and a read file keeps its placeholders: tell the subagent to
replace each `CLAUDE_PLUGIN_ROOT` placeholder in it, and in every plugin file it points to, with `${CLAUDE_PLUGIN_ROOT}`. Its output stays out of your context. **At most 2 ships at a time**; queue the
rest. Relay every PR URL and review outcome in one final report. Workers never run ship: a ship
started in a worker races the orchestrator's push.

## Keep your context clean

- Read screens with `| tail -N` (8–40 lines), never full scrollback.
- Trust the worker's own gates (full pre-push gate, simplification pass, self-report); spot-check,
  don't re-run everything.

## Hard rules

- You orchestrate; you do not implement. Never hand-edit a lane's worktree.
- **One phase per prompt; the worker never advances itself.** Never bundle "phase N then N+1";
  only you advance a lane, after V1.
- On herdr and cmux the worker ends every phase with exactly `=== PHASE <N> DONE ===`. Keep that
  text out of any busy regex. Match it as a whole line, allowing only the agent's bullet or indent
  before it (`^[^[:alnum:]=]*=== PHASE [0-9]+ DONE ===[[:space:]]*$`), because the echoed prompt quotes it
  mid-line.
- **Workers NEVER push.** The brief tells them to print `BLOCKED: push requested` instead. Pushing
  happens after the Phase 5 gate, through `tgc-skills:ship`. Any push you make yourself uses an
  explicit refspec, `git push origin HEAD:refs/heads/<lane branch>`, never a bare `git push` whose
  destination depends on tracking and `push.default`.
- If anything reaches a protected or default branch anyway: restore it with a pushed `git revert`
  (never force-push shared history), rebuild the feature branch on top of the revert, and tell the
  user immediately.
- GATE before anything irreversible or outward-facing. Don't fake
  convergence; report real failures. Planning files (the plan, the brief, review logs) stay
  untracked.

## Fallback

On `none`, tell the user and stop. Suggest `/tgc-skills:orchestrate` instead: each phase becomes
one fresh in-session subagent (a new subagent is a pristine context), and independent lanes run as
parallel subagents. It loses live visibility and mid-phase intervention, so prefer a real backend
when one is available.
