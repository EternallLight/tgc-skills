# herdr CLI reference

Captured from `herdr --help`, the per-group command lists (`herdr <group>` with no subcommand), and `herdr api schema --json` for **herdr 0.8.0**, protocol 19. The binary is the source of truth — when in doubt run `herdr <group>`, `herdr --skill`, or `herdr api schema --json`. This file is the fast path so you don't have to.

`herdr <group> <cmd> --help` does **not** print per-command help in 0.8.0; it prints the top-level help. Run the group bare instead. Never run bare `herdr` for discovery (it launches or attaches the TUI), and never omit arguments to probe a mutating command (`workspace create`, `tab create`, `worktree create` all run with defaults).

## Table of contents
- [Architecture & targeting model](#architecture--targeting-model)
- [Environment variables](#environment-variables)
- [Snapshot / JSON shapes](#snapshot--json-shapes)
- [Inspect](#inspect)
- [Layout: panes, tabs, workspaces](#layout-panes-tabs-workspaces)
- [Naming](#naming)
- [Send / read / keys](#send--read--keys)
- [Waiting](#waiting)
- [Agents](#agents)
- [Worktrees](#worktrees)
- [Notifications](#notifications)
- [Sessions, server, integrations](#sessions-server-integrations)
- [Gotchas](#gotchas)
- [Manager prompt (copy-paste)](#manager-prompt)

## Architecture & targeting model

herdr runs a **headless server** that owns the terminal state, plus thin clients (the TUI you look at, and the `herdr` CLI) that talk to it over a Unix socket. Two consequences for orchestration:

1. **The CLI works from any shell**, inside herdr or not. `herdr pane list` succeeding proves the *server* is up, not that *you* are in a pane. Gate on `$HERDR_PANE_ID`, which is what the skill's `detect-backend.sh` gate checks first.
2. **State is server-side and durable.** Sessions survive client detach (`herdr session attach <name>`, `herdr --remote <ssh-target>`), so a long orchestration run is not tied to your window staying open.

**IDs** are hierarchical, stable, opaque handles:

| Kind | Form | Example |
|---|---|---|
| Workspace | `w<N>` | `w1` |
| Tab | `w<N>:t<M>` | `w1:t1` |
| Pane | `w<N>:p<M>` | `w1:p2` |
| Terminal | `term_<hex>` | `term_65707963df69a1` |

They do **not** renumber when neighbouring panes open or close, and closed tab and pane IDs are never reused. A pane moved into another workspace gets a new pane ID: continue with `.result.move_result.pane.pane_id` (the old one is `.result.move_result.previous_pane_id`). Read IDs from JSON responses; never derive them from sidebar order or examples.

`agent` subcommands take a **target**: a unique live agent name or the pane ID currently hosting that agent. They do **not** accept terminal IDs or bare agent-kind labels. A name follows the pane's current occupant and is cleared when that agent exits, is released, or is replaced.

Pane commands that take `[<pane_id>|--pane ID|--current]` resolve `--current` to the calling pane. Omitting the target may resolve to the UI-focused pane, which can belong to the user or another client — always pass one.

## Environment variables

Set **inside** a herdr pane (this is how a pane identifies itself):

| Variable | Meaning |
|---|---|
| `HERDR_PANE_ID` | this pane, e.g. `w1:p2` — the variable `detect-backend.sh` gates on |
| `HERDR_ENV` | `1` inside a herdr-managed pane |
| `HERDR_WORKSPACE_ID` | e.g. `w1` |
| `HERDR_TAB_ID` | e.g. `w1:t1` |
| `HERDR_SESSION` | named session, **empty for the default session** — do not gate on this |
| `HERDR_SOCKET_PATH` | server socket |
| `HERDR_CLIENT_SOCKET_PATH` | client socket |
| `HERDR_BIN_PATH` | the herdr binary that spawned the pane |

Client-side / config:

| Variable | Meaning |
|---|---|
| `HERDR_CONFIG_PATH` | overrides `~/.config/herdr/config.toml` |
| `HERDR_LOG` | log verbosity |

## Snapshot / JSON shapes

`herdr api snapshot` is the single best inspection call — one JSON blob with everything:

```
.result.snapshot
  .protocol            protocol version (19)
  .version             herdr version ("0.8.0")
  .focused_workspace_id / .focused_tab_id / .focused_pane_id
  .workspaces[]        { workspace_id, label, number, focused, active_tab_id,
                         tab_count, pane_count, agent_status, worktree, tokens }
  .tabs[]              { tab_id, workspace_id, label, number, focused, pane_count, agent_status }
  .panes[]             { pane_id, tab_id, workspace_id, terminal_id, focused, label, title,
                         cwd, foreground_cwd, agent, display_agent, agent_status,
                         agent_session, revision, terminal_title, terminal_title_stripped,
                         scroll, state_labels, tokens }
  .agents[]            { name, pane_id, tab_id, workspace_id, terminal_id, agent, agent_status,
                         interactive_ready, launch_pending, state_change_seq,
                         cwd, foreground_cwd, … }
  .layouts[]           { workspace_id, tab_id, zoomed, focused_pane_id, area, panes[], splits[] }
```

Useful derived facts: `cwd` vs `foreground_cwd` (the latter tracks the running process, so it shows where a worker actually is); `agent` names the detected tool (`claude`, `codex`, `opencode`, …); `name` is the handle `agent start` registered; `interactive_ready` says the agent can take input.

`agent_status` is `idle|working|blocked|done|unknown`:
- `idle` — ready for input, and its tab has been seen in the focused UI.
- `done` — the same idle state after **unseen** background work finished. Focusing the tab, or a focus command on the pane or agent, marks it seen; CLI reads do not. An unfocused worker that finished therefore reads `done`.
- `blocked` — herdr recognized an approval or question UI.
- `unknown` — an agent is present but herdr cannot classify it; it does not prove completion.

Most CLI commands print a JSON envelope: `{"id":"cli:<group>:<cmd>","result":{…,"type":"<kind>"}}`. Server errors print `{"error":{"code":"<code>","message":"…"}}` on stderr and exit 1; CLI syntax errors exit 2. Creation results expose the IDs to use next:

| Command | Result |
|---|---|
| `workspace create` | `.result.workspace`, `.result.tab`, `.result.root_pane` |
| `tab create` | `.result.tab`, `.result.root_pane` |
| `pane split` | `.result.pane` |
| `worktree create` | `.result.workspace`, `.result.tab`, `.result.root_pane`, `.result.worktree` |
| `agent start` | `.result.agent` (with `name`, `pane_id`), `.result.argv` |
| `pane wait-output` | `.result.matched_line`, `.result.read` |

Reads carry the screen at `.result.read.text`. Check a read's output shape once before piping it to `tail`.

`herdr api schema [--json | --output PATH]` dumps the complete request/response JSON Schema — the authoritative answer for any flag or field question this file doesn't cover.

## Inspect

```
herdr api snapshot
herdr api schema [--json|--output PATH]
herdr status [server|client]
herdr workspace list
herdr workspace get <workspace_id>
herdr tab list [--workspace <workspace_id>]
herdr tab get <tab_id>
herdr pane list [--workspace <workspace_id>]
herdr pane get <pane_id>
herdr pane current [--pane ID|--current]
herdr pane layout [--pane ID|--current]
herdr pane process-info [--pane ID|--current]
herdr pane edges [--pane ID|--current]
herdr pane neighbor --direction left|right|up|down [--pane ID|--current]
herdr agent list
herdr agent get <target>
herdr agent explain <target> [--json|--format text|json] [--verbose]
herdr agent explain --file PATH --agent LABEL [--json|--format text|json] [--verbose]
```

`agent explain` says why herdr classified a pane as it did — the first stop when `agent_status` looks wrong.

## Layout: panes, tabs, workspaces

```
herdr pane split [<pane_id>|--pane ID|--current] --direction right|down
                 [--ratio FLOAT] [--cwd PATH] [--env KEY=VALUE] [--focus] [--no-focus]
herdr pane close <pane_id>
herdr pane focus --direction left|right|up|down [--pane ID|--current]
herdr pane resize --direction left|right|up|down [--amount FLOAT] [--pane ID|--current]
herdr pane zoom [<pane_id>|--pane ID|--current] [--toggle|--on|--off]
herdr pane swap --direction left|right|up|down [--pane ID|--current]
herdr pane swap --source-pane ID --target-pane ID
herdr pane move <pane_id> --tab <tab_id> --split right|down [--target-pane ID] [--ratio FLOAT] [--focus|--no-focus]
herdr pane move <pane_id> --new-tab [--workspace ID] [--label TEXT] [--focus|--no-focus]
herdr pane move <pane_id> --new-workspace [--label TEXT] [--tab-label TEXT] [--focus|--no-focus]

herdr tab create [--workspace <workspace_id>] [--cwd PATH] [--label TEXT] [--env KEY=VALUE] [--focus] [--no-focus]
herdr tab focus <tab_id> | herdr tab close <tab_id>

herdr workspace create [--cwd PATH] [--label TEXT] [--env KEY=VALUE] [--focus] [--no-focus]
herdr workspace focus <workspace_id> | herdr workspace close <workspace_id>
```

**Splits are `right|down` only.** To get a pane on the left/up, split then `pane swap`. `pane focus`/`resize`/`swap --direction` accept all four directions. Split a wide pane right and a narrow or tall one down; repeated same-direction splits make unusably thin panes. Use `--no-focus` for background work so the human keeps their focus.

## Naming

```
herdr pane rename <pane_id> <label>|--clear
herdr tab rename <tab_id> <label>
herdr workspace rename <workspace_id> <label>
herdr agent rename <target> <name>|--clear
```

Renaming the **agent** changes its target handle.

## Send / read / keys

```
herdr agent prompt    <target>  <text> [--wait] [--until STATUS]... [--timeout MS]
herdr pane run        <pane_id> <command>
herdr pane send-text  <pane_id> <text>
herdr agent send-keys <target>  <key> [key ...]
herdr pane send-keys  <pane_id> <key> [key ...]
herdr agent read <target>  [--source visible|recent|recent-unwrapped|detection] [--lines N] [--format text|ansi] [--ansi]
herdr pane  read <pane_id> [--source visible|recent|recent-unwrapped] [--lines N] [--format text|ansi] [--ansi]
```

- `agent prompt` submits text **and** Enter atomically, honouring the pane's live bracketed-paste mode — the way to hand an agent work or answer its free-text question.
- `pane run` is text plus Enter for a shell command; `pane send-text` types without Enter.
- `--source`: `visible` = current viewport; `recent` = recent output with soft wraps; `recent-unwrapped` = soft wraps joined (best for logs and transcripts); `detection` (`agent read` only) = the bottom-buffer snapshot herdr uses to classify the agent. ANSI is stripped unless `--format ansi`/`--ansi`.
- `--lines` pulls more rows from the screen and host scrollback, but rows that scrolled off an agent's **alternate screen** never enter scrollback. If more lines don't reveal a completed reply, ask the agent to write it to a temporary Markdown file and reply with the path, then read the file.

Key names are **validated before any byte is written**; an unknown name is a hard error, never a silent no-op. Common names: `enter`, `esc`, `tab`, `shift+tab`, `backspace`, `space`, `up`, `down`, `left`, `right`, `ctrl+<x>`, and bare characters (`1`, `y`). Names are case-insensitive.

## Waiting

The feature that removes hand-rolled polling loops from orchestration. **Timeouts are in milliseconds**; omitting `--timeout` waits indefinitely. Success → exit `0` + JSON result. Timeout or error → non-zero exit + JSON error.

```
herdr agent wait <target> [--until STATUS]... [--timeout MS]
herdr agent prompt <target> <text> --wait [--until STATUS]... [--timeout MS]
herdr pane wait-output <pane_id> (--match TEXT | --regex PATTERN)
                       [--source visible|recent|recent-unwrapped] [--lines N] [--timeout MS] [--raw]
```

- Without `--until`, `agent wait` and `agent prompt --wait` return at the first **settled** state: `idle`, `done`, or `blocked`. Don't repeat those defaults with `--until`; use it for a specific state (`--until blocked` to wake when a worker needs input). `--until` is repeatable.
- `agent prompt` sent from a non-working state must cause a lifecycle change within five seconds, or it fails with `agent_prompt_stalled` instead of waiting forever. The wait tracks lifecycle state, not one turn: if the agent was already working, the active turn finishing can satisfy it.
- `pane wait-output` takes `--match` (literal substring) or `--regex` (Rust regex; prefix `(?m)` so `^` and `$` anchor lines) and searches the selected snapshot **immediately**, so text already on screen can match. It returns `.result.matched_line` plus the full `.result.read`, so one call both waits and gives you the screen.

Usable directly as control flow:
```bash
if herdr pane wait-output w1:p2 --regex '(?m)^=== PHASE [0-9]+ DONE ===' --source recent --timeout 900000 >/dev/null; then
  echo "phase marker seen"
else
  echo "timed out — sweep the pane manually"
fi
```

**The echo trap:** the command you typed, and any prompt that quotes the marker, is on screen too, so a naive `--match FOO` fires on the echo, not on real output. Anchor the regex, match on text that only appears in genuine output, or verify with a read afterwards.

## Agents

```
herdr agent start <name> --kind KIND --pane ID [--timeout MS] [-- <agent-args...>]
herdr agent list | get <target> | read <target>
herdr agent prompt <target> <text> [--wait] [--until STATUS]... [--timeout MS]
herdr agent send-keys <target> <key> [key ...]
herdr agent rename <target> <name>|--clear
herdr agent focus <target>
herdr agent wait <target> [--until STATUS]... [--timeout MS]
herdr agent attach <target> [--takeover]
herdr agent explain <target> [--json|--format text|json] [--verbose]
```

Kinds (`herdr agent` prints the current list): `pi`, `claude`, `codex`, `gemini`, `cursor`, `devin`, `agy`, `cline`, `omp`, `mastracode`, `opencode`, `copilot`, `kimi`, `kiro`, `droid`, `amp`, `grok`, `hermes`, `kilo`, `qodercli`, `maki`.

`agent start` **never creates, splits, or moves layout.** It launches the agent in an existing shell pane that sits at its interactive prompt with no foreground command, editor, or agent, and registers the name. Names match `[a-z][a-z0-9_-]{0,31}` and must be unique among live agents. Everything after `--` is the agent's own arguments. It returns only after herdr detects the expected agent ready for input; the startup timeout defaults to 30 s and must be over 3000 and at most 300000 ms.

```bash
herdr pane split --current --direction down --cwd /repo/api --no-focus
herdr agent start worker-api --kind claude --pane <pane_id> -- --model sonnet --effort high
herdr agent start worker-web --kind codex --pane <pane_id> -- -c model_reasoning_effort=medium
```

Address the worker by **name** thereafter, and keep `.result.agent.pane_id` for pane commands.

Panes can also self-report agent state (this is what the integrations use):
```
herdr pane report-agent <pane_id> --source ID --agent LABEL --state idle|working|blocked|unknown
                                  [--message TEXT] [--seq N] [--agent-session-id ID] [--agent-session-path PATH]
herdr pane report-agent-session <pane_id> --source ID --agent LABEL [--seq N] [--agent-session-id ID] [--agent-session-path PATH]
herdr pane release-agent <pane_id> --source ID --agent LABEL [--seq N]
herdr pane report-metadata <pane_id> --source ID [--agent LABEL] [--title TEXT|--clear-title]
                                     [--display-agent TEXT|--clear-display-agent] [--state-label STATUS=TEXT]
                                     [--token NAME=VALUE] [--clear-token NAME] [--seq N] [--ttl-ms N] …
```

## Worktrees

Native git-worktree management — each worktree opens as its own workspace, which is the clean way to give parallel lanes physically separate checkouts.

```
herdr worktree list   [--workspace ID | --cwd PATH]
herdr worktree create [--workspace ID | --cwd PATH] [--branch NAME] [--base REF] [--path PATH]
                      [--label TEXT] [--focus] [--no-focus]
herdr worktree open   [--workspace ID | --cwd PATH] (--path PATH | --branch NAME)
                      [--label TEXT] [--focus] [--no-focus]
herdr worktree remove --workspace ID [--force]
```

Output is JSON; there is no `--json` flag. `worktree list` returns `.result.source` (`repo_root`, `repo_name`, `repo_key`, `source_checkout_path`, `source_workspace_id`) and `.result.worktrees[]` (`path`, `branch`, `label`, `is_bare`, `is_detached`, `is_linked_worktree`, `is_prunable`, `open_workspace_id`). `worktree create` returns the new checkout at `.result.worktree.path` and its ready shell at `.result.root_pane.pane_id` — start the lane's worker there. `worktree open` adds `.result.already_open`.

## Notifications

```
herdr notification show <title> [--body TEXT]
                                [--position top-left|top-right|bottom-left|bottom-right]
                                [--sound none|done|request]
```

## Sessions, server, integrations

```
herdr
herdr --session <name>
herdr --remote <ssh-target> [--session <name>] [--remote-keybindings local|server] [--handoff]
herdr --no-session
herdr session list [--json] | attach <name> | stop <name> [--json] | delete <name> [--json]
herdr server stop | herdr server reload-config | herdr server
herdr update [--handoff]
herdr channel show | herdr channel set <stable|preview>
herdr config check | herdr config reset-keys
herdr completion <shell>
herdr --default-config
herdr --skill
herdr integration install|uninstall <agent>
herdr integration status [--outdated-only]
herdr terminal attach <terminal_id> [--takeover]
herdr terminal session control|observe <target> [--cols N] [--rows N]
herdr terminal title set <title> | herdr terminal title clear
```

- Bare `herdr` launches or attaches the persistent session; `--session` names one; `--no-session` is the monolithic escape hatch. `session stop default` targets the default session.
- `herdr server` runs headless; `server stop` kills every pane's process — never run it from an active session unless the user means exactly that.
- `update --handoff` updates live without dropping panes.
- `--skill` prints herdr's own agent guide for the installed version.
- Integrations: `pi`, `omp`, `claude`, `codex`, `copilot`, `devin`, `droid`, `kimi`, `opencode`, `kilo`, `hermes`, `qodercli`, `cursor`, `mastracode`, `antigravity-cli`, `grok`.

**`herdr integration install claude` matters for orchestration.** It installs Claude Code hooks that report real agent state to herdr, which is what makes `agent_status` and `agent wait` trustworthy. Without it herdr falls back to screen-detection heuristics. If waits misfire, check `herdr integration status` first, then `herdr agent explain <target>`.

Config lives at `~/.config/herdr/config.toml`; logs at `~/.config/herdr/herdr.log` (plus `herdr-client.log`, `herdr-server.log`).

## Gotchas

- **The CLI answers from outside herdr.** A working `herdr` command proves the server is up, not that you are in a pane. Gate on `$HERDR_PANE_ID`.
- **An omitted pane target can mean the UI-focused pane** — someone else's, quite possibly the human's. Pass `--current` or an explicit ID.
- **`agent start` needs an idle shell pane** and never splits. Create the pane first.
- **`done` vs `idle`:** an unfocused worker that finished reports `done`. Wait on the settled default rather than `--until idle`.
- **`wait-output` matches what is already on screen**, including the echoed command. Anchor your regex.
- **Timeouts are milliseconds.** `--timeout 900` = 0.9 s.
- **Splits are `right|down` only.**
- **`HERDR_SESSION` is empty for the default session** — a falsy check on it is not a herdr check.
- **Names and IDs are not eternal.** A name clears when its agent exits or is replaced; a moved pane gets a new ID; a closed pane's ID is never reused.
- **`<cmd> --help` prints the top-level help.** Use `herdr <group>` for the command list.

## Manager prompt

A copy-paste Manager prompt (adapt ids/roles to the current workspace):

> You are the Manager agent running in my focused herdr pane. I will only talk to you; you coordinate worker panes. Use the REAL herdr CLI (do not invent flags; `herdr <group>` prints each group's commands). Keep upfront planning human-led — confirm the plan with me before delegating.
> 1. Confirm you are in herdr: `[ -n "$HERDR_PANE_ID" ]`. The CLI works from anywhere, so this gate is what distinguishes you from a stray shell.
> 2. Inspect live state: `herdr api snapshot`.
> 3. Spawn each worker by name: `herdr pane split --current --direction down --cwd <repo> --no-focus`, then `herdr agent start worker-<role> --kind claude --pane <pane_id> -- --model sonnet --effort high`. Address workers by NAME from then on.
> 4. Delegate: `herdr agent prompt worker-<role> '<task>'` (always single quotes — double quotes let the shell expand `$()`/`$VAR` in MY pane).
> 5. Wait instead of polling: `herdr agent wait worker-<role> --timeout <ms>`, then read the screen with `herdr agent read worker-<role> --source recent-unwrapped --lines 40`.
> 6. You talk to me; workers do the work. Report status; never invent output you did not read.
