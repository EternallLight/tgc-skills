---
name: cmux-orchestrate
description: Use when orchestrating cmux terminal panes, splits, tabs, worker sessions, or agents in other cmux panes, including reading screens, sending commands, answering prompts, jumping to unread activity, or setting AFK check-ins. Do not use for tmux, IDE/browser tabs, deployment replicas, or plain command execution.
---

# cmux Orchestrate

Drive a cmux terminal workspace — build pane layouts, name tabs, send work to worker panes, read their screens, and answer the agents running inside them — translating the user's plain English into real `cmux` CLI calls fast, without paging through help every time.

cmux is **agent-first**: it exposes a Unix-socket CLI so an agent can inspect and control the whole window/workspace/pane/surface tree. You don't memorize a GUI; you read the surface and act on it.

Trigger eagerly even when the user does not say "cmux" but is clearly orchestrating terminal panes: "open a pane", "split the terminal", "the agent in my other tab", "my worker panes", "check the other pane", "send X to the left pane", or "jump to whatever needs input".

## 0. Gate: are we even in cmux?

Before running any `cmux` command, confirm the environment:

```bash
[ -n "$CMUX_SURFACE_ID" ] && echo "in cmux: surface $CMUX_SURFACE_ID" || echo "NOT in cmux"
```

If `$CMUX_SURFACE_ID` is empty, you are **not** in a cmux workspace. Tell the user, and do not run cmux orchestration commands. (`cmux` may still launch a *new* workspace via `cmux <path>`, but pane/surface control assumes you're inside one.)

`$CMUX_SURFACE_ID` is **this pane** (where you're running). That's how you tell yourself apart from workers.

## Golden rules

1. **Don't invent flags.** The cheat sheet below is verified. For anything else, check `cmux <command> --help` or `references/cmux-cli.md`. The CLI is the source of truth; your memory of it may be stale.
2. **`--json` is a global flag — it goes BEFORE the subcommand:** `cmux --json tree`, not `cmux tree --json`.
3. **Re-inspect before you act on a worker.** Refs like `surface:21` / `pane:19` and indexes can shift as panes open/close. Run `cmux --json tree` (or `cmux list-panes`) to get current refs right before targeting one. Need durable IDs? add `--id-format uuids`.
4. **`cmux send` only TYPES text.** To make a worker actually run a command or submit a prompt, it must receive Enter. For short commands, ending the text with `\n` works (`\n`/`\r` → Enter, `\t` → Tab). For long prompts, a trailing `\n` is often swallowed into a bracketed paste — send the text first, then submit with a separate `cmux send-key --surface surface:N enter`.
5. **Single-quote free text — never double-quote it.** Always pass task text as `-- '<task>'`. Inside double quotes the shell expands `$()`, backticks, and `$VAR` in YOUR (manager) shell before cmux ever sees the text — command injection and credential leakage. If the text itself needs a single quote, rephrase to avoid it (e.g. `don't` → `do not`).
6. **Prefer panes over tab groups** — tab groups are easy to lose track of.
7. **Keep upfront planning human-led.** Confirm the layout/plan with the user before fanning out workers.
8. **Pick the worker model and effort deliberately.** Workers don't need the orchestrator's model tier — a cheaper model (e.g. `claude --model sonnet`) keeps cost and latency down. Effort follows the task: `high` for open-ended research or investigation; `medium` for well-specified implementation against a locked plan (the `orchestrate-plan` skill mandates this). This applies only to workers you spawn, never to the Manager pane (you).

## Cheat sheet (the basics — no `cmux help` needed)

**Inspect live state** (do this first, always):
```bash
cmux --json tree        # full window/workspace/pane/surface tree as JSON
cmux tree               # same, human box-drawing view: ◀ active, ◀ here(=you)
cmux list-panes         # enumerate panes
cmux list-pane-surfaces # surfaces (tabs) within panes
```
In the JSON: `caller` = you, `active` = the focused pane/surface, each node has a `ref` (`pane:N`/`surface:N`), `focused`/`selected` flags, and titles.

**Build the layout:**
```bash
cmux new-split right                 # split current pane (left|right|up|down)
cmux new-pane                        # new pane; --direction left|right|up|down
cmux new-pane --type browser --url https://example.com   # browser pane
cmux new-surface                     # new surface (tab) inside a pane
cmux new-workspace --name "build"    # whole new workspace
```

**Start a Claude Code worker in a fresh pane** (see golden rule 8 on model choice):
```bash
cmux new-pane --direction right
cmux send --surface surface:N -- 'claude --model sonnet --effort high\n'   # launch the worker agent
# then delegate the task once it's up (single quotes — golden rule 5):
cmux send --surface surface:N -- 'Investigate the failing auth test and report back\n'
```

**Name things so workers stay findable:**
```bash
cmux rename-tab "manager"
cmux rename-tab --surface surface:2 "worker-tests"
cmux rename-workspace "feature-x"
```

**Target a specific worker** — every action takes `--surface surface:N` (or `--pane`, `--workspace`, `--window`). Default target is your own surface (`$CMUX_SURFACE_ID`), so you MUST pass `--surface` to act on someone else.

**Send work into a worker, then read it back:**
```bash
cmux send --surface surface:2 -- 'ls -la\n'          # run a command (note \n)
cmux send --surface surface:2 -- 'Investigate the failing auth test and report back\n'  # prompt an agent
cmux read-screen --surface surface:2                 # read its visible screen
cmux read-screen --surface surface:2 --scrollback --lines 200   # deeper history
```
Use `--` before free text so leading dashes/special chars aren't parsed as flags, and single quotes so the manager shell can't expand anything inside the text (golden rule 5).

**Answer the agent running in a worker pane** (the key cross-pane move): `read-screen` to SEE the question first, then respond — see **Answering agents in workers** below for the chat vs TUI variants.

**Notifications / jump to what needs you:**
```bash
cmux jump-to-unread          # = Cmd+Shift+U: jump to a pane with unread activity
cmux list-notifications
cmux focus-pane --pane pane:3
```

**Surface your own status to the human (optional, nice for AFK runs):**
```bash
cmux set-status state "checking workers" --icon eye
cmux set-progress 0.4 --label "2/5 workers done"
cmux notify --title "Manager" --body "worker-3 is blocked on a question"
```

## Manager → worker workflow

The human is the CEO and talks only to **you, the Manager**, in the focused pane. You coordinate worker panes; workers do research/implementation.

1. **Plan with the human first.** Agree on how many workers and what each does. Don't fan out on ambiguity.
2. **Build the layout.** `cmux new-split right` / `cmux new-pane` per worker; name each with `cmux rename-tab --surface surface:N "<role>"` so they're findable (new panes spawn unfocused — omitting `--surface` renames YOUR tab, not the worker's).
3. **Launch each worker agent.** `cmux send --surface surface:N -- 'claude --model sonnet --effort high\n'` before delegating (golden rule 8).
4. **Delegate.** `cmux send --surface surface:N -- '<task>\n'` into each worker (single quotes — golden rule 5; long prompts: send text, then a separate `send-key enter`).
5. **Inspect, don't assume.** Before reporting or acting, `cmux --json tree` to see current refs, then `cmux read-screen --surface surface:N` to read each worker's actual output. Never invent output you didn't read.
6. **Report up.** Summarize worker state to the human. If a worker is blocked on a question, read it, decide (or ask the human), and answer it via `send`/`send-key`.

A copy-paste Manager prompt and the deeper command catalog are in `references/cmux-cli.md`.

## Answering agents in workers

Workers often run an agent (Claude Code, Codex, opencode) that pauses on a question or approval. The move is **always: `read-screen` first, then respond to what you actually see.** Two shapes:

- **Free-text / chat prompt** (agent asks a question and waits for a typed reply): send the answer with a trailing newline to submit.
  `cmux send --surface surface:2 -- 'Yes — prefer the existing util, do not add a dep\n'`

- **TUI selection menu** (Claude Code permission prompt, Codex approval, y/N confirms): these capture keystrokes, not a line of text. Read which option you want, then drive the keys.
  - Numbered menu → send the number: `cmux send-key --surface surface:2 -- "1"`
  - Highlighted list → `cmux send-key --surface surface:2 down` then `cmux send-key --surface surface:2 enter`
  - Plain `[y/N]` → `cmux send-key --surface surface:2 -- "y"` then (if needed) `enter`
  - Need to interrupt a runaway worker → `cmux send-key --surface surface:2 ctrl+c`

Exact keys vary by the worker's TUI and change between versions, so **don't memorize a mapping — read the screen, then send the matching key.** Re-read with `read-screen` afterward to confirm the prompt was accepted.

## AFK check-in loop

For "set it and walk away" runs, give a bounded goal with an **interval** and a **stop condition**. Example shape to hand a Manager pane:

> Record a start timestamp. Every 10 minutes, `cmux --json tree` then `cmux read-screen` each worker surface; if a worker is blocked on a question, read it and pick the best answer (or `cmux notify` me if it's a real decision); if it sits idle without having finished its task, nudge it to continue; leave actively working (spinner-running) workers alone. Stop 4 hours after the start timestamp and post a final summary.

Keep the upfront planning human-led; only the periodic mechanical check-ins run unattended.

## When you need more

- Full command catalog, JSON tree shape, and gotchas: `references/cmux-cli.md`
- Authoritative, always-current: `cmux help`, `cmux <command> --help`, `cmux docs <topic>` (settings|shortcuts|api|browser|agents|dock|sidebars).
