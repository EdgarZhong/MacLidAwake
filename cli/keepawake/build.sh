#!/bin/bash
# Builds the keepawake CLI binary.
set -euo pipefail
cd "$(dirname "$0")"

swiftc \
  -import-objc-header CGVirtualDisplayPrivate.h \
  -framework Cocoa \
  -framework CoreGraphics \
  -framework IOKit \
  -o keepawake \
  main.swift

echo "Built ./keepawake"
