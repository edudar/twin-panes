#!/bin/bash
# Fails unless every Swift Testing run in the given `swift test` log finished.
#
# A test that stops the main run loop (posting an NSEvent at the front of the queue,
# clicking an alert's button) makes the test process exit with status 0 before its
# summary line; `swift test` then reports success with the rest of the run skipped.
# Each test process prints "Test run started." first and "Test run with N tests" last,
# passed or failed: one process per test target from Xcode 26, one for all of them
# with Xcode 16. A run that started but never summed up ended early.
set -euo pipefail

log=${1:?usage: check-test-runs.sh <swift test log>}
started=$(grep -c 'Test run started' "$log" || true)
finished=$(grep -cE 'Test run with [0-9]+ tests?' "$log" || true)

if [ "$started" -eq 0 ] || [ "$finished" -ne "$started" ]; then
    echo "::error::$finished of $started Swift Testing runs finished; the others ended early."
    exit 1
fi
echo "All $started Swift Testing runs finished."
