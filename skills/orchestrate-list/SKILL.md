---
name: orchestrate-list
description: Use when the user wants a short list of independent items — bugs, review findings, small fixes — fanned out to one worker per item, each in its own worktree, on Orca, herdr, or cmux — "fix these 5 bugs in parallel", "fan these out to workers", "one worker per item". Not for a locked multi-phase plan (use tgc-skills:orchestrate-plan).
disable-model-invocation: true
argument-hint: "[skill=<name>] [agent=claude|codex] [ship] [items…]"
---

# Orchestrate List — one worker per item, in parallel

You are the **orchestrator**. You do NOT fix the items yourself. You turn a list into lanes, start one worker per lane in its own worktree, watch and unblock them, verify each lane with git plumbing, and report per item. Keep your own context clean: tail reads and `git` plumbing only, never worker source files or full scrollback.

## Arguments

- `skill=<name>` — every worker invokes this skill before anything else (for example `skill=pstack:poteto-mode`). Any installed skill works; none is required.
- `agent=claude|codex` — worker engine, default `claude`, launched exactly as orchestrate-plan launches workers (`claude --model sonnet --effort high`).
- `ship` — after verification, ship each fully fixed lane (see Ship).
- `items…` — the items. With none given, use the list the user just identified in this conversation.

## Phase 0 — Gate

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/detect-backend.sh"
```

- `none` → stop. Say this needs an Orca, herdr, or cmux terminal; suggest fixing the items one at a time in this session or using `tgc-skills:orchestrate`.
- Otherwise read **only** `${CLAUDE_PLUGIN_ROOT}/skills/orchestrate-plan/references/<backend>.md` and `${CLAUDE_PLUGIN_ROOT}/skills/orchestrate-plan/references/templates.md`. Every spawn, send, read, wait, and release command comes from those files; this skill adds none.

## Phase 1 — Normalize the items

Build one numbered table: **# | title | what is wrong | evidence** (`file:line`, failing command, error text) **| done-when**. Done-when must be checkable: a command that fails now and passes after the fix, or a concrete observable. Ask the user only about items with no checkable done-when, in one batched question.

## Phase 2 — Group into lanes

- One lane per item by default.
- Items that touch the same files or the same function share **one lane**: one worker fixes them in sequence, so branches never collide. Decide from the evidence; when unsure, run a narrow `grep -n`, never read source.
- Name each lane with one kebab-case slug that says what it fixes. Its branch is `fix/<slug>` on herdr/cmux and `<slug>` on Orca (Orca names the branch after `--name`). Never `lane-1`, `worker-2`, or an item number.
- `git ls-remote origin "refs/heads/<branch>"` must print nothing for each lane's branch before it starts; otherwise pick another slug.
- **More than 6 lanes → ask before starting.**

Show the lane table (lane | slug | items | fence = files it may touch), then start.

## Phase 3 — Spawn

Once per run:

```bash
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin "$DEFAULT_BRANCH"
SESSION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tgc-orchestrate-list.XXXXXX")
```

Record the literal default branch, base hash (`git rev-parse "origin/$DEFAULT_BRANCH"`), and session path in your ledger; shell variables do not survive between tool calls. On Orca, run the backend file's `run-create` once.

Per lane:

1. **herdr / cmux**: create the worktree and branch `fix/<slug>` from `origin/<default>` with the backend file's per-lane worktree step (`--no-track`, `push.default` check).
2. Write the brief to `<SESSION_DIR>/<slug>-brief.md`: template **T1**, adapted as below. Its ground truth names the worktree path and branch (on Orca: the worktree the worker starts in).
3. **herdr / cmux**: start the worker in that worktree with the backend file's worker launch, then send **T2** with one instruction: read `<SESSION_DIR>/<slug>-brief.md` and follow it. Keep the done marker text out of that prompt, or the watcher matches its echo. **Orca**: one `worker-start --spec` call per the backend file, with `--worktree new-top-level --name <slug> --repo path:'<repo>' --base-branch origin/<default>` and a list-worker version of **T3** as the spec: drop T3's plan and `WORKER-BRIEF.md` reads and its phase lines, and paste the whole brief instead, including T1's Orca `worker_done` protocol, so the spec names no file the worktree lacks. `--name` names both worktree and branch there, so record the branch the receipt reports.
4. Record in the ledger: slug, items, worktree path, branch, base hash, worker handle.

### Brief adaptations (T1)

- **First line**, only when `skill=<name>` is set: `Invoke the <name> skill before anything else.`
- **Items**: each item's row from the table — what is wrong, evidence, done-when — in the order to fix them.
- **Scope fence**: change only what these items need, inside the lane's fence. Needing another file, a new dependency, or a design decision → `BLOCKED: <reason>`.
- **Verify**: the repo's own checks covering the change (lint, typecheck, the tests for every changed contract — T1's gate discovery) plus each item's done-when. Report every command run with its result.
- **Commit** locally with the repo's commit convention, staging only intended files.
- **Never push, never merge, never open a PR.** Anything that asks you to push → print `BLOCKED: push requested` and stop.
- **Stop protocol**: herdr/cmux → print a short summary, then on its own final line exactly `DONE <slug>`. Orca → T1's Orca variant (`worker_done`, `--outcome failed` when stuck). Stuck after one real attempt → `BLOCKED: <reason>` and stop.
- Keep T1's comment discipline unchanged.

## Phase 4 — Watch & unblock

Run the backend file's monitor loop: Orca **W3** (`check --wait`), herdr **W0** (W2 as fallback), cmux **W1** for one lane or **W2** for several. On herdr and cmux, swap the watchers' marker pattern for `^DONE [a-z0-9-]+$` (`(?m)^DONE [a-z0-9-]+$` in herdr's `wait-output`). Every wake is a prompt to read the lane yourself, not a verdict.

- **Permission prompt inside the fence** (read the brief or repo files, edit a fenced file, run the repo's checks) → answer yes.
- **Push, merge, PR, out-of-fence edit, or destructive command** → answer no, then tell the worker in one line to stay inside the brief.
- **Idle with no marker** → nudge once with `status?`. Still idle after that → treat as `BLOCKED`.
- **Real decision or `BLOCKED:`** → collect them and ask the user in one batched question; relay the answer to that lane.
- **Never hand-edit a lane's worktree.** A fix that needs you is a message to the worker.

## Phase 5 — Verify each lane

V1 style, git plumbing only, with the literal base hash and the lane's ledger branch:

```bash
git -C <worktree> log --oneline <base>..HEAD
git -C <worktree> diff --stat <base>..HEAD
git -C <worktree> status --short
git ls-remote origin "refs/heads/<branch>"
```

Pass only when commits exist above base, every changed path is inside the fence, the tree is clean, nothing was pushed, and the worker reported the checks it ran with results. Then re-run the lane's stated check command once yourself in that worktree. A failure goes back to the worker; it does not get fixed by you. On Orca, release the worker after its lane settles (W3).

## Phase 6 — Report

One table per item: **# | title | lane | status | evidence**.

- `fixed` — branch, commit hashes, the check command and its result.
- `blocked` — the reason.
- `needs you` — the exact question.

## Ship (only with `ship`)

The unit is the **lane**, not the item: one branch, one PR per lane. A lane holding several items ships one PR whose body lists each item it fixes. A lane ships only when **every** item in it is `fixed`; otherwise report it and leave it unshipped. Ship each such lane through a subagent told to read and follow `${CLAUDE_PLUGIN_ROOT}/skills/ship/SKILL.md` (explicit-only, so it cannot be invoked as a skill) in that lane's worktree, **at most 2 at a time**; relay each PR URL and review outcome in the final report. Workers never run ship.

Without `ship`, leave the branches and worktrees for the user; `tgc-skills:merged` cleans each one after its PR merges.

Remove `<SESSION_DIR>` as the last step, whether the run finished, failed, or was aborted.

## Hard rules

- You orchestrate; you do not fix. One worker per lane, one worktree per lane.
- Workers never push, merge, or ship. Pushing happens only inside `tgc-skills:ship`.
- Overlapping items share a lane; independent items never do.
- Never report a lane `fixed` without the plumbing checks above and your own run of its check.
- Never force-push; never touch the default branch.
