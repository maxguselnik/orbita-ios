# Контракты модулей

Меняет только ведущий агент. Поток, которому нужно изменение, описывает его в отчёте.

## Поток данных за кадр
```
UI (C) ── ControlInput, FlightCommand ──▶ FlightSimulation (A)
                                              │ advance(realDelta) → [SimEvent]
                                              ▼
                              WorldSnapshot + [SimEvent]
               ┌──────────────┬───────────────┼──────────────┐
          Renderer (B)     HUD (C)        Audio (D)     Haptics (D)
               ▲
UI (C) ── CameraInput ──┘
```
Игровой цикл (главный актёр, частота кадров из настроек): ввод → `advance` → раздать снимок и события. Физика не знает об Apple-фреймворках; остальные потоки не меняют физическое состояние.

## Физика — `Packages/OrbitPhysics/Sources/OrbitPhysics/Contracts.swift`
- `Vec3`, `Quat` — Double, СИ.
- Координаты корабля — инерциальная система с центром в `VesselState.body`; Терра вращается вокруг +Z (`WorldSnapshot.terraRotation`), Луна — круговая орбита в плоскости XY (`lunaPosition`).
- Ориентация: `attitude` переводит оси корабля (нос = +Y) в инерциальные.
- `FlightSimulation.advance(realDelta:)` сама дробит шаг (≤ 0.02 с), учитывает ускорение времени и авто-сброс (`SimEvent.warpReset`).
- `ControlInput` — непрерывный ввод (тяга 0…1, оси −1…1, RCS). `FlightCommand` — кнопки (ступень, SAS, ускорение, парашют).
- `FlightTelemetry` — готовые числа для HUD; HUD сам ничего не считает.
- `SimEvent` — одноразовые события шага для звука, вибрации, эффектов, подсказок.

## Приложение — `App/Core/AppContracts.swift`
- `FlightRenderer` (B): floating origin — рендер вычитает позицию активного корабля и переводит в Float сам. Принимает `CameraInput` от C.
- `FlightAudio`, `FlightHaptics` (D): реагируют на снимок и события, выключаются флагом `isEnabled` (из `GameSettings`).
- `GameSettings`: частота кадров 60/90/120 (по умолчанию 90), звук, вибрация, наклон (выкл.).

## Владение папками
| Поток | Папки |
|---|---|
| A Physics | `Packages/OrbitPhysics/` |
| B Render | `App/Render/` |
| C UI | `App/UI/` |
| D Audio/Haptics | `App/Audio/` |
| E Build | `project.yml`, `scripts/`, `.github/`, `README.md` |
| Ведущий | `App/Core/`, `App/OrbitaApp.swift`, `docs/`, `CLAUDE.md`, `Contracts.swift` |
