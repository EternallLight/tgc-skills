---
name: checkpoint
description: Use when the user wants current work saved to the branch mid-flow without ending the task — "checkpoint", "commit and push", "save and push", "push what we have", optionally with a review ask ("checkpoint and review").
disable-model-invocation: true
---

# Checkpoint

Save the working tree as ONE commit and push it, then keep going. A checkpoint is a
quick save, not commit surgery — no splitting, no interactive staging, no questions
about which files to include.

## Recipe

1. **See the change.** Run `git status --short`, `git diff`, and `git diff --cached`.
   Resolve the default branch with `gh repo view --json defaultBranchRef`; if currently
   on it, create a feature branch first. Stop if the tree or index contains unrelated or
   sensitive files.
2. **Cheap verify.** Run the repo's fastest relevant checks on the changed code —
   typecheck and lint from package.json scripts, Makefile, or CLAUDE.md; not the full
   test suite. If a check fails on something you changed, fix it or report the failure
   instead of committing — "only if green" is the contract even when unspoken.
3. **Stage by explicit path** — the intended current work, never `git add -A`. Then
   inspect `git diff --cached --name-only` and `git diff --cached`; the index must contain
   only intended files. Treat plans and documentation like any other repo file.
4. **Commit** using the repo's documented or recent-log convention. Fall back to a
   conventional message when the repo has no established convention.
5. **Push** the current branch: `git push`, or `git push -u origin <branch>` the first
   time. Never force-push.
6. **Chain the review if asked.** When the request mentions review ("and review", "run
   the loop"), invoke `tgc-skills:review-loop` after the push; it reports its heartbeat
   path before dispatching. Otherwise stop after the checkpoint and mention
   `/tgc-skills:review-loop` as the next step.

Then report in one line: commit hash, branch, file count, which checks ran.

## Common mistakes

| Mistake | Fix |
|---|---|
| Running the full test suite | Checkpoint = cheapest checks that cover the changed code |
| Committing when a check you touched is red | Fix it or report; never checkpoint red code silently |
| Silently including an ambiguous file | Stop when status contains unrelated or sensitive work |
| `git add -A` sweeping in unrelated files | Stage intended files by explicit path |
