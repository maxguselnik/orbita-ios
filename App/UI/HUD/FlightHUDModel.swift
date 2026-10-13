import CoreGraphics
import Foundation
import Observation
import QuartzCore
import OrbitPhysics

/// Короткое сообщение поверх HUD (события, заглушки).
struct HUDToast: Equatable {
    let id: Int
    let text: String
}

/// Статус кнопки «Ступень»: перерисовка только при смене ступени или парашюта.
struct StageStatus: Equatable {
    var remaining: Int
    var chute: ChuteState
    var action: StageAction
    var hasSolid: Bool

    /// Номер ступени, которую затронет нажатие, — как в стопке ступеней: пуск и отделение — текущая (1),
    /// парашют — верхняя строка стопки.
    var number: Int { action == .armChute ? max(remaining, 1) : 1 }
}

/// Ускорение времени для меню: меняется редко.
struct WarpStatus: Equatable {
    var index: Int
    var factor: Double
    var blocked: WarpResetReason?
}

/// Система отсчёта скорости на навболе.
enum SpeedFrame: Equatable {
    case orbit, surface
}

/// Состояние HUD и игровой цикл UI: ввод → `advance` → снимок для отрисовки.
/// Кадр приходит от `FrameDriver` (CADisplayLink). Чтобы статичные элементы не перерисовывались
/// каждый кадр, наблюдаемые поля разбиты: `telemetry` меняется каждый кадр (верхняя полоса, навбол),
/// `sas`, `stageStatus`, `warp`, `solidLocked` — только при изменении значения.
@MainActor
@Observable
final class FlightHUDModel {
    @ObservationIgnored private(set) var snapshot: WorldSnapshot
    /// Телеметрия кадра — читают только вьюхи, которым она нужна каждый кадр.
    private(set) var telemetry: FlightTelemetry
    private(set) var sas: SASMode
    private(set) var stageStatus: StageStatus
    private(set) var warp: WarpStatus
    /// РДТТ горит — тяга не регулируется.
    private(set) var solidLocked: Bool
    /// РСУ: блоки, включено, монотопливо. Меняется редко (при работе сопел — вместе с остатком топлива).
    private(set) var rcs: RCSStatus
    /// Корабль на площадке (до отрыва): второстепенные контролы приглушаются. Меняется редко.
    private(set) var onPad: Bool
    /// Главное следующее действие (подсветка кнопки); меняется редко.
    private(set) var guide: HUDAction?
    /// Миссия «Выход на орбиту» применима: Терра, полёт начат с площадки.
    private(set) var missionActive = false
    /// Наибольший достигнутый шаг миссии (0…5): не откатывается.
    private(set) var missionProgress = 0
    /// Высотомер показывает высоту над рельефом (у поверхности), иначе над уровнем моря.
    private(set) var altimeterOverTerrain = false
    /// Детали активного корабля сверху вниз: стек ступеней и экипаж в HUD. Меняется при отделении.
    private(set) var parts: [PartID]
    private(set) var toast: HUDToast?
    /// Панель итогов полёта: авария или посадка.
    private(set) var result: FlightResult?
    /// Подсказка первого полёта (показывает вьюха, если подсказки включены).
    private(set) var hint: HUDHint?
    /// Наибольшее число ступеней за полёт: «Ступень N из M» (отделённые уже не в телеметрии).
    private(set) var totalStages = 0
    /// Тяга 0…1 — положение ползунка, сохраняется между кадрами.
    var throttle: Double = 0
    var isPaused = false
    var isPanelOpen = false
    /// Режим камеры (зеркало `feedback.cameraMode`).
    private(set) var cameraMode: CameraMode = .follow
    /// Скорость на навболе: nil — авто (у поверхности — относительно поверхности).
    private(set) var speedFrameOverride: SpeedFrame? = nil
    /// Узел манёвра (меняется только при правке) — для кнопок, которым не нужна телеметрия узла каждый кадр.
    private(set) var maneuverNode: ManeuverNode?
    var hasManeuver: Bool { maneuverNode != nil }
    /// Карта: прогноз, отметки, проекция в экран (через рендер).
    let map: MapModel
    /// Ручка Δv узла, которую держит палец (карта); применяется в `tick`, перерисовки не вызывает.
    @ObservationIgnored var maneuverDrag: ManeuverDrag? {
        didSet {
            // Перетаскивание закончилось любым способом — отправляем итоговое значение.
            if maneuverDrag == nil { commitDragDraft() }
        }
    }
    /// Локальный черновик узла во время перетаскивания: в физику уходит не чаще `MapModel.editInterval`.
    @ObservationIgnored private var dragDraft: ManeuverNode?
    @ObservationIgnored private var dragDirty = false
    @ObservationIgnored private var lastDragSend: TimeInterval = 0
    /// «К узлу» имеет смысл: узел есть и до прожига больше `ManeuverStatus.warpLead`. Меняется редко.
    private(set) var canWarpToManeuver = false

    /// Кнопки ориентации: время нажатия (секунды часов кадра); пишутся жестами, читаются в `tick`, перерисовки не вызывают.
    @ObservationIgnored private var attitudeHeld: [AttitudeButton: TimeInterval] = [:]
    /// Режим «ТОЧНО»: ввод кнопок ориентации ×0.3.
    var fineControl = false

    /// Нажатие/отпускание кнопки ориентации; повторное нажатие уже удерживаемой не сбрасывает разгон.
    func setAttitude(_ button: AttitudeButton, pressed: Bool, now: TimeInterval = CACurrentMediaTime()) {
        if pressed {
            if attitudeHeld[button] == nil { attitudeHeld[button] = now }
        } else {
            attitudeHeld[button] = nil
        }
    }

    /// Тангаж, рыскание и крен −1…1 на момент `now`; противоположные кнопки вместе дают 0.
    func attitudeAxes(now: TimeInterval) -> (pitch: Double, yaw: Double, roll: Double) {
        func axis(_ plus: AttitudeButton, _ minus: AttitudeButton) -> Double {
            func value(_ b: AttitudeButton) -> Double {
                attitudeHeld[b].map { AttitudeInputCurve.value(heldFor: now - $0, fine: fineControl) } ?? 0
            }
            let hasPlus = attitudeHeld[plus] != nil, hasMinus = attitudeHeld[minus] != nil
            if hasPlus && hasMinus { return 0 }
            return value(plus) - value(minus)
        }
        return (axis(.pitchUp, .pitchDown), axis(.yawRight, .yawLeft), axis(.rollRight, .rollLeft))
    }

    /// Кнопки исчезают из иерархии вместе с жестами (карта, перезапуск): сбрасываем ввод вручную.
    private func resetAttitudeInput() {
        attitudeHeld.removeAll()
    }

    /// Поступательный джойстик РСУ: вправо (x) и вверх (z), −1…1.
    @ObservationIgnored var rcsRightInput = 0.0
    @ObservationIgnored var rcsUpInput = 0.0
    /// Кнопки «вперёд» и «назад» РСУ (удержание).
    @ObservationIgnored var rcsForwardPressed = false
    @ObservationIgnored var rcsBackPressed = false
    /// Поступательная команда РСУ по осям корабля: x — вправо, y — вперёд по носу, z — вверх. В физику уходит только при включённом РСУ.
    var translationInput: Vec3 {
        Vec3(rcsRightInput, (rcsForwardPressed ? 1 : 0) - (rcsBackPressed ? 1 : 0), rcsUpInput)
    }

    /// Рендер, звук, вибрация и наклон; подключает RootView.
    @ObservationIgnored var feedback: FlightFeedback? {
        didSet {
            if let feedback { cameraMode = feedback.cameraMode }
            map.renderer = feedback?.renderer
        }
    }

    /// Интерактивный урок (nil — обычный полёт). Пока он держит физику на паузе, `tick` принимает ввод, но не двигает мир.
    /// Меняется, когда тур «Все кнопки» запускают из меню паузы поверх текущего полёта.
    private(set) var tutorial: TutorialController?
    /// Меню ускорения времени открывалось (счётчик для шага «попробуйте»); перерисовки не вызывает.
    @ObservationIgnored private var warpMenuCount = 0
    /// Скорость последнего касания поверхности, м/с (итог и ошибка урока «К Луне»).
    @ObservationIgnored private var touchdownSpeed: Double?

    @ObservationIgnored private var sim: any FlightSimulation
    private let makeSimulation: () -> any FlightSimulation
    /// Экипаж полёта (5.4): портреты HUD и реакции.
    let crew: CrewModel
    @ObservationIgnored private var lastTick: TimeInterval?
    @ObservationIgnored private var advisor = FlightAdvisor()
    @ObservationIgnored private var toastExpiry: TimeInterval = 0
    @ObservationIgnored private var toastCounter = 0
    /// Жесты камеры, накопленные с прошлого кадра.
    @ObservationIgnored private var pendingCamera = CameraInput()
    @ObservationIgnored private var cameraPending = false

    /// `scenario` — сцена отладки/CI: сцены карты открывают карту сразу.
    /// `crew` — экипаж полёта; nil — по местам кабин корабля.
    init(makeSimulation: @escaping () -> any FlightSimulation = { MockFlight() }, scenario: DemoScenario? = nil,
         tutorial: TutorialID? = nil, crew: [CrewMember]? = nil) {
        self.makeSimulation = makeSimulation
        self.tutorial = tutorial.map { TutorialController(id: $0) }
        self.map = MapModel()
        let sim = makeSimulation()
        self.sim = sim
        let snapshot = sim.snapshot
        let t = snapshot.telemetry
        self.snapshot = snapshot
        self.telemetry = t
        self.sas = t.sas
        self.stageStatus = Self.stageStatus(t)
        self.warp = Self.warpStatus(t)
        self.solidLocked = Self.solidLocked(t)
        self.rcs = t.rcs
        self.onPad = t.situation == .prelaunch
        self.guide = Self.guideAction(t)
        self.missionActive = t.body == .terra && t.situation == .prelaunch
        self.altimeterOverTerrain = AltimeterMode.overTerrain(previous: false, t)
        self.parts = Self.activeParts(snapshot)
        self.crew = CrewModel(crew: crew ?? CrewModel.crew(forParts: Self.activeParts(snapshot)),
                              override: scenario?.crewOverride)
        self.maneuverNode = t.maneuver?.node
        self.canWarpToManeuver = Self.canWarp(t)
        self.throttle = snapshot.vessels.first(where: { $0.id == snapshot.activeVessel })?.throttle ?? 0
        self.totalStages = t.stages.count
        if let scenario, scenario.opensMap {
            map.focus = scenario.mapFocus
            map.isOpen = true
        }
        saveTutorialCheckpoint()
    }

    /// Один кадр игрового цикла; `now` — время кадра в секундах (CACurrentMediaTime).
    func tick(now: TimeInterval) {
        if toast != nil, now >= toastExpiry {
            self.toast = nil
        }
        flushCamera()
        guard !isPaused else { lastTick = nil; return }
        // Длинные паузы (фон, отладчик) не превращаем в скачок симуляции.
        let delta = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 0
        lastTick = now
        let tilt = feedback?.tiltInput() ?? (pitch: 0, roll: 0)
        let axes = attitudeAxes(now: now)
        sim.setInput(ControlInput(
            throttle: throttle,
            pitch: min(max(axes.pitch + tilt.pitch, -1), 1),
            yaw: axes.yaw,
            roll: min(max(axes.roll + tilt.roll, -1), 1),
            translation: rcs.enabled ? translationInput : .zero
        ))
        applyManeuverDrag(now: now, delta: delta)
        if let tutorial, tutorial.holdsPhysics {
            // Пауза урока: мир стоит, но сцена рисуется (камера), карта считает прогноз узла,
            // а действия игрока доходят до шага.
            feedback?.frame(snapshot: snapshot, events: [], frameDelta: delta)
            map.update(sim: sim, now: now)
            tutorialFrame(tutorial, delta: 0)
            return
        }
        let events = sim.advance(realDelta: delta)
        noteTouchdown(events)
        publish(sim.snapshot)
        feedback?.frame(snapshot: snapshot, events: events, frameDelta: delta)
        feedback?.crew(crew.update(telemetry: snapshot.telemetry, events: events, dt: delta))
        map.update(sim: sim, now: now)
        advise(events: events, now: now)
        if let message = events.compactMap(Self.message(for:)).last {
            show(message, now: now)
        }
        if let tutorial { tutorialFrame(tutorial, delta: delta) }
    }

    // MARK: - Обучение

    /// Один кадр урока: действия игрока и телеметрия → шаг; пауза физики синхронизируется со звуком.
    private func tutorialFrame(_ tutorial: TutorialController, delta: Double) {
        guard tutorial.isActive else { return }
        let held = tutorial.holdsPhysics
        if tutorial.update(lessonInput(), delta: delta) { saveTutorialCheckpoint() }
        // К скруглению игра сама возвращается к ×1.
        if tutorial.forcesRealTime, telemetry.warpIndex > 0 {
            send(.setWarp(index: 0))
        }
        if tutorial.holdsPhysics != held { feedback?.setPaused(tutorial.holdsPhysics || isPaused) }
    }

    /// Что урок видит в игре сейчас: телеметрия, ввод, карта, отсутствующие элементы.
    func lessonInput() -> LessonInput {
        var input = LessonInput(telemetry: telemetry, throttle: throttle,
                                yawRightHeld: attitudeHeld[.yawRight] != nil)
        let dpad: [AttitudeButton] = [.pitchUp, .pitchDown, .yawLeft, .yawRight]
        input.dpadHeld = dpad.contains { attitudeHeld[$0] != nil }
        input.mapOpen = map.isOpen
        input.warpMenuCount = warpMenuCount
        input.time = snapshot.time
        input.touchdownSpeed = touchdownSpeed
        let mapSnapshot = map.snapshot
        // После выполненного узла его прогноз уже не нужен: встреча — по текущей траектории.
        let pending = telemetry.maneuver.map { !$0.isDone } ?? false
        let trajectory = (pending ? mapSnapshot.maneuver?.trajectory : nil) ?? mapSnapshot.trajectory
        if let encounter = trajectory?.encounter, encounter.body == .luna {
            input.lunaPeriapsis = encounter.periapsisAltitude
            input.encounterTime = encounter.time
        }
        input.unavailable = lessonUnavailable()
        return input
    }

    /// Элементы, которых сейчас нет на экране: шаги тура про них пропускаются.
    private func lessonUnavailable() -> Set<LessonElement> {
        var out: Set<LessonElement> = []
        if crew.isEmpty { out.insert(.crew) }
        if !rcs.available { out.insert(.rcs) }
        if !missionActive { out.insert(.mission) }
        if telemetry.stages.isEmpty { out.insert(.stageStack) }
        if maneuverNode == nil { out.formUnion([.mapHandle, .mapPanel, .mapToNode, .mapNode]) }
        return out
    }

    /// Контрольная точка в начале шага (у симуляций без отката — nil, повтор шага недоступен).
    private func saveTutorialCheckpoint() {
        guard let tutorial else { return }
        let point = (sim as? FlightCheckpointing).map { LessonCheckpoint(sim: $0.checkpoint(), throttle: throttle) }
        tutorial.saveCheckpoint(point, input: lessonInput())
    }

    /// «Понятно» / «Дальше» / «Поехали» / «Готово» в пузыре урока.
    func tutorialAcknowledge() {
        guard let tutorial else { return }
        if tutorial.acknowledge(lessonInput()) { saveTutorialCheckpoint() }
        feedback?.setPaused(tutorial.holdsPhysics || isPaused)
    }

    /// «Дальше» на шаге «попробуйте»: пропустить.
    func tutorialSkip() {
        guard let tutorial else { return }
        if tutorial.skip(lessonInput()) { saveTutorialCheckpoint() }
        feedback?.setPaused(tutorial.holdsPhysics || isPaused)
    }

    /// Тур «Все кнопки» поверх текущего полёта (из меню паузы): без смены корабля и без перезапуска.
    func startTour() {
        tutorial?.exit()
        let tour = TutorialController(id: .controls, telemetry: telemetry)
        tutorial = tour
        saveTutorialCheckpoint()
        isPaused = false
        lastTick = nil
        feedback?.setPaused(tour.holdsPhysics)
    }

    /// Меню ускорения времени открыто (шаг «Время и ускорение» засчитывается).
    func noteWarpMenu() {
        warpMenuCount += 1
    }

    private func noteTouchdown(_ events: [SimEvent]) {
        for event in events {
            switch event {
            case .touchdown(let speed), .splashdown(let speed), .crash(let speed): touchdownSpeed = speed
            default: break
            }
        }
    }

    /// «Повторить шаг»: откат к началу шага, ввод сброшен, игра на паузе. Без контрольной точки — просто продолжить.
    func tutorialRepeat() {
        guard let tutorial else { return }
        guard let saved = tutorial.saved, let checkpointing = sim as? FlightCheckpointing else {
            tutorial.dismissFailure(lessonInput())
            return
        }
        checkpointing.restore(saved.sim)
        throttle = saved.throttle
        resetAttitudeInput()
        fineControl = false
        resetTranslationInput()
        sim.setInput(ControlInput(throttle: throttle))
        publish(sim.snapshot)
        map.invalidate()
        feedback?.renderer?.reset()
        feedback?.frame(snapshot: snapshot, events: [], frameDelta: 0)
        tutorial.didRestore(lessonInput())
        feedback?.setPaused(true)
    }

    /// «Выйти из урока»: полёт продолжается обычным.
    func exitTutorial() {
        tutorial?.exit()
        feedback?.setPaused(isPaused)
    }

    func send(_ command: FlightCommand) {
        sim.send(command)
        publish(sim.snapshot)
    }

    func toggleSAS() {
        send(.setSAS(sas == .off ? .hold : .off))
    }

    /// Кнопка RCS: вкл/выкл. Без блоков РСУ включить нельзя — тост; выключить можно всегда.
    func toggleRCS() {
        if rcs.enabled {
            resetTranslationInput()
            send(.setRCS(false))
        } else if rcs.available {
            send(.setRCS(true))
        } else {
            notify("Нет блоков РСУ")
        }
    }

    /// Джойстик и кнопки РСУ исчезают из иерархии вместе с жестами: сбрасываем ввод вручную.
    private func resetTranslationInput() {
        rcsRightInput = 0
        rcsUpInput = 0
        rcsForwardPressed = false
        rcsBackPressed = false
    }

    func pause() {
        isPaused = true
        isPanelOpen = false
        feedback?.setPaused(true)
    }

    func resume() {
        lastTick = nil
        isPaused = false
        feedback?.setPaused(false)
    }

    /// Перезапуск полёта.
    func restart() {
        dragDraft = nil
        dragDirty = false
        sim = makeSimulation()
        let fresh = sim.snapshot.telemetry
        missionActive = fresh.body == .terra && fresh.situation == .prelaunch
        missionProgress = 0
        crew.reset()
        publish(sim.snapshot)
        resetAttitudeInput()
        fineControl = false
        resetTranslationInput()
        toast = nil
        isPanelOpen = false
        maneuverDrag = nil
        map.invalidate()
        advisor = FlightAdvisor()
        touchdownSpeed = nil
        tutorial?.restartLesson(lessonInput())
        saveTutorialCheckpoint()
        totalStages = 0
        result = nil
        hint = nil
        feedback?.renderer?.reset()
        feedback?.recalibrate()
        pendingCamera = CameraInput(reset: true)
        resume()
        if let tutorial, tutorial.holdsPhysics { feedback?.setPaused(true) }
    }

    /// «Продолжить» на панели результата: скрыть до следующей посадки.
    func dismissResult() {
        advisor.dismissResult()
        result = nil
    }

    /// Крестик на плашке: подсказки скрыты до конца полёта.
    func dismissHints() {
        advisor.dismissHints()
        hint = nil
    }

    private func advise(events: [SimEvent], now: TimeInterval) {
        let wasSafe = advisor.landedSafely
        advisor.update(telemetry, throttle: throttle, events: events, now: now)
        if result != advisor.result { result = advisor.result }
        if hint != advisor.hint { hint = advisor.hint }
        if advisor.landedSafely, !wasSafe {
            UserDefaults.standard.set(true, forKey: HUDHint.doneKey)
        }
    }

    /// Сообщение-заглушка для ещё не готовых функций.
    func notify(_ text: String) {
        show(text, now: CACurrentMediaTime())
    }

    // MARK: - Камера

    /// Вращение камеры, рад (азимут, возвышение); копится до кадра.
    func cameraOrbit(_ delta: SIMD2<Float>) {
        pendingCamera.orbitDelta += delta
        cameraPending = true
    }

    /// Множитель расстояния камеры (< 1 — ближе).
    func cameraZoom(_ factor: Float) {
        guard factor.isFinite, factor > 0 else { return }
        pendingCamera.zoomFactor *= factor
        cameraPending = true
    }

    func cameraReset() {
        pendingCamera = CameraInput(reset: true)
        cameraPending = true
        flushCamera()
    }

    /// Свободная → следование → по курсу → свободная.
    func cycleCameraMode() {
        let all = CameraMode.allCases
        let next = all[((all.firstIndex(of: cameraMode) ?? 0) + 1) % all.count]
        cameraMode = next
        feedback?.cameraMode = next
    }

    private func flushCamera() {
        guard cameraPending else { return }
        feedback?.camera(pendingCamera)
        pendingCamera = CameraInput()
        cameraPending = false
    }

    // MARK: - Навбол

    /// Текущая система отсчёта скорости: выбор игрока или авто.
    func speedFrame(for t: FlightTelemetry) -> SpeedFrame {
        if let speedFrameOverride { return speedFrameOverride }
        switch t.situation {
        case .prelaunch, .landed, .splashed, .crashed, .flying: return .surface
        case .suborbital, .orbiting, .escaping: return .orbit
        }
    }

    func toggleSpeedFrame() {
        speedFrameOverride = speedFrame(for: telemetry) == .orbit ? .surface : .orbit
    }

    // MARK: - Карта и узел манёвра

    /// Узел манёвра активного корабля (телеметрия кадра).
    var maneuver: ManeuverStatus? { telemetry.maneuver }

    /// Кнопка «Карта»: полёт ↔ карта.
    func toggleMap() {
        maneuverDrag = nil
        // Кнопки ориентации исчезают из иерархии вместе с жестом: сбрасываем ввод вручную.
        resetAttitudeInput()
        resetTranslationInput()
        isPanelOpen = false
        map.isOpen.toggle()
    }

    func setMapFocus(_ focus: MapFocus) {
        map.focus = focus
    }

    /// Тап по карте: по орбите — поставить узел или перенести существующий в эту точку.
    func mapTap(at point: CGPoint) {
        guard map.isOpen, let time = map.orbitPick(at: point) else { return }
        placeManeuver(at: time)
    }

    /// Узел в момент `time`; если узел уже есть — переносится с тем же импульсом.
    func placeManeuver(at time: Double) {
        let t = max(time, snapshot.time + Self.minNodeLead)
        var node = telemetry.maneuver?.node ?? ManeuverNode(time: t)
        node.time = t
        send(.setManeuver(node))
    }

    /// Изменить компоненту Δv узла, м/с.
    func adjustManeuver(_ axis: ManeuverAxis, by deltaV: Double) {
        guard var node = telemetry.maneuver?.node, deltaV.isFinite, deltaV != 0 else { return }
        axis.add(deltaV, to: &node)
        send(.setManeuver(node))
    }

    /// Сдвиг узла по времени, с (не раньше чем через `minNodeLead` от текущего момента).
    func shiftManeuver(by seconds: Double) {
        guard var node = telemetry.maneuver?.node else { return }
        node.time = max(node.time + seconds, snapshot.time + Self.minNodeLead)
        send(.setManeuver(node))
    }

    func deleteManeuver() {
        dragDraft = nil
        dragDirty = false
        maneuverDrag = nil
        send(.setManeuver(nil))
    }

    /// Ускорение «на рельсах» до начала прожига.
    func warpToManeuver() {
        guard canWarpToManeuver else {
            if telemetry.maneuver != nil { notify("До узла меньше \(Int(ManeuverStatus.warpLead)) с") }
            return
        }
        send(.warpToManeuver)
    }

    /// Ближайший допустимый момент узла от текущего времени, с.
    private static let minNodeLead = 1.0

    /// Удерживаемая ручка Δv: скорость изменения растёт с отводом пальца и временем удержания.
    private func applyManeuverDrag(now: TimeInterval, delta: Double) {
        guard var drag = maneuverDrag else { return }
        guard map.isOpen, var node = dragDraft ?? telemetry.maneuver?.node else {
            maneuverDrag = nil
            return
        }
        let start = drag.start ?? now
        if drag.start == nil {
            drag.start = now
            maneuverDrag = drag
        }
        let rate = ManeuverDrag.rate(offset: drag.offset, held: now - start)
        let deltaV = rate * drag.handle.sign * delta
        guard deltaV != 0, deltaV.isFinite else { return }
        drag.handle.axis.add(deltaV, to: &node)
        dragDraft = node
        if now - lastDragSend >= MapModel.editInterval {
            lastDragSend = now
            sim.send(.setManeuver(node))
            dragDirty = false
        } else {
            dragDirty = true
        }
    }

    /// Итог перетаскивания, не ушедший в физику из-за ограничения частоты.
    private func commitDragDraft() {
        let node = dragDraft
        dragDraft = nil
        if dragDirty, let node { send(.setManeuver(node)) }
        dragDirty = false
    }

    // MARK: - Публикация кадра

    /// Шаги миссии для карточки (с учётом монотонного прогресса).
    var missionSteps: [MissionStep] { MissionChecklist.steps(telemetry, reached: missionProgress) }

    private func publish(_ snapshot: WorldSnapshot) {
        self.snapshot = snapshot
        let currentThrottle = snapshot.vessels.first(where: { $0.id == snapshot.activeVessel })?.throttle ?? throttle
        if throttle != currentThrottle { throttle = currentThrottle }
        let t = snapshot.telemetry
        telemetry = t
        if t.stages.count > totalStages { totalStages = t.stages.count }
        if sas != t.sas { sas = t.sas }
        let stage = Self.stageStatus(t)
        if stageStatus != stage { stageStatus = stage }
        let warp = Self.warpStatus(t)
        if self.warp != warp { self.warp = warp }
        let solid = Self.solidLocked(t)
        if solidLocked != solid { solidLocked = solid }
        if rcs != t.rcs { rcs = t.rcs }
        if !(t.rcs.enabled && t.rcs.available) { resetTranslationInput() }
        let pad = t.situation == .prelaunch
        if onPad != pad { onPad = pad }
        let action = Self.guideAction(t)
        if guide != action { guide = action }
        if missionActive {
            let done = MissionChecklist.completed(t)
            if done > missionProgress { missionProgress = done }
        }
        let overTerrain = AltimeterMode.overTerrain(previous: altimeterOverTerrain, t)
        if altimeterOverTerrain != overTerrain { altimeterOverTerrain = overTerrain }
        let shipParts = Self.activeParts(snapshot)
        if parts != shipParts { parts = shipParts }
        let node = t.maneuver?.node
        if maneuverNode != node { maneuverNode = node }
        let canWarp = Self.canWarp(t)
        if canWarpToManeuver != canWarp { canWarpToManeuver = canWarp }
    }

    /// Что подсветить: совет помощника подъёма, затем «Ступень» при пустой ступени и для парашюта.
    private static func guideAction(_ t: FlightTelemetry) -> HUDAction? {
        if let action = AscentGuide.advice(t)?.action { return action }
        if t.nextStageAction == .separate, let stage = t.stages.first,
           stage.fuelCapacity > 0, stage.fuelFraction < 0.01 {
            return .stage
        }
        if t.nextStageAction == .armChute, t.chute == .stowed, t.chuteSafe,
           t.verticalSpeed < -5, t.altitude < 30_000, t.mission.launched {
            return .stage
        }
        return nil
    }

    private static func activeParts(_ snapshot: WorldSnapshot) -> [PartID] {
        snapshot.vessels.first(where: { $0.id == snapshot.activeVessel })?.parts ?? []
    }

    private static func canWarp(_ t: FlightTelemetry) -> Bool {
        guard let status = t.maneuver else { return false }
        return status.timeToBurn > ManeuverStatus.warpLead
    }

    private static func stageStatus(_ t: FlightTelemetry) -> StageStatus {
        StageStatus(remaining: t.stages.count, chute: t.chute, action: t.nextStageAction, hasSolid: t.stages.first?.hasSolid ?? false)
    }

    private static func warpStatus(_ t: FlightTelemetry) -> WarpStatus {
        WarpStatus(index: t.warpIndex, factor: t.warpFactor, blocked: t.warpBlocked)
    }

    private static func solidLocked(_ t: FlightTelemetry) -> Bool {
        t.stages.first?.hasSolid == true && t.stages.first?.hasLiquidEngine != true && t.solidBurning
    }

    private func show(_ text: String, now: TimeInterval) {
        toastCounter += 1
        toast = HUDToast(id: toastCounter, text: text)
        toastExpiry = now + 2.5
    }

    nonisolated static func message(for event: SimEvent) -> String? {
        switch event {
        case .ignition(_, let solid):
            return solid ? "Зажигание РДТТ" : "Двигатели зажжены"
        case .flameout:
            return "Топливо текущей ступени выработано"
        case .separation:
            return "Нижняя ступень отделена"
        case .chuteDeployed:
            return "Парашют выпущен"
        case .chuteOpened:
            return "Купол раскрыт"
        case .maxQ(let pascals):
            return "Макс. скоростной напор · \(HUDFormat.fixed(pascals / 1_000, digits: 1)) кПа"
        case .touchdown(let speed):
            return "Касание · \(HUDFormat.speed(speed))"
        case .splashdown(let speed):
            return "Приводнение · \(HUDFormat.speed(speed))"
        case .crash(let speed):
            return "Авария · \(HUDFormat.speed(speed))"
        case .soiChanged(_, let to):
            return "Сфера влияния: \(Bodies.body(to).name)"
        case .partDestroyed(let part):
            return "Сгорела деталь: \(part.spec.name)"
        case .warpReset(let reason):
            return "Ускорение сброшено: \(warpReasonText(reason))"
        }
    }

    nonisolated static func warpReasonText(_ reason: WarpResetReason) -> String {
        switch reason {
        case .atmosphere: "в атмосфере"
        case .terrain: "близко к поверхности"
        case .thrust: "работает двигатель"
        case .soiChange: "смена сферы влияния"
        case .maneuver: "узел манёвра"
        }
    }
}
