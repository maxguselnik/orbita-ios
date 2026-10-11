#!/usr/bin/env bash
# Генерация проекта, тесты физики, сборка под симулятор.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Нет xcodegen: brew install xcodegen"; exit 1; }

echo "▶ xcodegen generate"
xcodegen generate

echo "▶ Тесты OrbitPhysics"
swift test --package-path Packages/OrbitPhysics

echo "▶ Сборка под симулятор"
xcodebuild -project Orbita.xcodeproj -scheme Orbita \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO -quiet

echo "✔ Готово. Открой Orbita.xcodeproj, выбери iPhone и нажми Run."
