---
name: orchestrate
description: Use when executing a locked implementation plan (PLAN.md or equivalent) that is too big for one context window — "execute the plan", "implement PLAN.md", "orchestrate this implementation", "split the plan into phases and build it". Not for edits you can finish inline.
---

# Orchestrate — execute a plan via fresh-context agents, one phase at a time

You are the **orchestrator** (manager). You do NOT write the implementation yourself.
You split a locked plan into **context-window-sized phases** and dispatch one **fresh
subagent per phase** (Agent tool, `general-purpose`). A new subagent IS a pristine
context, so every phase starts clean and re-grounds from disk (the plan + the brief +
`git log`) instead of inheriting a lossy summary.

Three non-negotiables:

1. **One phase per subagent.** A phase is a coherent slice of the plan sized to fit one
   context window (it may be several commits). Split anything bigger; cluster anything
   trivially small. Never bundle "do phase N then N+1" into one dispatch.
2. **Every phase re-grounds from disk.** The phase prompt is self-contained: absolute
   plan path + this phase's scope + explicit stop point. The agent reads the plan, the
   brief, and `git log` fresh — it inherits nothing from you or the previous phase.
3. **Keep the orchestrator's context clean.** Never read implementation source files
   into your own window. Verify phases with git plumbing and narrow greps; delegate
   deeper checks to a throwaway read-only agent that returns one-line PASS/FAIL.

**Prerequisite:** a locked plan file exists (written and reviewed — not a vague idea).
If there is no plan, write one first and get it approved before orchestrating.

## Phase 0 — Inputs

Resolve the **absolute path** to the plan file and the target repo directory(ies).
Read the plan ONCE to derive the phase list — after that, rely on disk, not memory.

## Phase 1 — Split the plan into phases (+ detect parallel lanes)

Parse the plan into an ordered list of phases. For each phase record:

- **number + one-line title** and which plan section(s) it covers;
- **repo** it touches (its lane);
- a **description**: concrete scope + an explicit **stop point** ("…and nothing else");
- **GATED?** — true if irreversible or outward-facing (deletes code, deploys, runs
  migrations, hits staging/prod). Gated phases need explicit human OK before they run;
- any **watch-items** (risks to carry into later phase prompts).

**Detect parallel lanes.** Group phases by repo. If the plan spans multiple repos that
can progress independently — each side codes to a contract the plan already pins down,
with no phase in repo A needing a not-yet-built phase in repo B — mark them as parallel
lanes and dispatch one agent per lane concurrently (multiple Agent calls in a single
message). If phases cross-depend, keep them sequential. When unsure, default to
sequential and say why.

**Track progress.** Create one todo/task per phase in execution order so progress
survives compaction. Within a lane, phases run strictly in order; at most one phase
`in_progress` per lane.

Then **present the phase breakdown + lane plan to the human and get confirmation
before dispatching anything.** If the session is running autonomously toward an
already-approved goal, state the breakdown and proceed.

## Phase 2 — Repo prep & the brief

**Pick the branch base by topology, not by label** (per repo). The branch named "main"
is sometimes stale; base on the live trunk:

```bash
git rev-list --count <labelMain>..<candidate>   # candidate ahead of labelMain?
git rev-list --count <candidate>..<labelMain>   # ...and behind?
```

For each lane:

1. **Create the feature branch** off the verified base. Never work on main/master;
   never force-push.
2. **Write `WORKER-BRIEF.md`** in that repo (template below) — standing orders every
   phase agent re-reads. Keep it untracked; it is never committed.
3. **Discover the repo's REAL pre-push gate before writing the brief** — read the
   pre-push hook / husky config / package.json scripts and put the exact full command
   into the brief's self-verify step. A brief that names a subset lets every phase pass
   locally and then bounce at push.

### Brief template (`WORKER-BRIEF.md`)

```markdown
# Worker Brief — <plan title> — <repo> lane

You are executing ONE phase of a locked plan with a fresh context. At the start you MUST:
1. Read the full plan at <ABSOLUTE PLAN PATH> (the authoritative spec).
2. Read this brief.
3. Run `git log --oneline -20` to see which phases are already committed.
4. Implement ONLY the phase named in your prompt, up to its stated stop point.

## Ground truth (overrides any stale wording in the plan)
- Repo: <abs path>. Branch: <feature-branch> (off <verified base>). Never switch
  branches; never touch main/master; never force-push.
- Already done / out of scope: <what's committed; what NOT to do>.
- Contracts this builds against: <pinned API shapes etc.>.

## Conventions (from the repo's CLAUDE.md / AGENTS.md)
- Commits: <conventional-commit rules, scopes>.
- <lint / typecheck / test commands>.
- Code comments must never reference the plan or its scaffolding (no "Phase N",
  "per the plan", banner separators). Comment only non-obvious WHY.

## Per-phase workflow
1. Implement the one named phase, up to its stop point.
2. Self-verify with the repo's FULL pre-push gate: <exact command>. Fix failures;
   never finish red.
3. Run a simplification pass over your changes (delete reinvented stdlib, needless
   abstractions) and apply reasonable findings; re-verify if you changed anything.
4. Commit (conventional message), staging ONLY files you changed. Never commit the
   plan, this brief, or other planning artifacts.
5. Return a short report: what changed, commit hash(es), verification results, any
   watch-items for later phases — then STOP. Do not start the next phase.
6. If blocked after one real attempt, report `BLOCKED: <reason>` instead.
```

## Phase 3 — The per-phase loop

For each phase, in lane order:

1. **Dispatch a fresh `general-purpose` agent** with a self-contained prompt:

   > Read the full plan at `<ABSOLUTE PLAN PATH>`, then `WORKER-BRIEF.md` in `<repo>`,
   > then run `git log --oneline -20` to see completed phases. You are on branch
   > `<branch>`; do not switch. Implement ONLY phase `<N>`: `<description>` and stop
   > after `<stop point>`; build nothing beyond it. `<Watch-items from prior phases.>`
   > Follow the brief's per-phase workflow: full pre-push gate, simplification pass,
   > conventional commit staging only files you changed. Report what changed, commit
   > hashes, and verification results. Do NOT start the next phase.

2. **On return, verify independently and lightly** — without reading source into your
   context:

   ```bash
   git log --oneline -5                         # the phase's commit(s) landed
   git show --stat HEAD | tail -n +2            # only intended files, sane sizes
   git status --short                           # nothing stray; planning docs untracked
   grep -nE '<a key symbol this phase adds>' <changed file>   # narrow spot-check
   ```

   For deeper review, spawn a throwaway read-only agent that checks the phase and
   returns one-line PASS/FAIL.

3. **Verified →** mark the phase completed, dispatch the next. **`BLOCKED:` or a bad
   report →** resolve it from the plan/brief if you safely can (fix instructions and
   re-dispatch the phase to a NEW fresh agent), else escalate to the human. Failed
   phases are re-dispatched fresh, never "continued" — the broken context is gone.

4. **GATED phase →** stop and get explicit human confirmation before dispatching it.

Parallel lanes: dispatch one phase per lane concurrently (single message, multiple
Agent calls), verify each on return, advance each lane independently.

## Hard rules

- You orchestrate; you do not implement. One phase per fresh agent, always.
- The phase agent never advances itself — only you dispatch the next phase, after
  verifying the previous one.
- Parallel only for genuinely independent repo lanes. Cross-dependent phases stay
  sequential. At most one in-flight phase per lane.
- GATE before anything irreversible or outward-facing. Don't trust branch labels;
  confirm topology. Don't fake convergence; report real failures.
- Planning artifacts (the plan, briefs, review logs) stay untracked, always.

## What NOT to do

- Don't read implementation files or full diffs into your context "just to be sure" —
  delegate verification instead.
- Don't parallelize lanes that cross-depend; don't let one lane outrun a gated step.
- Don't let a phase agent batch phases or skip its self-verification.
- Don't silently resolve a real decision on the agent's behalf — a genuine design or
  irreversibility question goes to the human.
