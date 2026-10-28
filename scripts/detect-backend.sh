#!/bin/sh
if [ -n "$HERDR_PANE_ID" ]; then
  echo herdr
elif [ "$TERM_PROGRAM" = Orca ]; then
  echo orca
elif [ -n "$CMUX_SURFACE_ID" ]; then
  echo cmux
elif [ -n "$ORCA_TERMINAL_HANDLE" ]; then
  echo orca
else
  echo none
  exit 1
fi
