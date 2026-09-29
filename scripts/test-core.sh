#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/intent-tests.XXXXXX")"
xcrun swiftc -swift-version 5 -D CORE_STANDALONE Sources/PlannerCore/*.swift Tests/PlannerCoreTests/CoreTests.swift scripts/CoreTestRunner.swift -o "$OUTPUT/core-tests"
"$OUTPUT/core-tests"
