---
name: polish
description: Use when the user wants a combined quality pass over changed code — "polish the diff", "polish my changes", "clean up my changes", "run all the reviewers" — before shipping. Diff-scoped by default; accepts an optional path argument.
---

# Polish

One combined quality pass over changed code. Fan out three review lenses as
**findings-only** subagents (they read, they do not edit), merge and dedupe the
results, **auto-apply only the safe high-confidence findings**, verify the result with
the repo's own tooling, and hand back the riskier findings for the user to approve.

This is quality plus safe bug fixes, not a deep security audit.

## Why findings-only subagents

Parallel agents that edit race each other on the same files. So the subagents **only
report structured findings**, and a single orchestrator (you) applies edits
sequentially. Fan-out read, fan-in write.

## Step 1 — Resolve scope

- **No argument:** the current diff — union of `git diff --name-only` and
  `git diff --cached --name-only`. If empty, fall back to
  `git diff --name-only HEAD~1` and say you did.
- **Path argument:** review that file/directory.
- Skip files a review can't help: lockfiles, generated code, snapshots, binaries,
  vendored dirs.

If there is nothing to review, say so and stop.

## Step 2 — Fan out three lenses (parallel, findings-only)

Dispatch **three `general-purpose` subagents in a single message** so they run
concurrently. Give each the file list and require it to return **only** a JSON array
against this schema:

```json
[{
  "file": "relative/path.ts",
  "line": 42,
  "lens": "correctness | simplification | over-engineering",
  "confidence": "high | medium | low",
  "behaviorChanging": true,
  "issue": "one-line description of the problem",
  "fix": "concrete, specific proposed change"
}]
```

The three lens prompts:

1. **correctness** — "Review these changed files for correctness bugs only: logic
   errors, off-by-one, null/undefined handling, wrong conditionals, race conditions,
   incorrect error handling, broken edge cases. Do NOT report style or simplification.
   Set `behaviorChanging: true` for any fix that alters runtime behavior (most bug
   fixes do). Return findings-only JSON — do not edit files."

2. **simplification** — "Review these changed files for clarity and simplification:
   duplicated logic that could reuse existing helpers, dead flexibility, awkward
   control flow, wrong altitude, needless intermediate variables. Preserve behavior
   exactly — every fix must be `behaviorChanging: false`. Follow the repo's existing
   idioms and CLAUDE.md conventions. Return findings-only JSON — do not edit files."

3. **over-engineering** — "Review these changed files for over-engineering: reinvented
   standard-library/framework functionality, unnecessary dependencies, speculative
   abstractions, config for things with one caller, YAGNI violations. For each, say
   what to delete and what replaces it. Prefer behavior-preserving deletions. Return
   findings-only JSON — do not edit files."

Each subagent should read the repo's `CLAUDE.md`/`AGENTS.md` for local conventions
before judging.

## Step 3 — Merge & dedupe

Group findings that target the **same file and nearby lines with the same intent** into
one merged finding. Record an **agreement count** = how many distinct lenses flagged
it. Keep the clearest wording and the highest confidence in the group.

## Step 4 — Classify each merged finding

- **AUTO** (apply automatically) when **either**:
  - `confidence: high` AND `behaviorChanging: false` (mechanical, safe), OR
  - agreement count ≥ 2 AND `behaviorChanging: false` (independent corroboration).
- **REVIEW** (list, do not apply) for everything else — anything
  `behaviorChanging: true` (including correct bug fixes), uncorroborated low/medium
  confidence, anything ambiguous or touching public API/types.

The auto/review line is a **risk gate, not a quality gate**: a correct bug fix still
goes to REVIEW because auto-changing runtime behavior unseen is the dangerous case.

## Step 5 — Apply the AUTO set

Apply AUTO findings yourself with Edit, **sequentially**, one file at a time. Never
delegate the writes to parallel agents. If two AUTO findings conflict on the same
lines, apply the higher-confidence one and demote the other to REVIEW.

## Step 6 — Verify with the repo's own tooling

Do **not** hardcode a command. Discover it, in this order, and run the narrowest one
that applies to the changed files:

1. The repo's `CLAUDE.md` / `AGENTS.md` — a stated lint/typecheck/test command.
2. `package.json` scripts — prefer `typecheck` / `check` / `lint` (in that order),
   using the package manager implied by the lockfile.
3. Language defaults otherwise (`go vet ./...`, `tsc --noEmit`, `cargo check`, …).

If a check fails, identify the offending edit, revert just that edit, and move that
finding to REVIEW with a note. Re-run until clean. If no check can be found, say so
explicitly — do not claim the code is verified.

## Step 7 — Report

- **Applied (N):** each as `file:line — issue → fix`, grouped by lens, plus which
  verification command passed.
- **Needs your call (M):** the REVIEW findings, most important first. Offer to apply
  any the user picks.
- If any edit was reverted in Step 6, list it and why.

## Scope guardrails

- Only report/fix within the resolved scope — don't wander into unrelated files.
- Never `git add`, commit, or push. Leave the working tree for the user to review.
- If a lens returns malformed JSON, ask it once to reformat; if still broken, mark that
  lens as failed in the report rather than guessing.
