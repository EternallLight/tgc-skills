# Orca backend

Orca's orchestration layer supervises workers with typed messages, so there are no pane refs,
printed markers, or screen-scrape pollers here. A phase is an Orca **Task**, a worker is a
**Dispatch**, and completion is a `worker_done` message.

**Prerequisite:** Orca's own skills, `orca skills install --skill orca-cli --skill orchestration`.
Load `orca skills get orchestration` before the first command and use it for anything this file
does not cover. The flags below match Orca 1.4.240; the live `--help` of each command wins.

Resolve the executable once, the way Orca's `orchestration` skill says (`$ORCA_CLI_COMMAND`, then
`orca-dev` in a dev checkout, then `orca-ide` on Linux outside an Orca terminal, else `orca`), and
reuse it everywhere. On Linux outside Orca, bare `orca` is the GNOME screen reader. Examples
below write `orca`.

| herdr/cmux mechanism | Orca |
|---|---|
| Phase as a todo item | `task-create --spec <T3> --deps '["<prev_task_id>"]'` |
| Worker pane + captured ref | `worker-start` returns a durable dispatch id |
| `/clear` between phases | `worker-release`, then `worker-start` the next task in the same worktree |
| `=== PHASE N DONE ===` marker | `worker_done` with `--outcome succeeded\|failed` |
| W1/W2 poll loops | W3: `check --wait`, one call for every lane |
| Screen-classified NEEDS-INPUT | worker `ask` → your `reply` |
| `read-screen \| tail` | `worker-read --dispatch <id> --limit 50` |

## Gate

```bash
orca status --json
orca orchestration task-list --json
```

`status` must show a reachable runtime (start it with `orca open --json`). `task-list` answering
`run_required` is a pass: orchestration works and no Run is bound yet. `unknown command` means an
older CLI; stop and tell the user.

## Run and tasks

Bind one Run, then create one task per phase. Chain phases inside a lane with `--deps`; phases in
different lanes take no deps on each other.

```bash
orca orchestration run-create --objective "Execute <PLAN_FILE>: <plan title>" --json
orca orchestration task-create --spec "<T3 spec for phase 1>" --json
orca orchestration task-create --spec "<T3 spec for phase 2>" --deps '["<phase 1 task id>"]' --json
```

## Create the lane worktree and branch

Create the worktree first, without an agent, so the brief can be written into it before any
worker reads it.

```bash
git -C '<repo>' fetch origin '<default-branch>'
orca worktree create --repo path:'<repo>' --name <change-slug> --no-parent --base-branch origin/<default-branch> --setup run --json
```

`--name` names both the worktree and its branch. Record the full worktree `id`
(`<repo-id>::<path>`) and its path from the receipt (or `orca worktree list --json`). `--no-parent`
sets Orca lineage only, not the git base. Orca creates the branch, so check tracking yourself:

```bash
git -C '<worktree>' branch --show-current
git -C '<worktree>' rev-parse --abbrev-ref '@{upstream}'
```

The first must print the slug. If the second prints anything, run
`git -C '<worktree>' branch --unset-upstream`.

## Start a worker

```bash
orca orchestration worker-start --task <task_id> --worktree id:'<full worktree id>' --agent claude --model sonnet --effort high --json
orca orchestration worker-start --task <task_id> --worktree id:'<full worktree id>' --agent codex --json
```

When nothing has to be written into the worktree before the worker starts, one call creates the
worktree, the task, and the worker; run the tracking check above on the worktree it reports:

```bash
orca orchestration worker-start --spec "<task spec>" --worktree new-top-level --name <change-slug> --base-branch origin/<default-branch> --agent claude --model sonnet --effort high --setup run --json
```

The call exits 0 only for `ready`. On a non-zero exit, do not relaunch: read `failedStage`,
`residualResources`, and the recovery commands in the receipt, then load
`orca skills get orchestration --reference references/recovery-and-cleanup.md`. Compare
`launch.requested` with `launch.effective`; never claim a model or effort from the arguments alone.
Record the dispatch id in the lane ledger. `worker-start` injects the lifecycle preamble, so the
worker reports through `worker_done` and asks through `ask`.

The worker may run as a terminal or a chat, per the user's Orca setting. The orchestration verbs
below work for both; `orca terminal` verbs only work when `worker-show` reports a terminal handle.

## Send a prompt

The task spec is the prompt; `worker-start` delivers it. For guidance during a phase:

```bash
orca orchestration send --to dispatch:<dispatch_id> --subject "<subject>" --body "<guidance>" --json
```

The worker reads follow-ups at its own checkpoints. A successful `send` proves delivery to the
queue, not that the worker read it.

## Read status and screen

```bash
orca orchestration worker-show --dispatch <dispatch_id> --json
orca orchestration worker-read --dispatch <dispatch_id> --limit 50 --json
```

Continue `worker-read` from the returned `cursor`. If Orca reports `source_changed`, start a fresh
read without the old cursor. Never supply or guess a provider session id or transcript path.

## Wait for done or blocked — W3

One blocking call covers every lane:

```bash
orca orchestration check --wait --types worker_done,escalation,question --timeout-ms 900000 --json
```

For each message in the returned Delivery:

- **`worker_done`** → validate it against the expected dispatch, verify with V1, then decide the
  terminal's next owner (see Close). Then start the lane's next phase.
- **`question`** → answer it (see Answer a prompt).
- **`escalation`** → read it, resolve from the plan or brief, or escalate to the user. Do not
  release the worker.

Acknowledge only after every message in the Delivery is handled, and keep waiting in the same call:

```bash
orca orchestration check --ack <delivery_id> --wait --types worker_done,escalation,question --timeout-ms 900000 --json
```

A timeout or `{count:0}` is a checkpoint, not a failure; phases run 15–60 minutes. After three
empty waits in a row, run `orca orchestration worker-list --run <run_id> --json` and act on each
row's `projection.attention` and `projection.nextAction`.

## Answer a prompt

A worker `question`:

```bash
orca orchestration reply --id <message_id> --body "<answer>" --json
```

Typed mail does not see a raw permission dialog inside the agent. If a lane is quiet with no
message, run `worker-show`: a non-null `observation.agentWait` means the worker is parked on a
prompt only a human can answer. An absent `agentWait` means Orca did not look, not that the worker
is free. When `worker-show` reports a terminal handle, read the dialog and answer it:

```bash
orca terminal read --terminal <handle> --screen --json
orca terminal send --terminal <handle> --text '<answer or option number>' --enter --json
```

With no terminal handle, ask the user to answer it in Orca. Never auto-answer an irreversible or
ambiguous prompt.

## Next phase

A fresh worker process is the pristine context. After a verified `worker_done`, release the
settled dispatch and start the lane's next task in the same worktree:

```bash
orca orchestration worker-release --dispatch <dispatch_id> --json
orca orchestration worker-start --task <next_task_id> --worktree id:'<full worktree id>' --agent claude --model sonnet --effort high --json
```

## Close

Release every settled worker, failed ones too, unless the user asked to keep it (then
`worker-retain --dispatch <id>`). Release is cleanup after settlement, not cancellation. Never use
`orca terminal close` as a substitute. Before ending the run,
`orca orchestration worker-list --run <run_id> --terminal-state reclaimable --json` must return
nothing. Leave the worktree for shipping; `tgc-skills:merged` removes it with `orca worktree rm`
after merge.

## Skip-permissions launch (explicit user opt-in only)

`worker-start --agent` cannot carry `--dangerously-skip-permissions` or
`--dangerously-bypass-approvals-and-sandbox`. Launch the agent yourself in the lane worktree, then
hand that terminal to a supervised worker:

```bash
orca terminal create --worktree id:'<full worktree id>' --title lane-<repo> --command '<launcher with flags>' --json
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 120000 --json
orca terminal read --terminal <handle> --screen --json
orca orchestration worker-start --task <task_id> --terminal <handle> --worktree id:'<full worktree id>' --json
```

The read between `wait` and `worker-start` must show the agent banner: `tui-idle` is satisfied by a
dead shell prompt too, so a launch that errored looks ready. `--model` and `--effort` cannot
combine with `--terminal`; put them in the launch command. Codex renames its own tab, so match
terminals by handle, never by title.

## Traps

- **`check --wait` returns one Delivery**, and replays it until you `--ack`. Process every message
  in it, ack, and wait again until every dispatch settles.
- **Only positive proof of exit authorizes stop, abandon, or retry.** Never release, stop, or
  restart a worker on a timeout, a heartbeat, or an idle TUI. Recovery is conditional:
  `worker-show` says `ready` → keep waiting; proven `failed`/`stopped` →
  `worker-start --task <id> --retry-of <dispatch_id>` with an explicit `--worktree` and `--agent`,
  because retry does not inherit placement.
- **`--effort` requires `--model`.** Neither combines with `--terminal`.
- **`dispatch --inject` leaves the process unsupervised.** `worker-show` and `worker-read` report
  it as `unsupervised`, and stop, retain, and release take no process action. Use
  `worker-start --terminal <handle>` when you need lifecycle ownership of a terminal you launched.
- **A worktree per lane needs a reason on Orca.** Dev servers, watchers, and local stacks run from
  the user's primary checkout; that live-process conflict is the reason. State it.
- **Supervision, not handoff.** If the user only wants work handed off without monitoring, that is
  Orca's `orca-cli` skill, not this one.
- `coordinator-start` and `coordinator-stop` are retired. Use `run-create` or `run-use`.
