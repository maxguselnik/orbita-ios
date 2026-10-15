#!/usr/bin/env bash
# Native previews from the real map/flight renderer. Uses the already built app.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SCREENS_UDID:?SCREENS_UDID is required}"
mkdir -p screens
xcrun simctl bootstatus "$SCREENS_UDID" -b
xcrun simctl install "$SCREENS_UDID" build/Build/Products/Debug-iphonesimulator/Orbita.app
PLANET_DATA=$(xcrun simctl get_app_container "$SCREENS_UDID" com.maxguselnik.orbita data)
for GROUP in new original; do
  for MODE in map flight surface; do
    xcrun simctl terminate "$SCREENS_UDID" com.maxguselnik.orbita 2>/dev/null || true
    ARGS=(-planet-preview)
    BODIES=(terra luna)
    if [ "$GROUP" = new ]; then ARGS+=(-new-worlds); BODIES=(vella arda taros); fi
    if [ "$MODE" = flight ]; then ARGS+=(-flight-render); fi
    if [ "$MODE" = surface ]; then
      ARGS+=(-flight-render -surface-closeup)
      if [ "$GROUP" = new ]; then BODIES=(vella arda); fi
    fi
    for BODY in "${BODIES[@]}"; do rm -f "$PLANET_DATA/Documents/planet-$MODE-$BODY.ready"; done
    xcrun simctl launch --console "$SCREENS_UDID" com.maxguselnik.orbita "${ARGS[@]}" > "screens/worlds-$GROUP-$MODE.log" 2>&1 &
    LAUNCH_PID=$!
    READY=false
    for SECOND in $(seq 1 120); do
      READY=true
      for BODY in "${BODIES[@]}"; do
        if [ ! -f "$PLANET_DATA/Documents/planet-$MODE-$BODY.ready" ]; then READY=false; fi
      done
      if [ "$READY" = true ]; then break; fi
      sleep 1
    done
    if [ "$READY" != true ]; then
      cat "screens/worlds-$GROUP-$MODE.log"
      echo "::error::Native world preview was not ready: $GROUP/$MODE"
      exit 1
    fi
    sleep 2
    xcrun simctl io "$SCREENS_UDID" screenshot "screens/worlds-$GROUP-$MODE-native.png"
    xcrun simctl terminate "$SCREENS_UDID" com.maxguselnik.orbita || true
    wait "$LAUNCH_PID" || true
  done
done
