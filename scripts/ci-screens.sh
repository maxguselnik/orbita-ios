#!/usr/bin/env bash
# CI (macOS): собирает приложение под симулятор, снимает скриншоты в landscape и проверяет, что сцены не падают.
# Результат — в каталоге screens/. Использование: scripts/ci-screens.sh [сцена ...]
# Сцена передаётся приложению аргументом запуска `-screen <имя>` (по умолчанию — flight).
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${SCREENS_DEVICE:-iPhone 16 Pro}"   # 393×852 pt, как iPhone 15 Pro
SCENES=("${@:-flight}")
OUT=screens
CRASHED=""
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
  xcrun simctl launch "$UDID" com.maxguselnik.orbita -screen "$scene"
  sleep 8
  xcrun simctl io "$UDID" screenshot "$OUT/$scene.png"
  # Приложение должно быть живо после 8 с сцены, иначе — падение рендера или физики.
  if ! xcrun simctl spawn "$UDID" launchctl list | awk '$3 ~ /com\.maxguselnik\.orbita/ && $1 != "-" { found = 1 } END { exit !found }'; then
    echo "::error::Сцена $scene: приложение упало"
    CRASHED="$CRASHED $scene"
  fi
  # Приложение только landscape, а симулятор в портрете: поворачиваем снимок.
  sips -r 270 "$OUT/$scene.png" >/dev/null
done

ls -la "$OUT"
if [ -n "$CRASHED" ]; then
  echo "Упали сцены:$CRASHED"
  ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i orbita || true
  exit 1
fi
