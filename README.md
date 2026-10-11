# Орбита

Нативная iOS-игра: 3D-симулятор космических полётов. Swift 6, SwiftUI + RealityKit, iOS 18+, только landscape.

## Запуск на iPhone
1. `git pull`
2. `brew install xcodegen`
3. `xcodegen generate`
4. Открыть `Orbita.xcodeproj`
5. Target Orbita → Signing & Capabilities → Team: выбрать свой (подходит бесплатный Personal Team)
6. Вверху выбрать свой iPhone
7. Run (⌘R)

Чтобы `xcodegen generate` не сбрасывал Team: один раз `echo 'export ORBITA_TEAM=<твой Team ID>' >> ~/.zshrc` (Team ID — в Xcode → Settings → Accounts).

Первый запуск на телефоне: Настройки → Основные → VPN и управление устройством → доверять своему профилю разработчика.

## Скрипт
`scripts/run.sh` — генерация проекта, тесты физики, сборка под симулятор.

## Структура
- `App/` — приложение: `Core/` (настройки, контракты), `Render/`, `UI/`, `Audio/`
- `Packages/OrbitPhysics/` — физика, чистый Swift; тесты: `swift test --package-path Packages/OrbitPhysics`
- `docs/SPEC.md` — ТЗ, `docs/PROGRESS.md` — статус, `docs/CONTRACTS.md` — контракты модулей
- `reference/` — эталонная 2D-версия (PWA)
