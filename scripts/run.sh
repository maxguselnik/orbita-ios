#!/usr/bin/env bash
# Генерация проекта, тесты физики, сборка под симулятор.
# Полный вывод шагов — в build/logs/, на экран — только итог и ошибки.
# VERBOSE=1 scripts/run.sh — показывать всё как есть.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Нет xcodegen: brew install xcodegen"; exit 1; }

LOGS=build/logs
mkdir -p "$LOGS"

# step <имя лога> <команда...>: при успехе — последние строки итога,
# при провале — строки с ошибками (до 60) и путь к полному логу.
step() {
  local log="$LOGS/$1.log"; shift
  if [[ "${VERBOSE:-0}" == 1 ]]; then
    "$@" 2>&1 | tee "$log"
    return "${PIPESTATUS[0]}"
  fi
  if "$@" >"$log" 2>&1; then
    grep -E "Executed [0-9]+ tests?|Test run with|BUILD SUCCEEDED" "$log" | tail -n 2 || true
  else
    local code=$?
    grep -E "error:|failed|FAILED|Fatal|fatal error" "$log" | sort -u | head -n 60 || tail -n 40 "$log"
    echo "✘ Провал, полный лог: $log"
    return "$code"
  fi
}

echo "▶ xcodegen generate"
step xcodegen xcodegen generate

echo "▶ Тесты OrbitPhysics"
step physics-tests swift test --package-path Packages/OrbitPhysics -Xswiftc -warnings-as-errors

echo "▶ Сборка под симулятор"
step build xcodebuild -project Orbita.xcodeproj -scheme Orbita \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet

echo "✔ Готово. Открой Orbita.xcodeproj, выбери iPhone и нажми Run."
