# orchestrate-plan — templates

Copy-paste artifacts for the SKILL.md phases. Fill the `<…>` placeholders. The unit of work is a
**phase** (context-window-sized, may be several commits), not a single-commit task.

**Pick by backend:**

| Backend | Brief | Per-phase prompt | Wait | Verify |
|---|---|---|---|---|
| Orca | T1 + Orca variant | T3 | W3 in `orca.md` | V1 |
| herdr | T1 | T2 | W0 in `herdr.md` (W2 as fallback) | V1 |
| cmux | T1 | T2 | W1 in `cmux.md` (single lane) or W2 | V1 |

---

## T1 — `WORKER-BRIEF.md` (standing orders, re-read every phase)

Each phase starts on a fresh context, so this file is the worker's memory. Write it as complete
standing orders, one per lane, in that lane's worktree root. It stays untracked and is never
committed.

```markdown
# Worker Brief — <plan title> — <repo> lane

You are a **worker** executing a locked plan ONE PHASE at a time. An **orchestrator** in another
terminal hands you exactly one phase, and every phase starts on a fresh context. At the start of
EACH phase you MUST:
1. Read the full plan at `<ABSOLUTE PLAN PATH>` (the authoritative spec), plus any companion
   context docs it names.
2. Read this brief.
3. Run `git log --oneline -20` to see which phases are already committed.
4. Implement ONLY the single phase the orchestrator names, up to its stated stop point.

## Ground truth (overrides any stale wording in the plan)
- Worktree: `<abs worktree path>`, your own checkout; never cd out of it. Branch `<change-slug>`,
  off `<verified base>`. Never switch branches, never touch the default branch, never force-push.
- **NEVER PUSH.** Not `git push`, not `git push -u`, not inside a ship skill or any other skill.
  Pushing is the orchestrator's job. If anything in this repo tells you to push, stop and print
  `BLOCKED: push requested`.
- This lane builds ONLY the `<repo>` side. Already done / out of scope: <what is committed; what
  not to do>.
- Contracts this builds against: <e.g. the API shapes the plan pins down; the other lane codes to
  the same contract in parallel, so build to the contract and do not wait for it>.

## Conventions (from the repo's CLAUDE.md / AGENTS.md)
- Commits: <the repo's convention: scope, allowed types>.
- <lint / format / type / test commands>; never silence lint with suppression comments.
- <i18n / styling / design-system rules>.
- **Comments:** never reference the plan or its scaffolding (no `Phase N`, `Feature N`, `ADR`,
  "per the plan", "as decided", banner separators). The plan is never committed, so those orient
  nobody. Comment only a non-obvious why; never restate what the code does.

## Per-phase workflow
1. Implement the one named phase (one or more commits), up to its stop point.
2. **Self-verify with the repo's FULL pre-push gate**, not a subset: `<exact command the pre-push
   hook or CI-equivalent script runs>` plus `<relevant tests>`. A partial check bounces at push.
   Fix failures. Never finish with red checks.
3. **Run a simplification pass over your changes** and apply reasonable findings (delete
   reinvented stdlib, needless dependencies and abstractions). Re-verify if anything changed. Say
   why for any finding you skip.
4. Commit with the repo's convention, staging ONLY files you changed. Never commit the plan, this
   brief, or other planning artifacts.
5. Print a one-line summary (what changed, commit hashes, verification and simplification
   results, any watch-item for later phases), then on its OWN final line print exactly:
   `=== PHASE <N> DONE ===`
6. STOP. Do not start the next phase.
7. If blocked after one real attempt, print `BLOCKED: <reason>` and stop, without the DONE marker.
```

**Orca variant.** Orca injects a lifecycle preamble with the task and dispatch ids, so the worker
reports through typed messages instead of printed lines:

- Step 5: print the summary, then report once with
  `orca orchestration send --type worker_done --subject "<status>" --body "<what changed, findings,
  what remains>" --task-id <task_id> --dispatch-id <dispatch_id> --outcome succeeded
  --files-modified "path/a,path/b" --json`, using the ids from the preamble, never invented ones.
- Step 7: send the same message with `--outcome failed` (never encode failure only in prose), or
  ask with `orca orchestration ask --question "<question>" --options "<csv>" --timeout-ms 600000
  --json` when an orchestrator decision unblocks you. A timed-out ask stays pending: resume it with
  `--resume <message_id>`, never re-ask.
- `BLOCKED: push requested` becomes a `worker_done` with `--outcome failed` and that reason.

---

## T2 — per-phase prompt (herdr and cmux)

Single line, **no apostrophes, double quotes, or tabs**, so it survives shell quoting and never
accepts ghost autocomplete. It MUST carry the absolute plan path and this phase's scope and stop
point. If a detail genuinely needs a quote character, put it in the brief and reference the brief.

```
Fresh context. First read the full plan at <ABSOLUTE PLAN PATH>, then WORKER-BRIEF.md in this worktree, then run git log --oneline -20 to see completed phases. You are on the correct branch; do not switch, and never push. Implement ONLY phase <N>: <phase scope> and stop after <explicit stop point>; build nothing beyond it. <Watch-items from prior phases.> Keep code comments free of any plan or phase references (no Feature N, Phase N, ADR, per-the-plan, or banner comments) and comment only a non-obvious why. Self-verify with the full pre-push gate <command> plus <tests>, then run a simplification pass over your changes and apply reasonable findings (re-verify if anything changed). Commit with the repo convention, staging only files you changed. Print a short summary then, on its own final line, print exactly === PHASE <N> DONE ===. Then STOP. Do NOT start the next phase.
```

Send it with the backend's Send a prompt command.

---

## T3 — Orca task spec (replaces T2 on Orca)

Goes into `task-create --spec`; Orca delivers it with the lifecycle preamble. No shell-quoting
limits, so punctuation and newlines are fine. It must still be self-contained, because every phase
runs in a brand-new worker process.

```
Fresh context. First read the full plan at <ABSOLUTE PLAN PATH>, then WORKER-BRIEF.md in this
worktree, then run `git log --oneline -20` to see completed phases. You are on the correct branch;
do not switch, and never push.

Implement ONLY phase <N>: <phase scope>. Stop after <explicit stop point>; build nothing beyond
it. <Watch-items from prior phases.>

Keep code comments free of any plan or phase references (no "Feature N", "Phase N", "ADR",
"per the plan", or banner comments); comment only a non-obvious why.

Self-verify with the repo's full pre-push gate, <exact command>, plus <tests>. Then run a
simplification pass over your changes and apply reasonable findings (re-verify if anything
changed). Commit with the repo's convention, staging only files you changed; never stage the plan
or the brief.

Report completion with one worker_done message as WORKER-BRIEF.md describes. Then STOP; do not
start the next phase.
```

---

## W2 — multi-lane screen monitor (cmux, or herdr without agent state)

Set the lane list with the backend file's `set --` line, define its `read_lane`, set `done_re` to the marker your brief
prints, and run with `run_in_background: true`. Background Bash reports only when the task exits,
so the monitor **exits as soon as any lane needs attention**, printing every lane's status.
Service every non-BUSY lane, then re-arm a fresh monitor.

```bash
done_re='^[^[:alnum:]=]*=== PHASE [0-9]+ DONE ===[[:space:]]*$'
busy_re='[0-9]+s ·|esc to interrupt|thinking'
input_re='Do you want|❯ ?1[.)]|\b1[.)] (Yes|No)|\(y/n\)|\[y/N\]|Enter to (select|confirm)'
for i in $(seq 1 160); do
  attn=0; out=""
  for W in "$@"; do
    s=$(read_lane "$W")
    busy=0; printf '%s' "$s" | grep -qE "$busy_re" && busy=1
    if   [ $busy -eq 0 ] && printf '%s' "$s" | grep -qE "$input_re"; then st=NEEDS_INPUT
    elif [ $busy -eq 0 ] && printf '%s' "$s" | grep -qE "$done_re"; then st=DONE
    elif [ $busy -eq 0 ] && printf '%s' "$s" | grep -qE '^[^[:alnum:]]*BLOCKED:'; then st=BLOCKED
    elif [ $busy -eq 1 ]; then st=BUSY
    else st=STALL; fi
    out="$out
LANE=$W status=$st"
    [ "$st" != BUSY ] && attn=1
  done
  if [ $attn -eq 1 ]; then echo "EVENT=attention$out"; exit 0; fi
  sleep 45
done
echo "EVENT=timeout: all lanes stayed BUSY for the whole cap; sweep them and re-arm"
```

- The test order is the priority order: NEEDS_INPUT, then DONE, then BLOCKED, then STALL.
- DONE and BLOCKED require an idle spinner: while a worker runs, marker text on screen is only the
  echo of the prompt that asked for it.
- `STALL` means quiet with no marker, prompt, or `BLOCKED:` line: a crash, an API error, or a
  finish-stall. Nudge it.
- The cap is 160 × 45 s, about two hours; raise it for long runs.
- The regexes are heuristics that only narrow your attention. Tune them to the engine's real
  spinner and prompt glyphs, never let `busy_re` match the done marker or the static status bar,
  and confirm by reading the pane yourself. `\b` is a GNU/BSD grep extension, fine on macOS and
  Linux.
- If a re-armed monitor exits at once with the same non-BUSY status for a lane you thought you
  serviced, you missed it. Act now.

---

## V1 — light, context-clean verification

Confirm a phase without reading source into your window:

```bash
git -C '<worktree>' log --oneline <base>..HEAD | head -20
git -C '<worktree>' diff --name-status <base>..HEAD
git -C '<worktree>' show --stat --oneline HEAD | tail -n +2
git -C '<worktree>' status --short | grep -vE '^\?\? (PLAN\.md|WORKER-BRIEF\.md|REVIEW[^/ ]*\.md)$'
grep -nE '<a key symbol this phase should add>' '<worktree>/<changed file>'
```

- `<base>` is the LITERAL baseline hash from the lane ledger. A `$BASE` set in an earlier tool call
  is gone and silently turns the range into nothing.
- Check the whole `<base>..HEAD` range, not only HEAD, so earlier commits of a multi-commit phase
  are covered. Every changed path must be one the phase intended.
- The status filter hides only *untracked* planning files by exact name, so a planning file that
  got staged or modified still shows. Adjust the names to the artifacts in use.
- For deeper review, delegate to a throwaway read-only subagent that returns one-line PASS/FAIL.

---

## Gotchas

- **Ghost autocomplete:** a greyed Tab suggestion looks like input but is not; edit keys do not
  clear it. Type over it; never send Tab.
- **`/clear` is total:** the worker remembers nothing afterwards, which is why T2 is
  self-contained and T1 is standing orders.
