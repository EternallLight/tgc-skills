---
name: checkpoint
description: Use when the user wants current work saved to the branch mid-flow without ending the task — "checkpoint", "commit and push", "save and push", "push what we have", optionally with a review ask ("checkpoint and review").
---

# Checkpoint

Save the working tree as ONE commit and push it, then keep going. A checkpoint is a
quick save, not commit surgery — no splitting, no interactive staging, no questions
about which files to include.

## Recipe

1. **See the change.** `git status --short` and `git diff`. If on the default branch,
   create a feature branch first.
2. **Cheap verify.** Run the repo's fastest relevant checks on the changed code —
   typecheck and lint from package.json scripts, Makefile, or CLAUDE.md; not the full
   test suite. If a check fails on something you changed, fix it or report the failure
   instead of committing — "only if green" is the contract even when unspoken.
3. **Stage by explicit path** — the files you changed, never `git add -A`. Planning
   artifacts (plans, briefs, handover docs, review logs) stay untracked.
4. **Commit** with a conventional message: type from the diff, scope matching recent
   `git log` scopes in this repo.
5. **Push** the current branch: `git push`, or `git push -u origin <branch>` the first
   time. Never force-push.
6. **Chain the review if asked.** When the request mentions review ("and review", "run
   the loop"), invoke the `review-loop` skill after the push. Otherwise don't — just
   mention it's one word away.

Then report in one line: commit hash, branch, file count, which checks ran.

## Common mistakes

| Mistake | Fix |
|---|---|
| Running the full test suite | Checkpoint = cheapest checks that cover the changed code |
| Committing when a check you touched is red | Fix it or report; never checkpoint red code silently |
| Asking which files to include | Checkpoint saves all current work by definition |
| `git add -A` sweeping in planning docs | Stage changed files by explicit path |
