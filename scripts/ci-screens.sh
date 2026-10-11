#!/usr/bin/env bash
# CI (macOS): собирает приложение под симулятор, снимает скриншоты и короткое видео в landscape.
# Результат — в каталоге screens/. Использование: scripts/ci-screens.sh [сцена ...]
# Сцена передаётся приложению аргументом запуска `-screen <имя>` (по умолчанию — flight).
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${SCREENS_DEVICE:-iPhone 16 Pro}"   # 393×852 pt, как iPhone 15 Pro
SCENES=("${@:-flight}")
OUT=screens
mkdir -p "$OUT"

xcodebuild -project Orbita.xcodeproj -scheme Orbita \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath build -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet

APP=build/Build/Products/Debug-iphonesimulator/Orbita.app
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
print(next(x['udid'] for r in d.values() for x in r if x['name']=='$DEVICE'))")

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance dark || true
xcrun simctl install "$UDID" "$APP"

for scene in "${SCENES[@]}"; do
  xcrun simctl terminate "$UDID" com.maxguselnik.orbita 2>/dev/null || true
  xcrun simctl io "$UDID" recordVideo --codec h264 --force "$OUT/$scene.mp4" &
  REC=$!
  sleep 1
  xcrun simctl launch "$UDID" com.maxguselnik.orbita -screen "$scene"
  sleep 8
  xcrun simctl io "$UDID" screenshot "$OUT/$scene.png"
  kill -INT "$REC"; wait "$REC" || true
  # Приложение только landscape, а симулятор в портрете: поворачиваем снимок.
  sips -r 270 "$OUT/$scene.png" >/dev/null
done

ls -la "$OUT"
