---
name: merged
description: Use right after the user merged a PR — "merged", "I merged it", "merged, clean up", "shipped, clean up the branch" — to run the post-merge routine for the repo the PR belongs to.
disable-model-invocation: true
argument-hint: "[PR URL|number] [release]"
---

# Merged — post-merge cleanup, checks, and (optional) release

The human just merged a PR. Run the tail of the pipeline they otherwise type by hand.

## Arguments

- Optional PR URL/number (else detect: `gh pr list --state merged` or the current
  branch's PR).
- `release` — also cut a release after cleanup. **Never release unless this word (or an
  explicit ask) is present** — in some repos publishing a release deploys to production.

## Steps

1. **Verify repo and merge.** Resolve local `nameWithOwner`, then run
   `gh pr view <pr> --json state,mergedAt,mergeCommit,headRefName,headRefOid,url`.
   Require the PR URL repository to match the local repo and `state` to be `MERGED`.
   Otherwise stop before migration, deploy, release, or local actions.
2. **Migration check (do not skip).** Did the merged diff add DB migration files
   (`gh pr diff <pr> --name-only` against the repo's migrations dir)? If yes: verify
   the migration actually ran where the code deploys (deploy workflow run / migrator
   job logs) and say so explicitly. A shipped PR whose migration silently didn't run is
   a production incident — this check exists because it happened.
3. **Answer the deploy question preemptively.** From `.github/workflows`, state what
   this merge triggers on its own (e.g. "staging auto-deploys on merge to the default
   branch; prod only on a published release") and link the running workflow if one
   started.
4. **Local cleanup, limited to this PR.**
   - Resolve the default branch and locate its worktree plus the PR branch worktree with
     `git worktree list --porcelain`. Before switching or removing anything, run
     `git status --porcelain` in every involved worktree and stop if any is dirty.
   - Require the local PR branch tip to equal the recorded `headRefOid`; otherwise skip
     deletion and report unpublished or post-merge commits.
   - Update the default branch in its existing worktree with `git pull --ff-only`, or
     check it out in the primary worktree when free, then `git fetch --prune`. Never
     remove the primary worktree. If the PR branch occupies the primary worktree while
     the default branch is checked out elsewhere, leave the branch/worktree and report
     why cleanup was skipped.
   - Remove only a clean linked worktree belonging to this PR. Try `git branch -d` first.
     After a squash/rebase merge, allow `git branch -D` only because the PR is verified
     merged and the local tip exactly matches its recorded head. Never remove unrelated
     branches or worktrees.
   - Run `git worktree prune` to clear stale administrative records. Do not delete
     untracked files or vaguely named "planning artifacts"; each workflow owns and
     removes its own temporary files.
5. **Release (only if requested).** Use the repo's own documented release flow.
6. **Report.** One compact block: merged PR, migration verdict (none / ran /
   NOT VERIFIED — flag loudly), what auto-deploys, branches/worktrees removed,
   release link if cut.

## Red flags

- Any temptation to `gh pr merge` → never; this is a verify-only skill.
- Migration present but you can't confirm it ran → make it the FIRST line of the
  report and suggest how to verify; never bury it.
- The default branch is checked out in another worktree → run the update there; do not
  remove or force it.
