#!/bin/bash
# Polls clamshell-relevant IOKit properties every second so a lid-close/open
# cycle can be observed in real time. Run this in one terminal, then close and
# reopen the lid; Ctrl-C to stop.
set -euo pipefail

while true; do
  ts=$(date "+%H:%M:%S")
  state=$(ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -m1 AppleClamshellState || true)
  causes=$(ioreg -r -k AppleClamshellCausesSleep -d 4 2>/dev/null | grep -m1 AppleClamshellCausesSleep || true)
  echo "$ts  $state  |  $causes"
  sleep 1
done
