# tgc-skills

A shipping pipeline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code),
packaged as a plugin. Seven skills that take a change from "locked plan" to "merged and
cleaned up", using in-session agents — no external reviewer accounts, no infrastructure
beyond `git` and `gh`.

## The pipeline

```
orchestrate ──► checkpoint ──► ship ──► review-loop ──► (you merge) ──► merged
                                 │            │
                               polish     review-fix
```

| Skill | What it does |
|---|---|
| **orchestrate** | Execute a locked plan too big for one context window: split it into phases, dispatch one fresh subagent per phase, verify each with git plumbing, run independent repos as parallel lanes. |
| **ship** | The pre-merge pipeline: polish the diff, run the repo's real pre-push gate, commit, push, open a PR, hand it to the review loop. Never merges. |
| **review-loop** | Review → fix → re-review with independent agent reviewers until clean (max 5 iterations). Commits fixes locally each round, pushes once — squashed into a single commit — at the end. |
| **review-fix** | One pass of the fix cycle: gather findings from the PR, fix them, gate against branch tip AND the merge commit, commit, push. |
| **polish** | Three parallel review lenses (correctness, simplification, over-engineering) over the current diff; auto-applies only safe, behavior-preserving findings. |
| **checkpoint** | Mid-flow quick save: cheap verify, one commit, push, keep going. |
| **merged** | Post-merge tail: verify the merge, check that DB migrations actually ran, answer the deploy question, delete branches/worktrees, optional release. |

Design principles baked in:

- **One phase per context window.** Fresh subagents re-ground from disk instead of
  inheriting lossy summaries.
- **The orchestrator never reads implementation files** — verification is git plumbing,
  narrow greps, and throwaway read-only agents.
- **Merging is always the human's move.** No skill in this repo ever merges a PR.
- **Gates are the repo's real gates.** Skills read the pre-push hook and CI workflows
  and run those exact commands — including against the merge commit with the base
  branch, which is what CI actually builds.
- **Planning artifacts never get committed.** Plans, briefs, and loop status files stay
  untracked.

## Install

```
/plugin marketplace add EternallLight/tgc-skills
/plugin install tgc-skills@tgc-skills
```

## Requirements

- `git` and the [GitHub CLI](https://cli.github.com/) (`gh`), authenticated.
- Nothing else. Reviews run as in-session agents; pushes and PR comments come from
  your own GitHub user.

## License

MIT
