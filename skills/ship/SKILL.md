---
name: ship
description: Use when implementation on a branch is done and the user wants it taken through review — "ship", "ship it", "run the pipeline", or any ask to get the current changes polished, pushed, PR'd, and reviewed.
disable-model-invocation: true
argument-hint: "[PR title]"
---

# Ship — polish → gate → push → PR → review loop

Runs the standard pre-merge pipeline on the current branch. It ends at a reviewed PR.

**HARD RULE: this skill NEVER merges. Not on clean approval, not on green CI, not "to
save a step". Merging is the human's move, always. The terminal state is a reviewed PR
plus a report.**

## Arguments

- Optional PR title / extra instructions. If a PR already exists for the branch, reuse it.

## Steps

1. **Preflight.** Resolve the GitHub default branch, confirm the current branch is not
   it, verify `git status` is coherent, and ensure the intended work is in the diff.
2. **Polish.** Run `tgc-skills:polish` on the diff (correctness + simplification +
   over-engineering lenses; applies the safe findings). Skip only if the user says
   "no polish".
3. **Gate.** Run the repo's documented local or pre-push gate. Use hooks, project
   instructions, and package scripts to discover reproducible commands. Do not claim
   that copying GitHub Actions `run:` lines reproduces actions, services, matrices, or
   external checks; when there is no local gate, say CI remains authoritative.
4. **Commit.** Follow the repo's commit convention, falling back to a conventional
   message. Stage only files belonging to the change; inspect the complete index before
   committing. Do not exclude intentional plans or documentation merely because of
   their names.
5. **Update the base if needed.** Fetch the PR base/default branch. If the committed
   feature branch is behind, merge the fetched base, resolve conflicts explicitly, and
   rerun the local gate. Do not rebase a published branch or force-push.
6. **Push.** Push normally, establishing an upstream if needed. Never force-push.
7. **PR.** If none exists, `gh pr create` with a concise body: what changed, why, how it
   was verified. Note any DB migration prominently.
8. **Review loop.** Invoke `tgc-skills:review-loop` on the PR; it reports its heartbeat
   path before dispatching the loop agent.
9. **Report.** PR URL, loop outcome (clean / max-iterations / non-converging), findings
   fixed vs dismissed, gate evidence (what passed), and the current state of the hosted
   checks (`gh pr checks`). Only reach the ready-to-merge line once those checks are green
   or the user has explicitly authorised merging despite them; if any are still pending or
   failing, say so and stop short of the handoff instead. End with:
   "Ready for you to merge. Run `/tgc-skills:merged` after merging for the post-merge
   checks and cleanup."

## Red flags — stop and ask

- You're about to type `gh pr merge` in any form → violation of the hard rule, full stop.
- The diff contains a DB migration → flag it in the PR body and the report (the
  post-merge check in `merged` will look for it).
- The branch is behind its base → merge the fetched base without rewriting published
  history, then continue.
