#!/usr/bin/env bash
# Нативный аудит неизменённого приложения: ранний и поздний кадры, консоль и признак живого процесса.
# Запуск в CI: [build-only] [screens: audit]. Не управляет интерфейсом и не измеряет FPS устройства.
set -euo pipefail
cd "$(dirname "$0")/.."

UDID="${SCREENS_UDID:?SCREENS_UDID is required}"
APP=build/Build/Products/Debug-iphonesimulator/Orbita.app
OUT=screens
mkdir -p "$OUT"
git rev-parse HEAD > "$OUT/audit-commit.txt"
git rev-parse HEAD:App > "$OUT/audit-app-tree.txt"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance dark
xcrun simctl install "$UDID" "$APP"

SCENES=(newGame spaceCenter research hangarEmpty hangar hangarBoosters flight tutorial tutorialLuna orbit map mapManeuver mapLuna systemMap vellaSurface ardaSurface tarosOrbit crewGallery reentry landed crash lunaSurface)
if [ "$#" -gt 0 ]; then SCENES=("$@"); fi
FAILED=0

capture() {
  local scene="$1" delay="$2" started="$3" alive=1
  local file="$OUT/audit-$scene-${delay}s.png"
  local captureStarted=$(date +%s)
  xcrun simctl io "$UDID" screenshot "$file"
  local captured=$(date +%s)
  # Simulator запускает iOS-процесс на хосте. Не создаём дополнительный процесс
  # внутри перегруженного симулятора только ради проверки PID.
  if ! pgrep -x Orbita >/dev/null; then
    alive=0
    FAILED=1
    echo "::error::Audit $scene at ${delay}s: application is not running"
  fi
  # Сохраняем нативный масштаб; только приводим ориентацию снимка к landscape.
  if python3 - "$file" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    header = f.read(24)
w, h = struct.unpack('>II', header[16:24])
sys.exit(0 if w < h else 1)
PY
  then sips -r 270 "$file" >/dev/null; fi
  python3 - "$OUT/audit-captures.jsonl" "$scene" "$delay" "$started" "$alive" "$file" "$captureStarted" "$captured" <<'PY'
import json, os, struct, sys, time
path, scene, delay, started, alive, image, capture_start, captured = sys.argv[1:]
with open(image, 'rb') as f:
    w, h = struct.unpack('>II', f.read(24)[16:24])
row = dict(scene=scene, nominal_delay_seconds=int(delay), elapsed_seconds=round(time.time()-float(started),2),
           screenshot_command_start_seconds=int(capture_start)-int(started), screenshot_command_end_seconds=int(captured)-int(started),
           alive=bool(int(alive)), file=os.path.basename(image), width=w, height=h)
with open(path, 'a') as f:
    f.write(json.dumps(row)+'\n')
print(json.dumps(row))
PY
}

for scene in "${SCENES[@]}"; do
  xcrun simctl terminate "$UDID" com.maxguselnik.orbita 2>/dev/null || true
  started=$(date +%s)
  echo "[$(date +%T)] audit scene $scene"
  if [ "$scene" = newGame ]; then
    xcrun simctl launch --console "$UDID" com.maxguselnik.orbita > "$OUT/audit-$scene.log" 2>&1 &
  else
    xcrun simctl launch --console "$UDID" com.maxguselnik.orbita -screen "$scene" > "$OUT/audit-$scene.log" 2>&1 &
  fi
  launcher=$!
  sleep 6
  capture "$scene" 6 "$started"
  sleep 14
  capture "$scene" 20 "$started"
  case "$scene" in
    flight|mapLuna|ardaSurface)
      sleep 40
      capture "$scene" 60 "$started"
      ;;
  esac
  xcrun simctl terminate "$UDID" com.maxguselnik.orbita 2>/dev/null || true
  wait "$launcher" || true
done

python3 - "$OUT" <<'PY'
from pathlib import Path
import shutil, sys
dest=Path(sys.argv[1])
reports=Path.home()/'Library/Logs/DiagnosticReports'
for source in reports.glob('Orbita*'):
    if source.is_file():
        shutil.copy2(source, dest/source.name)
PY
exit "$FAILED"
