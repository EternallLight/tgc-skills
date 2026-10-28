---
name: herdr-orchestrate
description: Use when orchestrating herdr terminal panes, splits, tabs, workspaces, worktrees, worker sessions, or agents in other herdr panes, including reading screens, sending commands, answering prompts, waiting on agent status, and setting AFK check-ins. Do not use for tmux, IDE/browser tabs, deployment replicas, or plain command execution. For cmux use tgc-skills:cmux-orchestrate; for Orca use Orca's own orca-cli skill.
---

# herdr Orchestrate

Drive a **herdr** terminal workspace — build pane layouts, name panes and tabs, start worker agents, prompt them, read their screens, and answer the agents running inside them — translating the user's plain English into real `herdr` CLI calls fast, without paging through help every time.

herdr is **agent-first**: a headless server exposes a Unix-socket API, and the `herdr` CLI is a thin client over it. You don't memorize a GUI; you read the live snapshot and act on it.

Trigger eagerly even when the user does not say "herdr" but is clearly orchestrating terminal panes: "open a pane", "split the terminal", "the agent in my other tab", "my worker panes", "check the other pane", "send X to the right pane".

## 0. Gate: which backend are we in?

```bash
sh "${CLAUDE_PLUGIN_ROOT}/scripts/detect-backend.sh"
```

- `herdr` → continue. `$HERDR_PANE_ID` is **this pane** (e.g. `w1:p1`); that's how you tell yourself apart from workers.
- `cmux` → stop and use `tgc-skills:cmux-orchestrate`. The CLIs are not interchangeable.
- `orca` → stop and use Orca's own `orca-cli` / `orchestration` skills (`orca skills get orca-cli`).
- `none` → tell the user you are not inside a herdr pane, and stop.

Trust the script, not a working CLI. `herdr` talks to the server socket from *any* shell, so a successful `herdr pane list` proves the server is up, not that you are in a pane. Never gate on `HERDR_SESSION` (empty for the default session). Outside a pane, an omitted target resolves to the UI-focused pane — quite possibly the human's own.

## Golden rules

1. **Don't invent flags.** The cheat sheet below is verified against herdr 0.8.0. For anything else, run `herdr <group>` with no subcommand (it prints that group's commands; `herdr <group> <cmd> --help` prints only the top-level help) or read `references/herdr-cli.md`. Never run bare `herdr` to discover anything (it launches or attaches the TUI), and never probe a mutating command by omitting its arguments (`herdr workspace create` runs with defaults).
2. **IDs are stable and readable — use them.** `w1:p1` (pane), `w1:t1` (tab), `w1` (workspace). They do not shift when other panes open or close, and closed IDs are never reused. A pane moved to another workspace gets a new ID (`.result.move_result.pane.pane_id`).
3. **Target workers by NAME.** `herdr agent start <name> …` registers a name (`[a-z][a-z0-9_-]{0,31}`, unique among live agents); every `agent` command accepts that name or the pane ID hosting the agent. The name clears when the agent exits, so keep the pane ID in your ledger too.
4. **`agent prompt` and `pane run` submit; `pane send-text` only types.** `herdr agent prompt <name> '<text>'` writes text plus Enter atomically and honours bracketed paste — use it for anything aimed at an agent. `herdr pane run <id> '<cmd>'` is text plus Enter for shell commands. `herdr pane send-text` types without Enter; follow it with `herdr pane send-keys <id> enter`. There is no `\n` escape hack.
5. **Single-quote free text — never double-quote it.** Inside double quotes the shell expands `$()`, backticks, and `$VAR` in YOUR (manager) shell before herdr ever sees the text — command injection and credential leakage. If the text itself needs a single quote, rephrase (`don't` → `do not`).
6. **Prefer the native waits over polling loops.** `agent prompt --wait`, `agent wait`, and `pane wait-output` block server-side and return the moment the condition holds. Hand-roll a read-and-sleep loop only to watch several panes at once.
7. **Keep upfront planning human-led.** Confirm the layout/plan with the user before fanning out workers.
8. **Pick the worker model and effort deliberately.** Workers don't need the orchestrator's model tier: the default worker is `claude --model sonnet --effort high` (`--kind claude -- --model sonnet --effort high` in herdr). This applies only to workers you spawn, never to the Manager pane (you).

## Cheat sheet (the basics — no `herdr --help` needed)

**Inspect live state** (do this first, always):
```bash
herdr api snapshot
herdr workspace list
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr agent list
herdr pane current --current
```
`herdr api snapshot` is the one call worth memorizing: one JSON blob with `focused_pane_id`, `focused_tab_id`, `focused_workspace_id`, and per pane `agent`, `agent_status`, `cwd`, `foreground_cwd`, `terminal_title`. Most "what's going on" questions are answerable from it alone.

**Build the layout:**
```bash
herdr pane layout --pane "$HERDR_PANE_ID"
herdr pane split --current --direction right --cwd "$PWD" --no-focus
herdr tab create --workspace w1 --label build --no-focus
herdr workspace create --label feature-x --no-focus
herdr pane close w1:p2
herdr workspace close w2
```
`pane split` takes `right|down` only (plus `--ratio FLOAT`, `--cwd PATH`, `--env KEY=VALUE`) and returns the new pane at `.result.pane.pane_id`; split a wide pane right and a tall one down. `tab create` and `workspace create` return a ready shell at `.result.root_pane.pane_id`. `pane focus`/`resize`/`swap --direction` accept all four directions.

**Start a worker agent** (split, then start — see golden rules 3 and 8):
```bash
herdr pane split --current --direction down --cwd /path/to/repo --no-focus
herdr agent start worker-api --kind claude --pane <new pane_id> -- --model sonnet --effort high
```
`agent start` never creates layout: it needs an existing shell pane sitting at its prompt with nothing in the foreground. `--kind` picks the agent (`herdr agent` lists the kinds: `claude`, `codex`, `opencode`, …); everything after `--` is that agent's own arguments. It returns once herdr sees the agent ready for input (default startup timeout 30 s; `--timeout MS`, at most 300000).

**Name things so workers stay findable:**
```bash
herdr pane rename w1:p2 lane-api
herdr tab rename w1:t1 lane-api
herdr workspace rename w1 feature-x
herdr agent rename worker-api worker-auth
```

**Send work, then read it back:**
```bash
herdr agent prompt worker-api 'Investigate the failing auth test and report back' --wait --timeout 900000
herdr agent read worker-api --source recent-unwrapped --lines 120
herdr pane run w1:p2 'ls -la'
herdr pane read w1:p2 --source visible --lines 20
```
`--source` is `visible` (current screen), `recent` (scrollback), `recent-unwrapped` (scrollback with soft wraps joined — best for logs and transcripts), or, on `agent read` only, `detection`. Add `--format ansi` only when colour is evidence.

**Output is mostly JSON.** Commands print `{"result":{…}}`; server errors print JSON on stderr and exit 1, syntax errors exit 2. `agent read` puts the screen at `.result.read.text`, so a bare `| tail` slices JSON, not the screen. Check a read's shape once before piping it:
```bash
herdr agent read worker-api --source visible --lines 16 | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["read"]["text"])' | tail -8
```

**Wait for something instead of polling** (herdr's best orchestration feature):
```bash
herdr agent wait worker-api --timeout 900000
herdr agent wait worker-api --until blocked --timeout 900000
herdr pane wait-output w1:p2 --regex '(?m)^=== PHASE [0-9]+ DONE ===' --source recent --timeout 900000
herdr pane wait-output w1:p2 --match 'test result' --source recent --timeout 120000
```
Timeouts are **milliseconds**; omitting `--timeout` waits forever. Without `--until`, `agent wait` and `agent prompt --wait` return at the first settled state (`idle`, `done`, or `blocked`); `--until STATUS` is repeatable. `wait-output` takes `--match TEXT` (substring) or `--regex PATTERN` and returns `.result.matched_line`. On success these exit `0`; on timeout they exit non-zero with a JSON error. So `if herdr agent wait … ; then` is a valid control structure — but always confirm with a read before acting.

**Statuses** are `idle|working|blocked|done|unknown`. `idle` means ready for input *and* its tab has been seen in the focused UI; `done` is the same state after unseen background work finished, and CLI reads do not mark it seen — so a background worker that finished usually reads `done`, not `idle`. Never wait `--until idle` alone on an unfocused worker. `blocked` means herdr recognized an approval or question UI. `unknown` proves nothing.

**Keys** (all keys are validated before any byte is written — an unknown name is a hard error, not a silent no-op):
```bash
herdr agent send-keys worker-api enter
herdr agent send-keys worker-api down enter
herdr agent send-keys worker-api ctrl+c
herdr pane send-keys w1:p2 esc
```
Common names: `enter`, `esc`, `tab`, `shift+tab`, `backspace`, `space`, `up` `down` `left` `right`, `ctrl+<x>`, and bare characters like `1` or `y`.

**Git worktrees** (native — no manual `git worktree add` plumbing):
```bash
herdr worktree list   --cwd /path/to/repo
herdr worktree create --cwd /path/to/repo --branch feat/x --base main --label feat-x --no-focus
herdr worktree open   --cwd /path/to/repo --branch feat/x --no-focus
herdr worktree remove --workspace w3 --force
```
`worktree create` opens the new checkout as its own workspace and returns `.result.worktree.path` and a ready shell at `.result.root_pane.pane_id` — start that lane's worker there, so parallel lanes get physically separate checkouts.

**Notify the human:**
```bash
herdr notification show 'Manager' --body 'worker-api is blocked on a question' --sound request
```
`--position top-left|top-right|bottom-left|bottom-right`, `--sound none|done|request`.

**Focus / navigation** (focusing a worker marks its `done` as seen, turning it `idle`):
```bash
herdr pane focus --direction right
herdr agent focus worker-api
herdr tab focus w1:t2
herdr workspace focus w1
herdr pane zoom w1:p2 --toggle
```

## Manager → worker workflow

The human is the CEO and talks only to **you, the Manager**, in the focused pane. You coordinate worker panes; workers do research/implementation.

1. **Plan with the human first.** Agree on how many workers and what each does. Don't fan out on ambiguity.
2. **Spawn each worker by name:** `pane split --current --direction down --cwd <repo> --no-focus`, then `agent start worker-<role> --kind claude --pane <pane_id> -- --model sonnet --effort high`. Record the name and the pane ID.
3. **Delegate.** `herdr agent prompt worker-<role> '<task>'` (single quotes — golden rule 5).
4. **Wait, don't poll.** `herdr agent wait worker-<role> --timeout <ms>`, or `herdr pane wait-output <pane_id> --regex '<anchored done marker>' --source recent --timeout <ms>`.
5. **Inspect, don't assume.** Before reporting or acting, read the worker's actual screen. Never invent output you didn't read.
6. **Report up.** Summarize worker state to the human. If a worker is blocked on a question, read it, decide (or ask the human), and answer it.

A copy-paste Manager prompt and the deeper command catalog are in `references/herdr-cli.md`.

## Answering agents in workers

Workers often run an agent (Claude Code, Codex, opencode) that pauses on a question or approval. The move is **always: read the screen first, then respond to what you actually see.** Two shapes:

- **Free-text / chat prompt** (the agent asks a question and waits for a typed reply): `herdr agent prompt worker-api 'Yes — prefer the existing util, do not add a dep'`.
- **TUI selection menu** (Claude Code permission prompt, Codex approval, y/N confirms): these capture keystrokes, not a line of text.
  - Numbered menu → `herdr agent send-keys worker-api 1`
  - Highlighted list → `herdr agent send-keys worker-api down enter`
  - Plain `[y/N]` → `herdr agent send-keys worker-api y enter`
  - Interrupt a runaway worker → `herdr agent send-keys worker-api ctrl+c`

Exact keys vary by the worker's TUI and change between versions, so **don't memorize a mapping — read the screen, then send the matching key.** Re-read afterward to confirm the prompt was accepted.

`agent_status` reads `blocked` for many of these, so `herdr agent wait <name> --until blocked --timeout <ms>` can wake you the moment a worker needs input — treat it as a wakeup and confirm by reading the screen.

## AFK check-in loop

For "set it and walk away" runs, give a bounded goal with an **interval** and a **stop condition**. Example shape to hand a Manager pane:

> Record a start timestamp. Every 10 minutes, run `herdr api snapshot` and read each worker pane; if a worker is blocked on a question, read it and pick the best answer (or `herdr notification show` me if it's a real decision); if it sits idle without having finished its task, nudge it to continue; leave actively working workers alone. Stop 4 hours after the start timestamp and post a final summary.

Keep the upfront planning human-led; only the periodic mechanical check-ins run unattended.

## Gotchas

- **`pane wait-output` searches what is already on screen**, including your own typed command and any prompt that quotes the marker. Match text that only real output contains, anchor the regex (`--regex '(?m)^=== PHASE [0-9]+ DONE ==='`), and confirm with a read.
- **An omitted pane target can mean the UI-focused pane.** Pass `--current` or an explicit ID, every time.
- **`agent start` needs an idle shell pane.** It never splits; split (or create a tab/workspace/worktree) first.
- **`agent_prompt_stalled` means the prompt changed nothing within five seconds.** Read the screen before re-sending; the agent may be on a dialog.
- **`done`, not `idle`, is what an unfocused worker reports after finishing.** Wait on the settled default or list both.
- **`pane split` is `right|down` only** — no `left`/`up` (use `pane swap` to reorder).
- **Timeouts are milliseconds.** `--timeout 900` is 0.9 seconds, not 15 minutes.
- **A pane ID dies with its pane, and a name dies with its agent.** Re-check `herdr agent list` after a worker exits or is restarted.
- **A bigger `--lines` cannot recover an alternate-screen transcript.** If a long reply is cut off, ask the worker to write it to a temporary Markdown file and reply with the path, then read the file.
- **`herdr integration install claude`** wires Claude Code's hooks into herdr so `working`/`idle`/`blocked` are reported accurately. Without it `agent_status` leans on screen heuristics — check `herdr integration status` if statuses look wrong.
- **Don't close what you didn't create**, and never run `herdr server stop` from an active session: it kills every pane's process.

## When you need more

- Full command catalog, JSON shapes, and the Manager prompt: `references/herdr-cli.md`
- Authoritative, always-current: `herdr --help`, `herdr <group>`, `herdr --skill` (the vendor's agent guide for the installed version), `herdr api schema --json` (the complete request/response JSON Schema), `herdr api snapshot` (live state).
