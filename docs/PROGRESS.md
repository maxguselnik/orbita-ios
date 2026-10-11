# Прогресс

## Текущий этап
0 — каркас: готов, ждёт «ок» пользователя. Следующий — 1 (физика A + HUD на моках C + каркас звука D).

## Сделано
- Шаг 1: `CLAUDE.md`, `docs/SPEC.md`, `docs/PROGRESS.md`; эталонная 2D-версия распакована в `reference/`.
- Этап 0: `project.yml` (XcodeGen), пакет `OrbitPhysics` (Vec3, Quat, тела, контракты), `docs/CONTRACTS.md`, пустая RealityKit-сцена в landscape, настройки (60/90/120 Гц, по умолчанию 90), заглушки звука/вибрации, `scripts/run.sh`, README, CI.

## Проверено
- `swift test` OrbitPhysics на Linux (Swift 6.0.3): 4/4.
- CI PR #1: тесты на Linux и macOS, сборка под симулятор (Xcode 16.4) с warnings-as-errors — зелёные.

## Открытые проблемы
- Запуск на устройстве не проверен (только сборка в CI).
- Частота кадров из настроек ещё не применяется к рендеру (этап 2).
- В CI предупреждение GitHub о Node 20 у `actions/checkout@v4` — не ошибка.
