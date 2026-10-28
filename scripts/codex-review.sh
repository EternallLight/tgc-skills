#!/usr/bin/env bash
set -eu

usage() {
  echo "usage: codex-review.sh start <dir> <prompt-file> <out-prefix> | join <out-prefix> <timeout-s>" >&2
  exit 2
}

case "${1:-}" in
  start)
    [ $# -eq 4 ] && [ -f "$3" ] || usage
    rm -f "$4.done" "$4.last" "$4.log"
    set -m
    nohup "$0" run "$2" "$3" "$4" < /dev/null > /dev/null 2>&1 &
    echo $! > "$4.pid"
    ;;
  run)
    code=0
    command codex exec -s read-only -C "$2" -o "$4.last" - < "$3" > "$4.log" 2>&1 || code=$?
    echo "$code" > "$4.done.tmp"
    mv "$4.done.tmp" "$4.done"
    ;;
  join)
    [ $# -eq 3 ] && [ -f "$2.pid" ] || usage
    p=$2 limit=$3 pid=$(cat "$2.pid") elapsed=0
    until [ -f "$p.done" ]; do
      if ! kill -0 "$pid" 2>/dev/null; then
        [ -f "$p.done" ] && break
        echo "codex-review: codex exited without writing a result" >&2
        cat "$p.log" >&2
        exit 1
      fi
      if [ "$elapsed" -ge "$limit" ]; then
        kill -TERM -- "-$pid" 2>/dev/null || true
        sleep 2
        kill -KILL -- "-$pid" 2>/dev/null || true
        echo "codex-review: timed out after ${limit}s; codex killed" >&2
        exit 124
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    code=$(cat "$p.done")
    [ "$code" -eq 0 ] && [ -s "$p.last" ] && exec cat "$p.last"
    cat "$p.log" >&2
    [ "$code" -eq 0 ] && code=1
    exit "$code"
    ;;
  *) usage ;;
esac
