---
name: review-loop
description: Use only when the user explicitly asks to review, fix, and re-review a branch or PR until clean, or when an active ship/checkpoint workflow invokes it — "run the review loop", "review and fix until it passes", "loop review on this PR".
argument-hint: "[PR URL|branch]"
---

# Review Loop — review → fix → re-review until clean

Proceed only when the surrounding user request explicitly asks for the loop (including
direct `/tgc-skills:review-loop` invocation) or `tgc-skills:ship`/`tgc-skills:checkpoint`
invokes it. It commits fixes and pushes once, so stop without that authorization.

Review the branch diff with independent agents, fix legitimate findings, and repeat
until clean or a stop condition is reached. Never merge the PR.

## Keep the loop out of the main context

Create `STATUS=$(mktemp "${TMPDIR:-/tmp}/tgc-review-loop.XXXXXX")` and tell the user
that progress is visible there. Then launch one `general-purpose` subagent with the repo
path, optional PR/branch argument, status path, and the complete workflow below. The main
context manages only the dispatch and final report. Subagents may start in the
background; explicitly wait for this one to finish before returning or letting a parent
workflow report completion.

## Subagent workflow

### Setup and heartbeat

1. Resolve the local `nameWithOwner`, current branch, and GitHub default branch. Stop if
   the current branch is the default branch. Require a supplied branch argument to equal
   the current branch. If a PR is supplied or detected, require its URL repository to
   match `nameWithOwner` and its `headRefName` to match the current branch. Stop on any
   mismatch. Use its `baseRefName`; without a PR, use the default branch.
2. Require a clean working tree. Stop and report staged, unstaged, or untracked files
   rather than silently excluding them.
3. Fetch the resolved base and review its diff consistently throughout the loop. Capture
   the base ref from command output into a shell variable and always reference it quoted —
   a valid Git ref can contain shell metacharacters (`$(...)`, backticks), and
   command-substitution output is not re-evaluated, so this cannot inject commands:

   ```bash
   BASE_REF=$(gh pr view <pr> --json baseRefName --jq .baseRefName \
     || gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
   git fetch origin "$BASE_REF"
   LOOP_BASE=$(git rev-parse HEAD)
   git diff "origin/$BASE_REF...HEAD"
   ```
4. Create/truncate the passed status file outside the repo:

   ```bash
   STATUS="<passed status path>"
   : > "$STATUS"
   ```

5. Append one timestamped line when the loop starts and after every state change: review
   dispatched, verdicts received, fixing, committed, and exit. Remove only this file
   after the closing report/comment.

## Loop — at most five iterations

### 1. Review with two independent agents

Dispatch both reviewers concurrently. Give each the branch, base, diff scope, and enough
surrounding file context to judge. They report findings only and never edit.

- **Correctness and security:** logic errors, races, crash-level edge cases, security
  vulnerabilities, data corruption, and breaking API changes. Ignore style.
- **Robustness and quality:** error handling, resource leaks, realistic-input failures,
  misleading names/comments, and test gaps that hide those defects. Ignore formatting
  and linter findings.

Require exactly:

```text
VERDICT: APPROVE | REQUEST_CHANGES
CRITICAL_ISSUES:
- [file:line] description
MINOR_ISSUES:
- [file:line] description
```

### 2. Combine and judge

- Dedupe the same bug at the same location, keeping the clearest wording.
- Finish clean when neither reviewer has a critical issue and every minor finding for
  the current tree is fixed or dismissed with a recorded one-line reason.
- Verify every finding against the current tree before acting; prior iterations may
  have moved or removed the referenced code.

### 3. Fix and verify

Apply legitimate findings, critical first. Trace callers and fix the root cause. Skip
ambiguous or architecture/product decisions with a reason.

Discover and run the repo's reproducible local gate from its instructions, pre-push
hook, and project scripts. Do not claim isolated workflow `run:` lines reproduce action
steps, matrices, services, or external checks. Fix local failures, stage only intended
files, and commit using the repo's convention with a conventional fallback. Do not push.
Then return to review.

### 4. Stop conditions

- **clean:** reviewers approve and minors are resolved → finish through squash/push.
- **max-iterations:** five iterations reached → push loop commits as-is and report what
  remains.
- **non-converging:** the same finding survives two consecutive fix iterations → push
  loop commits as-is and report the disagreement for the user.
- **branch diverged:** the remote changed during the loop → stop without force-pushing.

## Clean exit: squash and push once

Count only commits created after `LOOP_BASE`:

```bash
N=$(git rev-list --count "$LOOP_BASE"..HEAD)
```

- `N=0`: push normally so a clean but unpublished branch is still published.
- `N=1`: keep the commit and push normally.
- `N>1`: before rewriting anything, confirm you are still on the branch the loop started
  on and that `LOOP_BASE` is an ancestor of `HEAD`
  (`git merge-base --is-ancestor "$LOOP_BASE" HEAD`); if either check fails, stop and
  report instead of resetting. Otherwise `git reset --soft "$LOOP_BASE"`, create one
  commit using the repo's convention (fallback `fix: address review findings`), then push
  normally.

Establish an upstream when the branch has none. Never force-push. If the remote has
diverged, stop and report it instead of retrying.

## Closing report

If a PR exists, post one comment containing outcome, iterations, fixed findings,
dismissals with reasons, local gate evidence, and unresolved items. Never post
per-iteration comments.

Return the same facts to the caller, include both final reviewer verdicts, then remove
the session status file. Merging remains the user's action.
