#!/bin/bash
# Runs `swift test` for CI with output unbuffered. If the run is still going after
# $LIMIT seconds, prints a stack sample of the test process so a hang shows where it is.
set -u
LIMIT="${LIMIT:-300}"
swift build --build-tests
script -q /dev/null swift test --skip-build &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge "$LIMIT" ]; then
    echo "::error::swift test still running after ${LIMIT}s; sampling"
    for p in $(pgrep -f "TunnelKitPackageTests|swiftpm-testing"); do
      echo "=== sample $p"
      sample "$p" 3 -mayDie 2>/dev/null | grep -vE "^\s*$" | head -400
    done
    kill "$pid"
    exit 1
  fi
  sleep 5
  waited=$((waited + 5))
done
wait "$pid"
