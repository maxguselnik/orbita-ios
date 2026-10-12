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

# Нужное устройство, а если на раннере его нет — самый новый доступный iPhone.
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
phones=[(rt,x) for rt,r in d.items() if 'iOS' in rt for x in r if x['name'].startswith('iPhone')]
exact=[x for rt,x in phones if x['name']=='$DEVICE']
if exact or phones:
    pick=exact[0] if exact else sorted(phones, key=lambda p: (p[0], 'Pro' in p[1]['name']))[-1][1]
    print(pick['udid'])")
if [ -z "$UDID" ]; then
  # Устройств нет вовсе — создать на самой новой среде iOS.
  RUNTIME=$(xcrun simctl list runtimes available -j | python3 -c "
import json,sys
r=[x for x in json.load(sys.stdin)['runtimes'] if x.get('platform','iOS')=='iOS' and 'iOS' in x['identifier']]
print(r[-1]['identifier'] if r else '')")
  [ -n "$RUNTIME" ] || { echo "::error::Нет среды iOS-симулятора на раннере"; exit 1; }
  UDID=$(xcrun simctl create "$DEVICE" "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro" "$RUNTIME" 2>/dev/null \
    || xcrun simctl create "Orbita iPhone" "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro" "$RUNTIME")
fi
echo "Симулятор: $UDID"

xcodebuild -project Orbita.xcodeproj -scheme Orbita \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet

APP=build/Build/Products/Debug-iphonesimulator/Orbita.app

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
