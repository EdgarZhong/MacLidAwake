#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

swift build -c release -Xswiftc -warnings-as-errors
BUILD_BIN_DIR="$(swift build -c release --show-bin-path)"
echo "Built $BUILD_BIN_DIR/lidgo"
