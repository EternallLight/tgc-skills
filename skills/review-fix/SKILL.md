---
name: review-fix
description: Use for a single pass of fixing review findings on the current PR — "fix the review findings", "address the review comments", "apply the reviewer feedback and push". One iteration; for the repeating fix-and-re-review cycle use review-loop.
---

# Review Fix — one pass: fix findings, gate, commit, push

Fix all actionable findings from the latest review of the current PR, verify against
the repo's real CI gate (including the merge-commit case), commit, and push — once.

## Step 0: Detect the PR

```bash
gh pr view --json number,url,headRefName,baseRefName
```

No PR for the current branch → stop and say so.

## Step 1: Gather findings

Fetch ALL current review content — reviews, inline comments, and top-level PR
comments (reviewers often leave findings as plain comments, not formal reviews):

```bash
gh api repos/{owner}/{repo}/pulls/{number}/reviews
gh api repos/{owner}/{repo}/pulls/{number}/comments
gh api repos/{owner}/{repo}/issues/{number}/comments
```

**Re-fetch fresh on every invocation** — reviewers and bots frequently EDIT an existing
review/comment to append findings rather than posting new ones. Always re-read the full
current body; never skip something because you saw it last time. Verify each finding
still applies to the current tree (a later commit may have moved or renamed the file).

Alternatively, the caller (e.g. review-loop) may hand you a findings list directly —
then skip the fetch.

## Step 2: Fix

For each finding, critical first: read the referenced code, understand the intent,
apply the fix. If a finding is ambiguous or would require an architectural change,
skip it with a one-line reason rather than guessing wrong.

## Step 3: Check existing CI failures

```bash
gh pr checks {number} --json name,state,description --jq '[.[] | select(.state == "FAILURE")]'
```

For each failure, `gh run view {run-id} --log-failed`, find the root cause, fix it.
Infrastructure flakes you can't fix from code: note and skip.

## Step 4: Pre-push gate (BEFORE committing)

Do not commit or push until this is green — skipping it produces push/fail/fix churn.

1. **Discover the real commands** from `.github/workflows/` (and the pre-push hook /
   husky config / package.json scripts). Read the literal `run:` lines; don't guess.
2. **Run them on the working tree.** Fix anything red and re-run.
3. **Run them against the merge commit with the base branch.** CI builds the merge
   commit, not your branch tip — a branch that is green in isolation can be red once
   merged (main grew a new caller for something you renamed, etc.):

   ```bash
   git fetch origin {baseRefName}
   SCRATCH=".claude/worktrees/_premerge-check-$$"
   git worktree add "$SCRATCH" HEAD
   (cd "$SCRATCH" && git merge "origin/{baseRefName}" --no-edit --no-ff && <same checks>)
   git worktree remove "$SCRATCH" --force
   ```

   Merge conflict or merged-tree failure → merge the base into the real branch,
   resolve explicitly, re-run both gates.
4. Run any other code-level jobs the workflows define (skip deploy/release jobs).

## Step 5: Commit and push

Only after Step 4 is fully green:

```bash
git add <only the files you changed>
git commit -m "fix: address review feedback"
git push
```

Never `git add -A` (it sweeps in planning artifacts); never force-push.

## Step 6: Report

Findings fixed, findings skipped + reasons, gate commands that passed, commit hash.
Do not merge, and do not re-trigger anything — the caller decides what happens next.
