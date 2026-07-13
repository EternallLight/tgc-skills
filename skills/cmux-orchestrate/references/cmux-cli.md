# cmux CLI reference

Captured from `cmux help` (v0.64.14). The binary is the source of truth — when in doubt run
`cmux help`, `cmux <command> --help`, or `cmux docs <topic>`. This file is the fast path so you
don't have to.

## Table of contents
- [Targeting model (refs, indexes, UUIDs)](#targeting-model)
- [JSON tree shape](#json-tree-shape)
- [Inspect](#inspect)
- [Layout: panes / splits / surfaces](#layout)
- [Workspaces & windows](#workspaces--windows)
- [Naming](#naming)
- [Send / read / keys](#send--read--keys)
- [Notifications & unread](#notifications--unread)
- [Status, progress, log](#status-progress-log)
- [Sidebar (Files / Find / Vault)](#sidebar)
- [Agents, hooks, teams](#agents-hooks-teams)
- [Gotchas](#gotchas)
- [Manager prompt (copy-paste)](#manager-prompt)

## Targeting model
Most commands accept a target via one of: `--window`, `--workspace`, `--pane`, `--surface`
(`tab-action` also takes `--tab`). Accepted forms:
- **short refs**: `window:1`, `workspace:2`, `pane:3`, `surface:4`, `tab:5` (default output format)
- **indexes**: positional integers
- **UUIDs**: full IDs; request them with the global `--id-format uuids` (or `both`)

Defaults when you omit a target: `--surface` → `$CMUX_SURFACE_ID`, `--workspace` → `$CMUX_WORKSPACE_ID`.
That means **omitting `--surface` acts on YOUR pane** — always pass `--surface` to touch a worker.

Global options go **before** the subcommand: `cmux --json tree`, `cmux --id-format both list-panes`.

## JSON tree shape
`cmux --json tree` returns:
- `caller` — the surface that ran the command (**you**): `{ pane_ref, surface_ref, tab_ref, workspace_ref, window_ref, surface_type, is_browser_surface }`
- `active` — the truly focused path (same shape)
- `windows[]` → each `{ ref, index, current, selected_workspace_ref, workspaces[] }`
  - `workspaces[]` → `{ ref, index, title, selected, panes[] }`
  - `panes[]` → `{ ref, index, focused, selected_surface_ref, surface_count, surface_refs[], surfaces[] }`
  - `surfaces[]` → `{ ref, index, title, type (terminal|browser), url, tty, focused, selected, here }`
`here:true` marks your own surface; `focused/active/selected` mark the live path. Browser surfaces carry `url`.

## Inspect
```
cmux tree [--all] [--workspace <t>] [--window <t>]   # box-drawing; markers ◀ active / ◀ here
cmux --json tree [--all]                              # structured
cmux list-windows
cmux list-workspaces [--window <t>]
cmux list-panes [--workspace <t>] [--window <t>]
cmux list-pane-surfaces [--pane <t>] [--workspace <t>]
cmux list-panels [--workspace <t>]
cmux current-window | current-workspace
cmux top [--processes] [--sort cpu|mem|proc] [--flat] [--format tree|tsv]   # per-pane process/resource view
cmux memory [--all] [--groups <n>]
cmux identify [--surface <t>] ...                     # what/where is this surface
cmux capabilities                                     # what this cmux build supports
```

## Layout
```
cmux new-split <left|right|up|down> [--surface <t>] [--panel <t>] [--focus true|false]
cmux new-pane [--type terminal|browser] [--direction left|right|up|down] [--url <url>] [--focus ...]
cmux new-surface [--type terminal|browser] [--pane <t>] [--url <url>]   # new tab inside a pane
cmux close-surface [--surface <t>]
cmux move-surface --surface <t> [--pane <t>] [--before|--after <t>] [--index <n>]
cmux split-off --surface <t> <left|right|up|down>     # pop a surface into its own split
cmux reorder-surface --surface <t> (--index <n> | --before <t> | --after <t>)
cmux focus-pane --pane <t>
cmux focus-panel --panel <t>
cmux focus-window --window <id>
cmux refresh-surfaces
```
Browser-pane helpers exist too (`cmux browser ...`, `cmux new-pane --type browser --url ...`).

## Workspaces & windows
```
cmux new-workspace [--name <title>] [--description <text>] [--cwd <path>] [--command <text>] [--focus ...]
cmux select-workspace --workspace <t>
cmux close-workspace --workspace <t>
cmux move-tab-to-new-workspace [--surface <t>] [--title <text>]
cmux reorder-workspace --workspace <t> (--index <n> | --before <t> | --after <t>)
cmux workspace-action --action <name> [--workspace <t>] [--title <text>] [--color <name|#hex>]
cmux new-window | close-window --window <id> | focus-window --window <id>
cmux move-workspace-to-window --workspace <t> --window <t>
```

## Naming
```
cmux rename-tab [--surface <t>] [--tab <t>] <title>
cmux rename-workspace [--workspace <t>] <title>
cmux rename-window [--window <t>] <title>
```

## Send / read / keys
```
cmux send [--surface <t>] [--] <text>        # types text; \n,\r=Enter  \t=Tab. Append \n to submit.
cmux send-key [--surface <t>] [--] <key>     # one key event: enter, tab, up, down, left, right,
                                             #   ctrl+c, ctrl+d, esc, "1", "y", ...
cmux send-panel --panel <t> <text>           # same but target a panel
cmux send-key-panel --panel <t> <key>
cmux read-screen [--surface <t>] [--scrollback] [--lines <n>]   # plain-text screen dump
```
Read-then-respond is the safe loop for answering an agent's question in a worker (see SKILL.md).
`read-screen` is for terminal surfaces; for a browser surface read its `url`/use `cmux browser`.

## Notifications & unread
```
cmux jump-to-unread                          # Cmd+Shift+U equivalent
cmux list-notifications
cmux open-notification --id <uuid>
cmux mark-notification-read (--id <uuid> | --workspace <t> | --all)
cmux dismiss-notification (--id <uuid> | --all-read)
cmux clear-notifications [--workspace <t>]
cmux notify --title <text> [--subtitle <text>] [--body <text>] [--surface <t>]
cmux trigger-flash [--surface <t>]
```

## Status, progress, log
Use these to surface Manager state to the human, especially during AFK runs.
```
cmux set-status <key> <value> [--icon <name>] [--color <#hex>] [--priority <n>]
cmux clear-status <key>      |  cmux list-status
cmux set-progress <0.0-1.0> [--label <text>]   |  cmux clear-progress
cmux log [--level <level>] [--source <name>] <message>   |  cmux list-log [--limit <n>]  |  cmux clear-log
```

## Sidebar
```
cmux right-sidebar <toggle|show|hide|focus|files|find|vault|sessions|feed|dock> [--no-focus]
cmux sidebar <validate|reload|select> [name]
```
Vault = past conversations you can resume in a new tab.
In the GUI: Cmd+Alt+B opens the right sidebar; 1/2/3 switch Files/Find/Vault.

## Agents, hooks, teams
```
cmux docs agents            # agent hook integrations, feed approvals, notifications, session restore
cmux hooks setup [<agent>]  # install cmux hooks for an agent (e.g. so its notifications reach cmux)
cmux hooks <agent> <install|uninstall|event>
cmux claude-teams [claude-args...]   # launch Claude in a team layout — pass worker model/effort, e.g. cmux claude-teams --model sonnet --effort high
cmux codex-teams  [codex-args...]    # launch Codex in a team layout
cmux omo|omx|omc [args...]           # opencode / omx / omc launchers
cmux restore-session | cmux surface resume <set|show|get|clear>
```

## Gotchas
- `--json` and `--id-format` are **global** — before the subcommand.
- `cmux send` without a trailing `\n` only types; it won't run/submit.
- Omitting `--surface` targets **your own** pane (`$CMUX_SURFACE_ID`). Pass `--surface` for workers.
- Refs/indexes shift as panes open/close — re-run `cmux --json tree` right before acting; use `--id-format uuids` for durable IDs across a long run.
- Prefer panes over tab groups (easy to lose track of tab groups).
- Config: `~/.config/cmux/cmux.json` and Ghostty at `~/.config/ghostty/config`; `cmux reload-config` reloads both in place. Back up `cmux.json` to a timestamped `.bak` before editing.

## Manager prompt
A copy-paste Manager prompt (adapt refs/roles to the current workspace):

> You are the Manager agent running in my focused cmux pane. I will only talk to you; you coordinate
> worker panes. Use the REAL cmux CLI (do not invent flags). Keep upfront planning human-led — confirm
> the plan with me before delegating.
> 1. Build the layout: `cmux new-split right`, `cmux new-pane`; name tabs `cmux rename-tab "<role>"`.
> 2. Launch each Claude Code worker: `cmux send --surface surface:N -- "claude --model sonnet --effort high\n"`.
> 3. Inspect live state before acting: `cmux --json tree`, `cmux list-panes`.
> 4. Delegate then read back: `cmux send --surface surface:N -- "<task>\n"`, then `cmux read-screen --surface surface:N`.
> 5. You talk to me; workers do the work. Report status; don't let workers drift — re-check `cmux --json tree`.
> Guardrail: prefer panes over tab groups.
