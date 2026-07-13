---
name: ship
description: Use when implementation on a branch is done and the user wants it taken through review — "ship", "ship it", "run the pipeline", or any ask to get the current changes polished, pushed, PR'd, and reviewed.
---

# Ship — polish → gate → push → PR → review loop

Runs the standard pre-merge pipeline on the current branch. It ends at a reviewed PR.

**HARD RULE: this skill NEVER merges. Not on clean approval, not on green CI, not "to
save a step". Merging is the human's move, always. The terminal state is a reviewed PR
plus a report.**

## Arguments

- Optional PR title / extra instructions. If a PR already exists for the branch, reuse it.

## Steps

1. **Preflight.** Confirm you are on a feature branch (never main/master — stop and say
   so if you are), `git status` is coherent, and the work the user means is actually in
   the diff.
2. **Polish.** Run the `polish` skill on the diff (correctness + simplification +
   over-engineering lenses; applies the safe findings). Skip only if the user says
   "no polish".
3. **Gate.** Run the repo's FULL pre-push gate — the exact command its pre-push hook or
   CI runs (read the hook / husky config / package.json / workflow files). A subset that
   passes locally and bounces in CI costs a whole round. Fix failures before proceeding.
4. **Commit & push.** Conventional message, staging only files that belong to the
   change. Never commit planning artifacts (plans, briefs, review logs).
5. **PR.** If none exists, `gh pr create` with a concise body: what changed, why, how it
   was verified. Note any DB migration prominently.
6. **Review loop.** Invoke the `review-loop` skill on the PR. Tell the user where its
   heartbeat file is.
7. **Report.** PR URL, loop outcome (clean / max-iterations / non-converging), findings
   fixed vs dismissed, gate evidence (what passed). End with: "Ready for you to merge.
   Say 'merged' when you have and I'll run the post-merge cleanup."

## Red flags — stop and ask

- You're about to type `gh pr merge` in any form → violation of the hard rule, full stop.
- The diff contains a DB migration → flag it in the PR body and the report (the
  post-merge check in `merged` will look for it).
- The branch is behind its base → rebase onto the latest base first, then continue.
