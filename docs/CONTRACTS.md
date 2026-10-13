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
- `FlightTelemetry` — готовые числа для HUD и звука (включая `stages: [StageInfo]` — Δv, TWR, топливо по ступеням (`fuelMass`/`fuelCapacity` в кг, `hasLiquidEngine` для смешанных ступеней); тягу, РДТТ, плотность, нагрев, перегрузку); HUD сам ничего не считает.
- `FlightTelemetry.navball` — маркеры навбола уже в осях корабля; `pitch/heading/roll` — относительно горизонта; `chute`, `chuteSafe`; `warpIndex` в `TimeWarp.levels` (×1–4 физическое, ×10–100 000 рельсы) и `warpBlocked`.
- `FlightTelemetry.nextStageAction` — точное следующее действие: `.ignite`, `.separate`, `.armChute`, `.none`; HUD и подсказки не определяют его по числу секций.
- `VesselAssembly.empty`, `insert(_:into:at:)`, `move(_:from:to:)` — осевая сборка; крепления 0…count, перенос использует индекс крепления до удаления исходной детали. Сохраняется прежний формат `VesselDesign.parts`.
- `stages[0]` — текущая ступень; отдельного номера ступени нет.
- `FlightTelemetry.mission: MissionRecord` — итоги полёта с момента старта (макс. высота/скорость/перегрузка, космос, орбита, SOI Луны, орбита Луны, посадка на Луну, возврат из космоса) — для экрана результата.
- `VesselDesign.issues() -> [DesignIssue]` — проверка проекта в ангаре; `isBlocking` — старт запрещён, `text` — строка для UI.
- `SimEvent` — одноразовые события шага для звука, вибрации, эффектов, подсказок.
- Узел манёвра (этап 5): `FlightCommand.setManeuver(ManeuverNode?)` — поставить/изменить/удалить узел активного корабля (один узел); `warpToManeuver` — рельсы до узла, сброс до ×1 за `ManeuverStatus.warpLead` с до начала прожига (`WarpResetReason.maneuver`). `SASMode.maneuver` — держать нос по оставшемуся импульсу. `FlightTelemetry.maneuver: ManeuverStatus?` — время до узла, Δv полный и оставшийся (уменьшается тягой), время прожига, начало прожига, `isDone` (только при импульсе узла ≥ 1 м/с); `navball.maneuver` — направление оставшегося импульса. Остаток = Δv узла − сожжённое тягой с момента постановки узла (правка узла посреди прожига сожжённое не теряет; удаление узла его обнуляет). Без тяги (`burnTime` = ∞) `timeToBurn` = `timeToNode`.
- `FlightSimulation.predictTrajectory(maxPatches:)`, `predictManeuver(_:maxPatches:)` — прогноз патченными кониками для карты. `MapMarkers.compute(_:afterManeuver:)` — Ап/Пе, AN/DN, SOI, падение по участкам (`MapMarker`, координаты в инерциальной системе тела участка; `soiExit(b)` — тело, из SOI которого выходим). Число участков прогноза — `TrajectoryPredictor.defaultMapPatches` (4).

- `Terrain.craterShade(body:direction:)` — оттенок малых кратеров Луны −1 (дно) … +1 (вал), 0 вне кратеров и на Терре; малые кратеры (25 м–2.5 км) входят в `Terrain.height`, биом не меняют.

- РСУ (Б4): детали `PartID.rcsBlock` (`PartKind.rcs`: сопла + свой запас монотоплива; `thrustVacuum` — тяга на одно направление, Isp монотоплива) и `.m100` (`PartKind.monoTank`). Монотопливо хранится в `fuelMass` этих деталей, общее на весь корабль (через разделители тоже), в Δv ступеней не входит. `FlightCommand.setRCS(Bool)`; при включённом РСУ `ControlInput.translation` (x — правый борт, y — вперёд по носу, z — вверх/спина) даёт тягу `блоков × тяга × команда` по каждой оси, а поворот (ручной и SAS) получает добавочный момент от сопел; расход — по Isp. Без блоков или монотоплива РСУ молчит. Тяга РСУ уменьшает остаток узла манёвра; работающие сопла блокируют рельсы (`.thrust`). `FlightTelemetry.rcs: RCSStatus` (есть ли блоки, включено, монотопливо кг/ёмкость, работают ли сопла). `VesselState.rcsTranslation` / `rcsRotation` — команда на сопла в этом кадре (для струек рендера), нули — молчит.
- `VesselState.parts` (сверху вниз), `firingEngines` (индексы деталей с факелом), `chute`, `chuteDeploy` 0…1 — для рендера корабля и отделённых ступеней.
- Оси корабля: нос +Y, спина +Z, правый борт +X; pitch>0 — нос к +Z, yaw>0 — к +X, roll>0 — правый борт вниз. На площадке +X — восток, +Z — юг. `position` — нижняя точка стека; `angularVelocity` — инерциальная.

## Приложение — `App/Core/AppContracts.swift`
- `FlightRenderer` (B): floating origin — рендер вычитает позицию активного корабля и переводит в Float сам. Принимает `CameraInput` от C.
- `FlightAudio`, `FlightHaptics` (D): реагируют на снимок и события, выключаются флагом `isEnabled` (из `GameSettings`).
- `FlightFeedback` (ведущий): каждый кадр раздаёт снимок рендеру (`renderer.update`), звуку и вибрации; жесты камеры из UI идут через `feedback.camera(_:)` и `feedback.cameraMode`.
- `GameFlow` (ведущий): экран `hangar`/`flight`, текущий `design` (автосохранение в Documents/hangar.json через `DesignStore`), `launch()`, `returnToHangar()`, `makeSimulation()`, `flightID` — ключ нового полёта. Без `-screen` игра открывается в ангаре.
- `HangarPreview` (B): `show(parts:selected:)`, `apply(CameraInput)`; реализация `HangarScene` + SwiftUI `HangarSceneView(scene:)` — в `App/Render/`.
- `FlightFeedback.stop()` — выход из полёта: звук, вибрация и наклон выключены.
- `DemoScenario` (ведущий): аргумент запуска `-screen hangar|flight|ascent|staging|orbit|lunaApproach|lunaSurface|lunaDescent|chute|landed|crash` — стартовое состояние для CI-скриншотов и отладки (`screens.txt` — список снимаемых сцен).
- `MapModel` (ведущий, `App/Core/MapModel.swift`): владеет `FlightHUDModel` (`map`), каждый кадр `update(sim:now:)` — прогноз ≤ 4 Гц (при правке узла ≤ 30 Гц), отдаёт `MapSnapshot` рендеру (`updateMap`) и оверлею (`snapshot`); `isOpen`, `focus` пробрасываются в рендер; `project`, `orbitPick`, `setViewSize` — через рендер.
- `FlightRenderer` карта (B): `isMapMode` — вместо полёта тела в масштабе карты, орбиты (текущая — по участкам, после узла — пунктир/другой цвет, участок у Луны — фиолетовый, возврат к Терре — оранжевый), корабль-значок, SOI Луны; жесты `apply` крутят камеру карты вокруг `mapFocus`. `project` и `orbitPick` — для оверлея C (подписи отметок, тап по орбите).
- Сцены карты: `-screen map|mapManeuver|mapLuna` (`DemoScenario.opensMap`, `mapFocus`).
- `GameSettings`: частота кадров 60/90/120 (по умолчанию 90), звук, вибрация, наклон (выкл.), подсказки первого полёта (вкл.).

## Обучение «Первый полёт» (2026-10-13)
- Физика: `FlightCheckpointing` (`checkpoint() -> SimCheckpoint`, `restore(_:)`) — полное состояние `FlightSim` для отката шага; реализует только `FlightSim` (`sim as? FlightCheckpointing`), у моков и `ScenarioFlight` — nil, повтор шага тогда недоступен.
- Ведущий (`App/Core/GameFlow.swift`): `TutorialID` (`.firstFlight`, `title`, `design` = «Орбита»), `GameFlow.tutorial`, `startTutorial(_:)` (проект ангара не меняется; `makeSimulation` строит корабль урока), `launch()`/`returnToHangar()` сбрасывают урок. `TutorialProgress` (UserDefaults): `wasOffered`/`markOffered()` — предложение при первом запуске показано, `isFirstFlightDone`/`markFirstFlightDone()`. Сцена `-screen tutorial` — урок на площадке (CI).
- C (`App/UI/Tutorial/`): контроллер урока — шаги из макета (артефакт «Орбита — обучение «Первый полёт»»): знакомство (пауза), тяга MAX (ждём), Пуск (ждём), вертикально до 1 км (живая), разворот ▶ до 80° (ждём), следовать метке до 10 км (живая), отделение (пауза при пустой ступени), Ап 80 км — тяга 0 (ждём), ускорение до Ап (ждём), скругление (живая), итог (пауза). Виды шагов: `pause` — игра на паузе, затемнение с вырезом вокруг элемента, пузырь с кнопкой; `wait` — то же, ждёт действия игрока (на паузе физика стоит, но действие — тяга/кнопка — принимается; после него пауза снимается); `live` — плашка без затемнения, полёт идёт. Ошибка шага (нос > 15° от цели дольше 3 с или Ап падает) — красная плашка «Повторить шаг»: `restore` контрольной точки начала шага и пауза. Пороги — `AscentGuide`, шаги — согласованы с `MissionChecklist`. Подсвечиваемые элементы HUD отдают свои рамки через anchor preference (ключ — элемент урока). Пока идёт урок, подсказки первого полёта (`HintBanner`) и помощник подъёма в строке статуса не дублируют урок. Вход: предложение при первом запуске (ангар, если `!wasOffered`), «Обучение» в ангаре и в меню паузы. Итог — `markFirstFlightDone()`, «В ангар».

## Уроки «Полёт к Луне» и «Все кнопки» (2026-10-13)
- Ведущий: `TutorialID.toLuna` (корабль «Луна», старт — орбита 80 км через `ScenarioFlight` + автопилот за кадром; `ScenarioFlight` реализует `FlightCheckpointing`), `TutorialID.controls` (площадка, «Орбита»); `TutorialID.makeSimulation()`; `TutorialProgress.isDone(_:)`/`markDone(_:)`; сцены `-screen tutorialLuna|tutorialControls`.
- C: движок урока обобщается — протокол урока (шаги, вид шага pause/wait/live/try, цель подсветки, условие выполнения, плашка, ошибка), `FirstFlightLesson` — первая реализация; `TutorialController` создаёт урок по `TutorialID`. Подсвечиваемые элементы расширяются на всю HUD и карту (`LessonElement`), урок может открыть/ждать карту. Шаги — по макету «Орбита — уроки «К Луне» и «Все кнопки»». «Все кнопки» открывается и из меню паузы на текущем полёте (тур только по видимым элементам, без отката). Вход в уроки — список уроков в ангаре и в меню паузы (пройденные отмечены).

## Владение папками
| Поток | Папки |
|---|---|
| A Physics | `Packages/OrbitPhysics/` |
| B Render | `App/Render/` |
| C UI | `App/UI/` |
| D Audio/Haptics | `App/Audio/` |
| E Build | `project.yml`, `scripts/`, `.github/`, `README.md` |
| Ведущий | `App/Core/`, `App/OrbitaApp.swift`, `docs/`, `CLAUDE.md`, `Contracts.swift` |
