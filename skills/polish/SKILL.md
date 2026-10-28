---
name: polish
description: Use only when the user explicitly asks for a combined quality pass over changed code, or when the active ship workflow invokes it — "polish the diff", "polish my changes", "clean up my changes", "run all the reviewers". Diff-scoped by default; accepts an optional path or commit range and a subset of lenses.
argument-hint: "[path|commit-range] [lenses=correctness,simplify,overeng]"
---

# Polish

One combined quality pass over changed code. Fan out three review lenses as
**findings-only** subagents (they read, they do not edit), merge and dedupe the
results, **auto-apply only the safe high-confidence findings**, verify the result with
the repo's own tooling, and hand back the riskier findings for the user to approve.

Proceed only when the surrounding user request explicitly asks for polishing (including
direct `/tgc-skills:polish` invocation) or `tgc-skills:ship` invokes it. Do not load this
skill from unrelated requests because polishing can edit files.

This is quality plus safe bug fixes, not a deep security audit.

## Why findings-only subagents

Parallel agents that edit race each other on the same files. So the subagents **only
report structured findings**, and a single orchestrator (you) applies edits
sequentially. Fan-out read, fan-in write.

## Step 1 — Resolve scope

- **No argument:** the current work — union of `git diff --name-only`,
  `git diff --cached --name-only`, and untracked files from
  `git ls-files --others --exclude-standard`. If all are empty, fall back to
  `git diff --name-only HEAD~1` and say you did.
- **Path argument** (`src/components`): review that file/directory.
- **Range argument** (`abc123..HEAD`): review the files from
  `git diff --name-only <range>` and the changes in that range. Use it for work that is
  already committed, such as commits a review loop made.
- **`lenses=`** (`lenses=simplify,overeng`): run only the named lenses —
  `correctness`, `simplify`, `overeng`. The rest of the flow is unchanged. An unknown
  name → stop and list the valid ones.
- Skip files a review can't help: lockfiles, generated code, snapshots, binaries,
  vendored dirs.

If there is nothing to review, say so and stop.

## Step 2 — Fan out the lenses (parallel, findings-only)

Dispatch **one `general-purpose` subagent per lens in a single message** so they run
concurrently. Run the correctness lens on the session model and the simplification and
over-engineering lenses with `model: sonnet`. Give each the file list, the scope, and its
own output path from `mktemp "${TMPDIR:-/tmp}/polish-<lens>.XXXXXX"`. Each lens writes
**only** a JSON array against this schema to that path and replies with the path alone,
because long replies arrive truncated:

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
   fixes do). Write the findings JSON to your output path — do not edit source files."

2. **simplification** — "Review these changed files for clarity and simplification:
   duplicated logic that could reuse existing helpers, dead flexibility, awkward
   control flow, wrong altitude, needless intermediate variables. Preserve behavior
   exactly — every fix must be `behaviorChanging: false`. Follow the repo's existing
   idioms and CLAUDE.md conventions.

   Comments are part of this lens. The repo's `CLAUDE.md`/`AGENTS.md` comment rules
   win. Where the repo states none, report every comment that restates what the code
   does, narrates the change ('now we handle X'), refers to a plan, phase, or review
   round, or annotates a config, schema, constant, or enum entry. Propose deleting it,
   or compacting a multi-line comment to the one-line non-obvious why it carries. These
   are `behaviorChanging: false`, and `confidence: high` when the rule clearly applies.
   Keep a real non-obvious why (a workaround, an edge case, a business rule).
   Write the findings JSON to your output path — do not edit source files."

3. **over-engineering** — "Review these changed files for over-engineering: reinvented
   standard-library/framework functionality, unnecessary dependencies, speculative
   abstractions, config for things with one caller, YAGNI violations. For each, say
   what to delete and what replaces it. Prefer behavior-preserving deletions. Write the
   findings JSON to your output path — do not edit source files."

Each subagent should read the repo's `CLAUDE.md`/`AGENTS.md` for local conventions
before judging.

While the lenses run, wait for their completion notifications. Reading the diff or
running the gate yourself in the meantime duplicates their work.

## Step 3 — Merge & dedupe

Read each lens output file. Group findings that target the **same file and nearby lines
with the same intent** into one merged finding. Record an **agreement count** = how many
distinct lenses flagged it. Keep the clearest wording and the highest confidence in the
group. Then delete the lens output files.

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
2. The pre-push hook and project scripts — prefer the narrowest documented command that
   covers the files, using the repo's package/build tool.
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

Keep it terminal-friendly. Do not re-print unchanged code.

## Scope guardrails

- Only report/fix within the resolved scope — don't wander into unrelated files.
- Never `git add`, commit, or push. Leave the working tree for the user to review.
- If a lens output is malformed JSON, ask that lens once to rewrite it; if still broken,
  mark that lens as failed in the report rather than guessing.
