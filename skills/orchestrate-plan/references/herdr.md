# herdr backend

herdr gives every worker a stable pane id and a named agent, submits prompts atomically, and
waits on agent state server-side. Commands below match herdr 0.8.0; `herdr <group>` with no
subcommand prints that group's current syntax, and the binary wins over this file. Deeper CLI
notes live in `tgc-skills:herdr-orchestrate`.

Two handles per lane, both recorded literally in the lane ledger: the **agent name**
(`worker-<lane>`, matching `[a-z][a-z0-9_-]{0,31}`) for agent verbs, and the **pane id**
(`w1:p3`) for pane verbs. Shell variables do not survive between tool calls.

## Gate

`detect-backend.sh` printing `herdr` means `$HERDR_PANE_ID` is set, so you are inside a herdr
pane. A working `herdr` command proves nothing: the CLI answers from any shell, and a command with
no target may hit the pane the user has focused. Always pass an explicit agent name or pane id.

Accurate agent state needs the engine's integration: check `herdr integration status`, and if the
worker engine is missing, ask the user before running `herdr integration install claude` (or
`codex`). Without it, state can read `unknown`; use the marker fallback in W0.

## Create the lane worktree and branch

```bash
git -C '<repo>' fetch origin '<default-branch>'
git -C '<repo>' worktree add --no-track -b <change-slug> '<repo>-<change-slug>' origin/<default-branch>
```

## Start a worker

Split a sibling pane in the worktree, keeping focus in your own pane:

```bash
herdr pane split --current --direction down --cwd '<worktree>' --no-focus
```

Read the new pane id from `.result.pane.pane_id`. The pane must sit at its shell prompt before
`agent start`. If the repo needs shell setup (`nvm use`, direnv), run it first with
`herdr pane run <pane_id> '<setup>'` and read the pane to confirm. Then start the agent; native
flags go after `--`:

```bash
herdr agent start worker-<lane> --kind claude --pane <pane_id> -- --model sonnet --effort high
herdr agent start worker-<lane> --kind codex --pane <pane_id> -- -c model_reasoning_effort=medium
```

It returns once herdr detects the agent ready for input. If it errors, stop and fix it; do not
send anything to that pane. Confirm the banner shows the intended model and effort:
`herdr agent read worker-<lane> --source visible --lines 12`.

## Send a prompt

`agent prompt` types the text and Enter in one call, honouring bracketed paste:

```bash
herdr agent prompt worker-<lane> '<single-line prompt, no apostrophes>'
```

Single-quote the text so your shell expands nothing in it.

## Read status and screen

```bash
herdr agent get worker-<lane>
herdr agent read worker-<lane> --source visible --lines 16
herdr agent read worker-<lane> --source recent-unwrapped --lines 120
```

States: `working`; `blocked` (herdr recognized an approval or question UI); `idle` or `done`
(ready for input; `done` means it finished while you were not looking); `unknown` (agent present,
state unclear; never proof of completion). If a larger `--lines` reveals nothing more, the agent
is on the alternate screen; ask it to write its full reply to a temp file and print the path.

## Wait for done or blocked — W0

Send and wait in one call, with `run_in_background: true`. Timeouts are milliseconds.

```bash
herdr agent prompt worker-<lane> '<phase prompt>' --wait --timeout 3600000
```

`--wait` first requires the agent to change state within 5 s (else it returns
`agent_prompt_stalled`; read the pane and resend), then returns on the first `idle`, `done`, or
`blocked`. To wait on an agent that is already working, for example after you answered a prompt
and `agent get` shows `working`:

```bash
herdr agent wait worker-<lane> --timeout 3600000
```

Parallel lanes: run one background W0 per lane. Each wakes you for its own lane; service it,
then re-arm that lane only.

A return tells you something settled, not what happened. Read the tail and classify: `blocked`
or an idle worker ending on a question is NEEDS-INPUT, not DONE.

**Marker fallback** when state reads `unknown`. Use `(?m)` because herdr matches Rust regexes and
`^` otherwise anchors only to the start of the snapshot; the anchor keeps the echoed prompt, which
quotes the marker mid-line, from matching:

```bash
herdr pane wait-output <pane_id> --regex '(?m)^=== PHASE [0-9]+ DONE ===' --source recent --timeout 3600000
```

For a screen-scrape monitor across lanes, use W2 in `templates.md` with this `read_lane`. `pane read`
prints a JSON envelope, so it unwraps `.result.read.text` (needs `python3`):

```bash
LANES="w1:p2 w1:p3"
read_lane() { herdr pane read "$1" --source visible --lines 16 2>/dev/null | python3 -c 'import json, sys; d = sys.stdin.read(); print(json.loads(d)["result"]["read"]["text"] if d.lstrip().startswith("{") else d)'; }
```

## Answer a prompt

Read first: `herdr agent read worker-<lane> --source visible --lines 30`. Then:

- Free-text question: `herdr agent prompt worker-<lane> '<answer>'`.
- Numbered menu: `herdr pane send-text <pane_id> '1'`.
- Highlighted list: `herdr agent send-keys worker-<lane> down enter`.
- Runaway worker: `herdr agent send-keys worker-<lane> ctrl+c`, then redirect.

Read again to confirm the prompt was accepted. Escalate real decisions to the user and notify:
`herdr notification show 'Orchestrator' --body '<lane>: <question>' --sound request`.

## Next phase

```bash
herdr agent prompt worker-<lane> '/clear'
herdr agent read worker-<lane> --source visible --lines 8
```

If the slash palette is still open, `herdr agent send-keys worker-<lane> enter`. `/clear` reverts
Claude's effort to the launch default, which the `--effort high` launch flag already set; Codex
keeps its launch flag. Then send the next T2 prompt.

## Close

When a lane runs out of phases, close only the pane you created: `herdr pane close <pane_id>`.
Leave the worktree for shipping; `tgc-skills:merged` removes it after merge. Never run
`herdr server stop`.
