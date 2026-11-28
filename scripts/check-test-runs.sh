#!/bin/bash
# Fails unless every test target under TwinPanesKit/Tests finished its Swift Testing run
# in the given `swift test` log.
#
# A test that stops the main run loop (posting an NSEvent at the front of the queue,
# clicking an alert's button) makes the test process exit with status 0 before its
# summary line; `swift test` then reports success with the rest of that target unrun.
# Every test target has Swift Testing tests, so each prints one "Test run with N tests"
# line, passed or failed.
set -euo pipefail

log=${1:?usage: check-test-runs.sh <swift test log>}
root=$(cd "$(dirname "$0")/.." && pwd)
expected=$(find "$root/TwinPanesKit/Tests" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
finished=$(grep -cE 'Test run with [0-9]+ tests?' "$log" || true)

if [ "$finished" -ne "$expected" ]; then
    echo "::error::$finished of $expected test targets finished their run; the others ended early."
    exit 1
fi
echo "All $expected test targets finished their run."
