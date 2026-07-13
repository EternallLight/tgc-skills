---
name: review-fix
description: Use for a single pass of fixing review findings on a pull request — "fix the review findings", "address the review comments", "apply the reviewer feedback and push". One iteration; for the repeating fix-and-re-review cycle use tgc-skills:review-loop.
disable-model-invocation: true
argument-hint: "[PR URL|number]"
---

# Review Fix — one pass: fix findings, gate, commit, push

Fix all actionable findings from the latest review, verify the committed result against
the repo's reproducible local gate and a merge with the PR base, then push once.

## Step 0: Resolve the PR

Use the optional argument or the current branch:

```bash
gh pr view <optional-pr> --json number,url,headRefName,baseRefName
gh repo view --json nameWithOwner
```

Compare the `owner/repo` segment of the PR URL with local `nameWithOwner`. Stop if the PR
belongs to another repository, does not exist, or its head branch is not the checked-out
branch. Require `git status --porcelain` to be empty before editing; never mix review
fixes with pre-existing staged, unstaged, or untracked work.

## Step 1: Gather every finding

Fetch every page of formal reviews, inline comments, and top-level PR comments. Flatten
each paginated response to one JSON object per item:

```bash
gh api --paginate repos/{owner}/{repo}/pulls/{number}/reviews --jq '.[]'
gh api --paginate repos/{owner}/{repo}/pulls/{number}/comments --jq '.[]'
gh api --paginate repos/{owner}/{repo}/issues/{number}/comments --jq '.[]'
```

Re-fetch on every invocation because reviewers and bots edit existing comments. These
REST endpoints do not expose review-thread resolution state, so judge every finding
against the current tree and ignore stale, informational, and non-actionable comments.
Alternatively, use a findings list supplied directly by the caller and skip the fetch.

## Step 2: Fix

Handle critical findings first. Read the referenced code and its callers, identify the
root cause, and apply the smallest complete fix. Skip ambiguous findings or changes that
require a product/architecture decision, recording one clear reason for each.

## Step 3: Inspect current checks

```bash
gh pr checks {number} --json name,state,description,link
```

For each failed GitHub Actions check, extract the numeric run ID from the
`/actions/runs/<run-id>/` segment of `link`, then run
`gh run view <run-id> --log-failed`. For an external check, follow/report its link; do
not claim its logs were inspected through `gh run`. Fix code failures and identify
infrastructure failures separately.

## Step 4: Run the working-tree gate

Discover reproducible local commands from repo instructions, the pre-push hook, and
project scripts. Run them before committing and fix failures. Workflow `run:` lines do
not reproduce action steps, matrices, services, or external checks; if no local gate
exists, state that CI remains authoritative.

## Step 5: Commit locally

Stage only intended files, inspect the complete index with `git diff --cached`, and stop
if it contains anything unrelated. Commit using the repo's convention, falling back to
`fix: address review feedback`. Do not push yet. The merge-tree check must start from
this commit so it includes the fixes.

## Step 6: Check the merge tree

Fetch the base, create a detached scratch worktree in the system temporary directory,
merge the fetched base there, and run the same reproducible local gate:

```bash
git fetch origin {baseRefName}
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/tgc-premerge.XXXXXX")
cleanup_scratch() { git worktree remove "$SCRATCH" --force 2>/dev/null || true; }
trap cleanup_scratch EXIT
git worktree add --detach "$SCRATCH" HEAD
if (cd "$SCRATCH" && git merge "origin/{baseRefName}" --no-edit --no-ff && <same checks>); then
  CHECK_STATUS=0
else
  CHECK_STATUS=$?
fi
cleanup_scratch
trap - EXIT
test "$CHECK_STATUS" -eq 0
```

The forced removal is allowed only for this workflow-created scratch worktree. Always
remove it, including after a failed merge or check.

- Merge conflict: merge the fetched base into the real branch, resolve it, commit, and
  rerun both gates.
- Merged-tree failure: fix the real branch, amend the unpushed fix commit when safe,
  and rerun both gates.
- No reproducible local gate: still test the merge for conflicts, then report that CI
  remains the only executable gate.

## Step 7: Push and report

Push only after the available gates pass. Never force-push. Report findings fixed,
findings skipped with reasons, exact commands run, CI-only limitations, and commit hash.
Do not merge or trigger another review cycle; the caller decides what follows.
