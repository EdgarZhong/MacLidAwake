#!/bin/bash
# Builds the phantom-display test binary.
set -euo pipefail
cd "$(dirname "$0")"

swiftc \
  -import-objc-header CGVirtualDisplayPrivate.h \
  -framework Cocoa \
  -framework CoreGraphics \
  -o phantom-display \
  main.swift

echo "Built ./phantom-display"
