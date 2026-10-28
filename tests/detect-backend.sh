#!/bin/sh
script="$(dirname "$0")/../scripts/detect-backend.sh"
fail=0

check() {
  want=$1 want_code=$2
  shift 2
  got=$(env -i "$@" /bin/sh "$script")
  code=$?
  if [ "$got" != "$want" ] || [ "$code" -ne "$want_code" ]; then
    echo "FAIL: [$*] printed '$got' exit $code, want '$want' exit $want_code"
    fail=1
  fi
}

check none 1
check orca 0 TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=t
check herdr 0 HERDR_PANE_ID=w1:p1 TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=t
check herdr 0 HERDR_PANE_ID=w1:p1 CMUX_SURFACE_ID=s
check cmux 0 CMUX_SURFACE_ID=s
check cmux 0 CMUX_SURFACE_ID=s ORCA_TERMINAL_HANDLE=t TERM_PROGRAM=ghostty
check orca 0 CMUX_SURFACE_ID=s TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE=t
check orca 0 ORCA_TERMINAL_HANDLE=t TERM_PROGRAM=tmux

[ "$fail" -eq 0 ] && echo "detect-backend: all cases passed"
exit "$fail"
