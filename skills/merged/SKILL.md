---
name: merged
description: Use right after the user merged a PR — "merged", "I merged it", "merged, clean up", "shipped, clean up the branch" — to run the post-merge routine for the repo the PR belongs to.
---

# Merged — post-merge cleanup, checks, and (optional) release

The human just merged a PR. Run the tail of the pipeline they otherwise type by hand.

## Arguments

- Optional PR URL/number (else detect: `gh pr list --state merged` or the current
  branch's PR).
- `release` — also cut a release after cleanup. **Never release unless this word (or an
  explicit ask) is present** — in some repos publishing a release deploys to production.

## Steps

1. **Verify it's actually merged.** `gh pr view <pr> --json state,mergedAt,mergeCommit`.
   Not merged → stop; this skill never merges anything itself.
2. **Migration check (do not skip).** Did the merged diff add DB migration files
   (`gh pr diff <pr> --name-only` against the repo's migrations dir)? If yes: verify
   the migration actually ran where the code deploys (deploy workflow run / migrator
   job logs) and say so explicitly. A shipped PR whose migration silently didn't run is
   a production incident — this check exists because it happened.
3. **Answer the deploy question preemptively.** From `.github/workflows`, state what
   this merge triggers on its own (e.g. "staging auto-deploys on merge to main; prod
   only on a published release") and link the running workflow if one started.
4. **Local cleanup.**
   - `git checkout <trunk> && git pull`, delete the merged local branch,
     `git fetch --prune`.
   - Prune worktrees whose branches are merged (`git worktree list`, then
     `git worktree remove` the stale ones) so they don't cause wrong-branch starts.
   - Remove leftover planning artifacts (plans, briefs, review logs,
     `.review-loop-status`) from the repo root — they are untracked by convention.
5. **Release (only if requested).** Use the repo's own documented release flow.
6. **Report.** One compact block: merged PR, migration verdict (none / ran /
   NOT VERIFIED — flag loudly), what auto-deploys, branches/worktrees removed,
   release link if cut.

## Red flags

- Any temptation to `gh pr merge` → never; this is a verify-only skill.
- Migration present but you can't confirm it ran → make it the FIRST line of the
  report and suggest how to verify; never bury it.
- `git checkout <trunk>` fails because the trunk is checked out in another worktree →
  run the cleanup from that worktree or prune it first; don't force.
