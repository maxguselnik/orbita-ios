#!/usr/bin/env bash
# Локальная проверка: xcodegen → нужные тесты OrbitPhysics → сборка с тестами
# (предупреждения = ошибки) → нужные AppTests на симуляторе → снимки сцен.
# По умолчанию тесты — только для изменённого кода (scripts/affected-tests.sh);
# --full — все тесты, как в CI.
# Использование: check.sh [--full] [сцена ... | default | all]   — без сцен снимков нет.
# Полные логи — build/logs/, снимки — screens/.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
LOGS=build/logs; mkdir -p "$LOGS"
T0=$(date +%s)
FULL=0; [ "${1:-}" = --full ] && { FULL=1; shift; }
if [ "$FULL" = 1 ]; then PHYS=all APP=all
else
  aff=$(scripts/affected-tests.sh)
  PHYS=$(sed -n 's/^physics: //p' <<< "$aff"); APP=$(sed -n 's/^app: //p' <<< "$aff")
fi
echo "Тесты физики: $PHYS"; echo "Тесты приложения: $APP"

step() {
  local log="$LOGS/$1.log"; shift
  if "$@" >"$log" 2>&1; then
    grep -E "Executed [0-9]+ tests?|Test run with|BUILD SUCCEEDED|TEST SUCCEEDED|TEST BUILD SUCCEEDED" "$log" | tail -n 2 || true
  else
    local code=$?
    grep -E "error:|failed|FAILED|Fatal|fatal error|XCTAssert" "$log" | sort -u | head -n 60 || tail -n 40 "$log"
    echo "✘ Провал, полный лог: $log"
    exit "$code"
  fi
}

# Симулятор: уже загруженный iPhone, иначе iPhone 15/16/17 Pro, иначе самый новый iPhone.
UDID="${SCREENS_UDID:-$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
ph=[(rt,x) for rt,r in d.items() if 'iOS' in rt for x in r if x['name'].startswith('iPhone')]
booted=[x for rt,x in ph if x['state']=='Booted']
pro=[x for rt,x in sorted(ph, key=lambda p: p[0]) if x['name'] in ('iPhone 15 Pro','iPhone 16 Pro','iPhone 17 Pro')]
pick=(booted or pro or [x for rt,x in sorted(ph, key=lambda p: p[0])])
print(pick[0]['udid'] if pick else '')")}"
[ -n "$UDID" ] || { echo "✘ Нет iOS-симулятора (Xcode → Settings → Components)"; exit 1; }
export SCREENS_UDID="$UDID"
echo "Симулятор: $(xcrun simctl list devices | grep "$UDID" | sed 's/^ *//')"

echo "▶ xcodegen generate";  step xcodegen xcodegen generate
if [ "$PHYS" != none ]; then
  filt=(); [ "$PHYS" = all ] || filt=(--filter "($(tr ' ' '|' <<< "$PHYS"))")
  echo "▶ Тесты OrbitPhysics"; step physics-tests swift test --package-path Packages/OrbitPhysics -Xswiftc -warnings-as-errors ${filt[@]+"${filt[@]}"}
fi
echo "▶ Сборка с тестами";   step build xcodebuild -project Orbita.xcodeproj -scheme Orbita \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build -configuration Debug \
  build-for-testing CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES
if [ "$APP" != none ]; then
  only=(); [ "$APP" = all ] || for t in $APP; do only+=("-only-testing:AppTests/$t"); done
  echo "▶ AppTests";          step app-tests xcodebuild -project Orbita.xcodeproj -scheme Orbita \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build -configuration Debug \
    test-without-building CODE_SIGNING_ALLOWED=NO ${only[@]+"${only[@]}"}
fi

if [ $# -gt 0 ]; then
  SCENES="$*"
  [ "$SCENES" = default ] && SCENES=$(cat screens.txt)
  [ "$SCENES" = all ] && SCENES=$(cat screens-all.txt)
  echo "▶ Снимки: $SCENES"
  rm -rf screens
  # shellcheck disable=SC2086
  step screens scripts/ci-screens.sh $SCENES
  ls screens/*.png
fi
echo "✔ Всё зелёное за $(( $(date +%s) - T0 )) с"
