---
name: review-loop
description: Use only when the user explicitly asks to review, fix, and re-review a branch or PR until clean, or when an active ship/checkpoint workflow invokes it — "run the review loop", "review and fix until it passes", "loop review on this PR".
argument-hint: "[PR URL|number|branch]"
---

# Review Loop — review → fix → re-review until clean

Proceed only when the surrounding user request explicitly asks for the loop (including
direct `/tgc-skills:review-loop` invocation) or `tgc-skills:ship`/`tgc-skills:checkpoint`
invokes it. It commits fixes and pushes once, so stop without that authorization.

Review with `tgc-skills:review`, fix with `tgc-skills:review-fix`, and repeat until a
review approves or a stop condition is reached. Fixes are committed locally and pushed
once at the end. Never merge, never force-push.

## Keep the loop out of the main context

1. Create `LOOP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tgc-review-loop.XXXXXX")` and tell the
   user `progress: tail -f <LOOP_DIR>/status`.
2. Launch one background `general-purpose` subagent with the repo path, the optional
   argument, `LOOP_DIR`, and the workflow below.
3. **Stall watch while it runs**: wait with one foreground Bash call
   (`timeout: 600000`), repeated as needed, never `sleep` across turns:
   ```bash
   for i in $(seq 19); do tail -n 1 "$LOOP_DIR/status" | grep -q ' exit ' && echo EXITED && break; [ -n "$(find "$LOOP_DIR/status" -mmin +15)" ] && echo STALE && break; sleep 30; done
   ```
   `EXITED` or the subagent's completion → step 4. `STALE` (no status line for 15
   minutes) → read the status tail and send the subagent one message to resume from that
   line. Stale again → report the stall to the user with the status tail instead of
   waiting. A stale status is a stall signal, not proof the subagent exited.
4. Relay the final report, then `rm -rf "$LOOP_DIR"`.

## Subagent workflow

Shell state does not persist between commands. Keep `LOOP_DIR`, `LOOP_BASE`, the base,
and each review's outputs in your notes and paste them into each command. Run every step
in the foreground; a background job's result never wakes this subagent.

### Setup and heartbeat

1. Run `"${CLAUDE_PLUGIN_ROOT}/scripts/pr-context.sh" --local [argument]`. It stops on the
   default branch, a branch argument that is not the checked-out branch, a PR from another
   repository or head branch, and a dirty tree (staged, unstaged, or untracked files are
   reported, never silently excluded). A non-zero exit is `blocked`; report its reason.
   Note `number` (may be empty), `base`, and `branch`. Never `source` or `eval` its output.
2. Fetch the base and record the start. Always reference the base ref quoted; a valid Git
   ref can contain shell metacharacters:

   ```bash
   BASE_REF="<base>"
   git fetch origin "$BASE_REF"
   LOOP_BASE=$(git rev-parse HEAD)
   ```

3. `: > "$LOOP_DIR/status"`, then append one line per state change (started, review
   dispatched, verdict, fixing, committed, gate, pushed, `exit <outcome>`):

   ```bash
   printf '%s %s\n' "$(date -u +%FT%TZ)" "<event>" >> "$LOOP_DIR/status"
   ```

   Keep `$LOOP_DIR/history.md` with one section per review: verdict, mode, partial,
   fingerprints, what was fixed, and dismissals with reasons.

### Loop — at most 3 fix rounds

The final confirming review does not count as a fix round.

**Review k**: invoke `tgc-skills:review local out=$LOOP_DIR/review-<k> [PR]`. The first
review is full. Every later review adds `delta <previous target_sha> <previous findings>`.
Record `verdict`, `findings`, `target_sha`, `target_tree`, `mode`, `coverage`, and
`partial` in `history.md`.

- `INCOMPLETE` → retry the same review once into a new `out=` directory. A second
  `INCOMPLETE` → exit `blocked`.
- `REQUEST_CHANGES` → fix round, or exit `max-iterations` if 3 fix rounds are spent.
- `APPROVE` from a full review → exit `clean`.
- `APPROVE` from a delta review → exit `clean` only when all of these hold:
  - the last full review was not `partial`;
  - every file in `git diff --name-only <last full target_sha>..HEAD` is in that full
    review's `coverage`;
  - none of those changes touch migrations, dependency manifests or lockfiles, or auth,
    session, or permission code.

  Otherwise run one confirming full review at the same `HEAD` (no `delta`). Its
  `APPROVE` → `clean`. Its findings → a fix round, or `max-iterations` after round 3.

**Fix round r**: read `${CLAUDE_PLUGIN_ROOT}/skills/review-fix/SKILL.md` and follow it in
loop-driven mode with the latest `findings.json`. It is user-invocation-only, so the
Skill tool cannot load it. It fixes, runs lint, typecheck, and the tests covering each
changed contract, and commits locally without pushing. Then go to the next review.

- **Fix the class**: when a finding belongs to a defect family an earlier round already
  fixed (same value, invariant, or sibling call site), tell the fix pass to enumerate
  every writer and consumer of that value across the repo and fix the whole class in one
  commit. Record the enumeration in `history.md`.
- **Non-converging**: the same fingerprint still unresolved after two consecutive fix
  rounds, or a round that commits nothing → exit `non-converging` with the findings and
  the fix pass's reasons.

## Exit

Outcomes: `clean`, `max-iterations`, `non-converging`, or `blocked` (unsafe state, two
`INCOMPLETE` reviews, auth or push failure, remote diverged). `blocked` never pushes.

### 1. Full local gate, once

Before the push, discover and run the repo's full reproducible local gate from its
instructions, pre-push hook, and project scripts. Do not claim that workflow `run:` lines
reproduce action steps, matrices, services, or external checks; with no local gate, say
CI remains authoritative. The gate must leave the tree clean. On a `clean` exit, hand
gate failures to a fix round as findings if one remains (then review again), else exit
`max-iterations`. On other exits, report the failure with the push.

### 2. Squash on a clean exit

Count only commits created after `LOOP_BASE`:

```bash
N=$(git rev-list --count "$LOOP_BASE"..HEAD)
```

- `N=0` or `N=1`: no rewrite.
- `N>1`: confirm you are still on the branch the loop started on and that
  `git merge-base --is-ancestor "$LOOP_BASE" HEAD` succeeds; if either check fails, stop
  and report instead of resetting. Otherwise `git reset --soft "$LOOP_BASE"` and create
  one commit using the repo's convention (fallback `fix: address review findings`).

The squash changes the SHA, not the tree. Bind the push to the reviewed tree:

```bash
test "$(git rev-parse 'HEAD^{tree}')" = "<final review target_tree>"
```

If it fails, stop and report instead of pushing. Non-clean exits push the loop commits
as they are.

### 3. Push once

If `origin/<branch>` exists after `git fetch origin "<branch>"` and
`git merge-base --is-ancestor "origin/<branch>" HEAD` fails, the remote diverged: exit
`blocked` without retrying. Otherwise push normally, with `git push -u origin HEAD` when
the branch has no upstream. `N=0` still pushes, so a clean but unpublished branch is
published. Never force-push.

### 4. Closing report

If a PR exists, post one comment (`gh pr comment <number> --body-file <file>`) with the
outcome, fix rounds, fixed findings, dismissals with reasons, local gate evidence,
unresolved items, the final reviewed tree, and the pushed SHA. Quote
`gh pr checks <number>` as it stands; checks still pending on the new push are reported
as pending, never as passed. Never post per-round comments.

Return the same facts and the final review verdict to the main session. Merging remains
the user's action.
