---
name: explain-pr
description: Use before shipping, when the user wants to understand their own branch — "explain what we did", "walk me through this branch", "what am I about to ship", "why did we change that", or any ask to account for the current diff before running tgc-skills:ship. Explains the change back to the user and flags anything it cannot justify. Read-only; not a PR description writer, not a code review.
---

# Explain PR — account for the diff before you ship

Walk the user through their own branch: what changed, why, and what neither of you can
justify. Agent-written code ships without ever being understood; this is the checkpoint
that catches it.

**Done:** every change in the diff is either explained with evidence or listed as
unjustified, and the user has decided what to do about the unjustified ones.

**Never:** invent a plausible "why". An unexplained change is the finding. Say `???`.

## Steps

1. **Resolve the diff.** The base is the PR's `baseRefName` when a PR exists, else the
   GitHub default branch. Diff from `git merge-base --fork-point origin/<base> HEAD`
   (falling back to `git merge-base origin/<base> HEAD`), plus uncommitted and
   untracked work. Not on a feature branch, or the diff is empty — say so and stop. Say
   what range you used.
2. **Gather the why, before forming a view.** Commit messages, the branch name, any plan
   or requirements doc the branch touches, the linked issue/PR (`gh`), and this
   conversation. Read the code itself last — it tells you *what*, rarely *why*.
3. **Group into changes, not files.** One entry per intent, however many files it spans.
   A 400-line diff is usually 3-5 real changes.
4. **Explain each one:** what it does, why it exists, and the `file:line` evidence for
   both. Mark the "why" source: commit / plan doc / issue / conversation /
   inferred-from-code. `inferred-from-code` is a weak source — say so.
5. **Flag what has no why.** A change with no evidence trail gets `Why: ???`. Name the
   likely cause: leftover debugging, a speculative abstraction, an agent's
   belt-and-suspenders guard, an unrelated drive-by, or a rename that touched more than
   it meant to. Also flag changes that contradict a plan doc in the repo, and anything
   in the diff the user did not ask for.
6. **Report in the chat.** Never write the explanation to a file, and never offer to.
   Open with `X explained, Y unjustified`, then a numbered list with two or three lines
   per change: what it does, `Why: <reason> (<source>)` or `Why: ???`, and `file:line`.
   Under 400 words for a normal branch. Only an unjustified change earns extra lines:
   name the concrete next move (keep it and say why here, cut it, or split it to its own
   branch). Suggest nothing else — no refactors, no improvements, no review notes.
7. **Hand off.** When `tgc-skills:ship` invoked this skill, return the report to it.
   Otherwise, when the user is satisfied, offer `/tgc-skills:ship`; never run it
   yourself, and never present the branch as ready while unjustified changes are
   unresolved.

## Boundaries

Read-only: never edits code, commits, pushes, or comments on GitHub. Bugs and style
belong to `tgc-skills:polish` and `tgc-skills:review`; the PR body belongs to
`tgc-skills:ship`.
