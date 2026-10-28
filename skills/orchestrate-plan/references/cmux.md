# cmux backend

cmux addresses a worker by a `surface:N` ref. Commands below match cmux 0.64.20; `cmux <command>
--help` wins over this file. Deeper CLI notes live in `tgc-skills:cmux-orchestrate`.

**The one destructive trap:** an empty or omitted `--surface` targets **your own** pane. Record
each lane's literal ref in the lane ledger and inline it in every command; `"$W"` below stands for
that literal ref, because shell variables do not survive between tool calls. Refs can shift as
panes open and close, so re-confirm with `cmux --json tree` (match the tab title) before acting,
or use durable ids with `--id-format uuids`.

## Gate

`detect-backend.sh` printing `cmux` means `$CMUX_SURFACE_ID` is set; that value is your own
surface, which is how you tell yourself apart from workers.

## Create the lane worktree and branch

```bash
git -C '<repo>' fetch origin '<default-branch>'
git -C '<repo>' worktree add --no-track -b <change-slug> '<repo>-<change-slug>' origin/<default-branch>
```

## Start a worker

Split, capture the ref, and name the tab. The guard is mandatory:

```bash
W=$(cmux --json new-split right --focus false | sed -n 's/.*"surface_ref"[[:space:]]*:[[:space:]]*"\(surface:[0-9]*\)".*/\1/p')
case "$W" in
  surface:[0-9]*) echo "worker surface: $W"; cmux rename-tab --surface "$W" "lane-<repo>" ;;
  *) echo "ABORT: no surface ref captured" ;;
esac
```

On `ABORT`, send nothing: an empty `$W` would land every later `send` in your own pane. Take the
new surface's ref from `cmux --json tree` instead. Then move into the worktree, check, and launch:

```bash
cmux send --surface "$W" -- 'cd <worktree> && <env setup, e.g. nvm use>\n'
cmux send --surface "$W" -- 'pwd\n'
cmux read-screen --surface "$W" | tail -4
cmux send --surface "$W" -- 'claude --model sonnet --effort high\n'
cmux send --surface "$W" -- 'codex -c model_reasoning_effort=medium\n'
```

Send exactly one of the two launch lines, and only after `pwd` shows the worktree. Quote the path
if it has spaces. Confirm boot with `cmux read-screen --surface "$W" | tail -8`: the banner shows
the intended model and effort, and the input box is ready.

## Send a prompt

`send` only types. A long prompt's trailing `\n` is often swallowed into a bracketed paste, so
send the text, then a separate Enter:

```bash
cmux send --surface "$W" -- '<single-line prompt, no apostrophes>'
cmux send-key --surface "$W" enter
cmux read-screen --surface "$W" | tail -6
```

The read must show the spinner running, not the prompt sitting in the box. Single-quote all text
so your shell expands nothing. Never send `\t`: Tab accepts ghost autocomplete.

## Read status and screen

```bash
cmux read-screen --surface "$W" | tail -16
cmux read-screen --surface "$W" --scrollback --lines 60 | tail -40
```

cmux has no agent state; classify from the screen.

## Wait for done or blocked

Single lane: W1 below, with `run_in_background: true`. Parallel lanes: W2 in `templates.md` with:

```bash
LANES="surface:21 surface:24"
read_lane() { cmux read-screen --surface "$1" 2>/dev/null | tail -16; }
```

### W1 — idle watcher (single lane)

Keys only on ephemeral spinner text, never on the static status bar or the done marker, which sits
in the prompt echo and would fire at once.

```bash
busy_re='[0-9]+s ·|esc to interrupt|thinking'
idle=0
for i in $(seq 1 160); do
  s=$(cmux read-screen --surface "$W" 2>/dev/null | tail -12)
  if printf '%s' "$s" | grep -qE "$busy_re"; then idle=0; else idle=$((idle+1)); fi
  if [ $idle -ge 3 ]; then echo "EVENT=idle :: worker quiet ~45s (done or waiting)"; break; fi
  sleep 15
done
echo "WATCHER_EXIT iter=$i idle=$idle"
```

After it fires, read the tail and look for the done marker, `BLOCKED:`, or a question.

## Answer a prompt

Read first, then answer what you see:

- Free-text question: `cmux send --surface "$W" -- '<answer>\n'`.
- Numbered menu: `cmux send-key --surface "$W" -- "1"`.
- Highlighted list: `cmux send-key --surface "$W" down`, then `cmux send-key --surface "$W" enter`.
- `[y/N]`: `cmux send-key --surface "$W" -- "y"`, then `enter` if needed.
- Runaway worker: `cmux send-key --surface "$W" ctrl+c`, then redirect.

Read again to confirm. Escalate real decisions to the user and notify:
`cmux notify --title Orchestrator --body '<lane>: <question>'`.

## Next phase

```bash
cmux send --surface "$W" -- '/clear\n'
cmux read-screen --surface "$W" | tail -8
```

If the slash palette is still open, `cmux send-key --surface "$W" enter`. `/clear` reverts
Claude's effort to the launch default, which the `--effort high` launch flag already set; Codex
keeps its launch flag. Then send the next T2 prompt.

## Close

When a lane runs out of phases, close only the surface you created:
`cmux close-surface --surface "$W"`. Leave the worktree for shipping; `tgc-skills:merged` removes
it after merge. Progress for the user: `cmux set-progress 0.5 --label '2/4 phases verified'`.
