#!/bin/bash
# Builds the keepawake CLI binary.
set -euo pipefail
cd "$(dirname "$0")"

swiftc \
  -framework Cocoa \
  -framework IOKit \
  -o keepawake \
  main.swift

echo "Built ./keepawake"
