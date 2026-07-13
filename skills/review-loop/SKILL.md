---
name: review-loop
description: Use when a branch or PR should be reviewed, fixed, and re-reviewed automatically until clean — "run the review loop", "review and fix until it passes", "loop review on this PR". Runs in a subagent to keep the main context clean.
---

# Review Loop — review → fix → re-review until clean

An automated cycle: independent reviewer agents review the branch diff, a fixer applies
the legitimate findings, and the loop re-reviews until the reviewers approve with no
critical issues. Everything runs **in-session with agents** — no external reviewer
accounts, no GitHub user switching. Fixes are committed locally each iteration and
**pushed once, squashed into a single commit, at the end**.

## Arguments

- **PR URL or branch** (optional). Defaults to the current branch; if a PR exists for
  it (`gh pr view`), the loop posts its closing summary there.

## Workflow

Launch a **single `general-purpose` subagent** with these instructions (pass it the
PR URL / branch and repo path):

```
You are running an automated review-fix loop on branch <branch> (base <base>).

## Heartbeat (do this FIRST, and after every state change)

Maintain a status file at `.review-loop-status` in the repo root (untracked; delete on
exit). APPEND one timestamped line per state change:

  echo "$(date +%H:%M) iter 2: 3 findings, fixing" >> .review-loop-status

Log at minimum: loop started, review dispatched, verdicts received, fixing (N findings),
committed, and the exit line. Long silence is indistinguishable from a hang — don't go
quiet.

## Setup

1. Record the starting point: `LOOP_BASE=$(git rev-parse HEAD)`.
2. Determine the diff scope: `git diff <base>...HEAD` (the PR's base branch, or the
   branch point from the trunk).

## Loop (max 5 iterations)

### 1. Review — two independent reviewer agents in parallel

Dispatch two agents in ONE message so they run concurrently. Both get the branch, base,
and instruction to review `git diff <base>...HEAD` plus enough surrounding file context
to judge. Different lenses so they don't just duplicate each other:

- **Reviewer A (correctness & security):** logic errors, race conditions, unhandled
  edge cases that crash, security vulnerabilities, data corruption, breaking API
  changes. Ignore style.
- **Reviewer B (robustness & quality):** error handling, resource leaks, wrong
  behavior under realistic inputs, misleading naming/comments, test gaps that hide
  the above. Ignore formatting nits and anything CI's linter will catch.

Each returns exactly:

    VERDICT: APPROVE | REQUEST_CHANGES
    CRITICAL_ISSUES:
    - [file:line] description
    MINOR_ISSUES:
    - [file:line] description

### 2. Combine and judge

- Dedupe (same file + same bug = one finding; keep the clearer wording).
- **DONE** when neither reviewer has critical issues AND every minor finding for the
  CURRENT tree is either fixed or explicitly dismissed with a one-line reason
  (intentional / stale / not worth it). Record every dismissal.
- Verify stale findings against the current tree before acting — an earlier iteration
  may have moved the file.

### 3. Fix

Apply the legitimate findings (critical first). Read each referenced location, fix with
judgment; skip-with-reason anything ambiguous or requiring an architectural change.
Then run the repo's FULL pre-push gate (the exact command its pre-push hook / CI
workflows run — read them, don't guess). Fix failures. Commit locally, staging only the
files you changed, with a conventional message. Do NOT push yet. Go back to step 1.

### 4. Exit conditions

- **clean** — reviewers approve, minors resolved → squash & push (step 5).
- **max-iterations** — 5 iterations reached → push commits AS-IS (no squash), report
  what remains.
- **non-converging** — the same findings survive 2 consecutive fix iterations → stop,
  push as-is, report the disagreement for the human to settle.

### 5. Squash & push (clean exit only)

Squash everything the loop committed into ONE commit:

    N=$(git rev-list --count $LOOP_BASE..HEAD)
    # N <= 1 → nothing to squash, just push.
    git reset --soft $LOOP_BASE
    git commit -m "fix: address review findings"
    git push   # add --force-with-lease ONLY if loop commits were already on the remote

Never plain `--force`. If a force-with-lease push is rejected, the branch diverged —
stop and report; do not retry harder.

### 6. Closing summary (every exit path)

If a PR exists, post ONE comment: outcome (clean / max-iterations / non-converging),
iterations, findings fixed, findings dismissed with reasons, and what remains if not
clean. Never post per-iteration comments. Then delete `.review-loop-status`.

## Report back

Return: iterations run, findings fixed, dismissals + reasons, final verdict per
reviewer, anything unresolved.
```

## Important notes

- **Always run the loop in a subagent** — the point is keeping the main conversation
  clean. Tell the user immediately where the heartbeat is:
  "progress: `tail -f <repo>/.review-loop-status`". If asked "is it frozen?", read that
  file and answer from it.
- The loop never merges the PR. Merging is always the human's move.
- One push per loop run (squashed), from the current authenticated user. No account
  switching anywhere.
