# orchestrate-plan — verbatim templates

Copy-paste artifacts for the SKILL.md phases. Fill the `<…>` placeholders. The unit of work is a
**phase** (context-window-sized, may be several commits), not a single-commit task.

---

## T1 — `WORKER-BRIEF.md` (standing orders, re-read by the worker every phase)

Because the worker is `/clear`ed before each phase, this file IS its memory. Write it as complete
standing orders, not a one-time intro. Keep it untracked in the repo root. Write ONE brief per repo
lane (each parallel worker reads its own).

```markdown
# Worker Brief — <project / plan title> — <repo> lane

You are a **worker** executing a locked plan ONE PHASE at a time. An **orchestrator** in another
cmux pane clears your context before each phase and hands you exactly one phase. You start every
phase with a FRESH context, so at the start of EACH phase you MUST:
1. Read the full plan at `<ABSOLUTE PLAN PATH>` (the authoritative spec), plus any companion
   context docs it names, if present.
2. Read this brief.
3. Run `git log --oneline -20` to see which phases are already committed.
4. Implement ONLY the single phase the orchestrator names, up to its stated stop point. Do not
   start the next phase.

## Ground truth (overrides any stale wording in the plan)
- Repo: `<abs repo path>`. You are on branch `<feature-branch>` (off `<verified base>`).
  Never switch branches; never touch main/master; never force-push.
- This lane builds ONLY the `<repo>` side. Already done / out of scope: <what's committed; what NOT to do>.
- Contracts this builds against: <e.g. the API wire shapes the plan pins down; the other repo's lane
  codes to the same contract in parallel — do not wait on it, build to the contract>.

## Conventions (non-negotiable — from the repo's CLAUDE.md/AGENTS.md)
- Commits: <conventional-commit rules, required scope, allowed types>.
- <lint/format/type/test commands>; never use lint-suppression comments to silence lint.
- <i18n / styling / design-system rules>.
- **Comment discipline:** code comments must NEVER reference the plan or its scaffolding — no
  `Feature 1/2`, `Phase N`, `ADR`, `per the plan`, "as decided", or decorative section banners
  (`// ───── X ─────`). The plan is never committed, so those orient nobody and read as noise to
  whoever opens the file later. Comment ONLY non-obvious *why* (a workaround, an edge case, a
  business rule); never restate what the code plainly does. Default to fewer, shorter comments —
  no walls of comments, no banner separators. Self-documenting code over narration.

## Per-phase workflow
1. Implement the one named phase (one or more commits is fine within the phase), up to its stop point.
2. **Self-verify = the repo's FULL pre-push gate, not a subset.** Run `<prepush command — the exact
   command the repo's pre-push hook runs, e.g. `bun run prepush` (which includes knip), or
   `yarn lint && yarn typecheck && yarn test`>` plus `<relevant tests>`. A partial check
   (`bun run check` without knip, lint without types) WILL bounce at push/CI and cost a whole
   fix-up round. Fix failures. Never finish with red checks.
3. **Run a simplification pass over your changes and apply any reasonable findings**
   (delete reinvented stdlib, drop needless deps/abstractions, simplify). Re-run self-verify if you
   changed anything. Skip only findings that are clearly wrong, and say why in your summary.
4. Commit (conventional message, correct scope), staging ONLY files you changed. Do NOT commit
   the plan, this brief, or any other planning artifacts.
5. Print a one-line summary (what changed, commit hash(es), verification + simplification results,
   any watch-item for downstream phases), then on its OWN final line print exactly:
   `=== PHASE <N> DONE ===`
6. STOP. Do not start the next phase.
7. If blocked after one real attempt, print `BLOCKED: <reason>` and stop (do NOT print the DONE marker).
```

---

## T2 — per-phase prompt (sent after `/clear`; self-contained)

Single line, **no apostrophes / double-quotes / tabs** (so it survives shell quoting and won't trigger
ghost-autocomplete). It MUST contain the **absolute plan path** and **this phase's description +
stop point**. Keep `<N>` numeric.

```
Fresh context. First read the full plan at <ABSOLUTE PLAN PATH>, then WORKER-BRIEF.md in this repo, then run git log --oneline -20 to see completed phases. You are on the correct branch; do not switch. Implement ONLY phase <N>: <phase description — the concrete scope> and stop after <explicit stop point>; build nothing beyond it. <Any watch-items from prior phases.> Keep code comments compact and free of any plan or phase references (no Feature N, Phase N, ADR, per-the-plan, or banner-separator comments) and comment only non-obvious why. Self-verify with the repos FULL pre-push gate <prepush command> plus <tests>, then run a simplification pass over your changes and apply any reasonable findings (re-verify if you changed anything). Commit with a conventional message (scope <scope>), staging only files you changed. Print a short summary then, on its own final line, print exactly === PHASE <N> DONE ===. Then STOP. Do NOT start the next phase.
```

Send it, then submit with a SEPARATE Enter:
```bash
cmux send --surface "$W" -- '<the prompt above>'
cmux send-key --surface "$W" enter
cmux read-screen --surface "$W" | tail -6     # confirm spinner running
```

---

## W1 — idle watcher (single lane; background; wakes you when the worker is done or waiting)

Keys ONLY on ephemeral spinner text — never the static status bar (`✓ Bash ×N`) and **never** the
`=== PHASE N DONE ===` marker text (it sits in the prompt echo and would fire instantly). Run with
`run_in_background: true`.

```bash
busy_re='[0-9]+s ·|esc to interrupt|thinking'
idle=0
for i in $(seq 1 160); do                      # 160 * 15s = 40 min cap
  s=$(cmux read-screen --surface "$W" 2>/dev/null | tail -12)
  if printf '%s' "$s" | grep -qE "$busy_re"; then idle=0; else idle=$((idle+1)); fi
  if [ $idle -ge 3 ]; then echo "EVENT=idle :: worker quiet ~45s (phase done or waiting)"; break; fi
  sleep 15
done
echo "WATCHER_EXIT iter=$i idle=$idle"
```
After it fires, read the tail and check for `=== PHASE N DONE ===` vs `BLOCKED:` vs a question.

---

## W2 — multi-pane monitor (parallel lanes; poll all workers ~every 45s)

For 2+ lanes, poll every pane each cycle and emit each lane's CURRENT status (level, not edge — re-emit
every cycle so a persistent NEEDS-INPUT can't go stale and get dropped). Pass the surface refs in
`LANES`. Run with `run_in_background: true`. **This only flags WHICH lane to look at — it is a wakeup,
not a verdict. Always `read-screen` the specific pane yourself and re-classify before acting** (Phase 4
rule). The order of tests below IS the priority order: NEEDS-INPUT before DONE before BLOCKED before
STALL.

```bash
LANES="surface:21 surface:24"                  # one per repo lane
busy_re='[0-9]+s ·|esc to interrupt|thinking|processing'
# input_re: a worker waiting on YOU — TUI menu, confirm, or a trailing question with no spinner.
input_re='Do you want|❯ ?1[.)]|\b1[.)] (Yes|No)|\(y/n\)|\[y/N\]|Enter to (select|confirm)|? for (shortcuts|agents)'
for i in $(seq 1 160); do                      # ~40 min cap; raise for long runs
  for W in $LANES; do
    s=$(cmux read-screen --surface "$W" 2>/dev/null | tail -16)
    busy=0; printf '%s' "$s" | grep -qE "$busy_re" && busy=1
    if   [ $busy -eq 0 ] && printf '%s' "$s" | grep -qE "$input_re"; then st=NEEDS_INPUT
    elif printf '%s' "$s" | grep -qE '=== PHASE [0-9]+ DONE ==='; then st=DONE
    elif printf '%s' "$s" | grep -qE 'BLOCKED:'; then st=BLOCKED
    elif [ $busy -eq 1 ]; then st=BUSY
    else st=STALL; fi                            # quiet, no marker, no prompt → nudge (crash/finish-stall)
    echo "LANE=$W status=$st"                    # re-emitted every cycle on purpose
  done
  sleep 45
done
```
Per SKILL Phase 4 (priority order): **NEEDS_INPUT → read the prompt and answer if safe, else `cmux
notify` the human (act FIRST — the worker is fully stalled);** DONE → verify + advance; BLOCKED →
resolve or escalate; STALL → `please continue` (or re-send the phase prompt if it lost its task); BUSY
→ leave it. Keep a per-lane ledger: a lane is *unserviced* until you act; if the same non-BUSY status
re-emits twice, you missed it. The regexes only narrow your attention — confirm by reading the pane.
(`input_re`/`busy_re` are heuristics; tune them to the worker engine's actual spinner + prompt glyphs,
and never match the `=== PHASE N DONE ===` text or the static status bar.)

---

## V1 — light, context-clean verification (orchestrator side)

Confirm a phase without reading source into your window.

```bash
cd <repo>
git log --oneline -5                                # the phase's commit(s) landed
git show --stat --oneline HEAD | tail -n +2         # only intended files, sane sizes
git status --short | grep -vE 'PLAN|WORKER-BRIEF|REVIEW'   # nothing stray staged
grep -nE '<a key symbol this phase should add>' <changed file>     # narrow spot-check
```
For deeper review, delegate to a throwaway read-only subagent that returns one-line PASS/FAIL — its
reads stay in its context, not yours.

---

## Gotchas (all hard-won)

- **Ghost autocomplete:** a greyed Tab-suggestion looks like input but isn't; edit keys won't clear
  it. Type your prompt over it; never send Tab.
- **Long-paste no-submit:** a trailing `\n` in `cmux send` is often swallowed into a bracketed paste.
  Always follow with a separate `cmux send-key --surface "$W" enter`.
- **`/clear` is total:** the worker remembers nothing afterward — that's why T2 is self-contained
  (incl. the absolute plan path) and T1 is standing orders. `/clear` also reverts `/effort` to the
  launch default — re-apply `medium` after every clear.
- **Marker vs watcher:** the worker's `=== PHASE N DONE ===` line is for YOU to grep after idle; keep
  it OUT of the busy-watcher regex or it fires instantly off the prompt echo.
- **Branch label lies:** verify trunk by commit topology before branching.
