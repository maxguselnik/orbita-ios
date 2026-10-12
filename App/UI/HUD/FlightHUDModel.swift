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

    /// Оси джойстика и кнопки крена; пишутся жестами, читаются в `tick`, перерисовки не вызывают.
    @ObservationIgnored var pitchInput = 0.0
    @ObservationIgnored var yawInput = 0.0
    @ObservationIgnored var rollLeftPressed = false
    @ObservationIgnored var rollRightPressed = false
    /// Крен −1…1: обе кнопки учитываются отдельно, отпускание одной не сбрасывает другую.
    var rollInput: Double { (rollRightPressed ? 1 : 0) - (rollLeftPressed ? 1 : 0) }
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

    @ObservationIgnored private var sim: any FlightSimulation
    private let makeSimulation: () -> any FlightSimulation
    @ObservationIgnored private var lastTick: TimeInterval?
    @ObservationIgnored private var advisor = FlightAdvisor()
    @ObservationIgnored private var toastExpiry: TimeInterval = 0
    @ObservationIgnored private var toastCounter = 0
    /// Жесты камеры, накопленные с прошлого кадра.
    @ObservationIgnored private var pendingCamera = CameraInput()
    @ObservationIgnored private var cameraPending = false

    /// `scenario` — сцена отладки/CI: сцены карты открывают карту сразу.
    init(makeSimulation: @escaping () -> any FlightSimulation = { MockFlight() }, scenario: DemoScenario? = nil) {
        self.makeSimulation = makeSimulation
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
        self.maneuverNode = t.maneuver?.node
        self.canWarpToManeuver = Self.canWarp(t)
        self.throttle = snapshot.vessels.first(where: { $0.id == snapshot.activeVessel })?.throttle ?? 0
        self.totalStages = t.stages.count
        if let scenario, scenario.opensMap {
            map.focus = scenario.mapFocus
            map.isOpen = true
        }
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
        sim.setInput(ControlInput(
            throttle: throttle,
            pitch: min(max(pitchInput + tilt.pitch, -1), 1),
            yaw: yawInput,
            roll: min(max(rollInput + tilt.roll, -1), 1),
            translation: rcs.enabled ? translationInput : .zero
        ))
        applyManeuverDrag(now: now, delta: delta)
        let events = sim.advance(realDelta: delta)
        publish(sim.snapshot)
        feedback?.frame(snapshot: snapshot, events: events, frameDelta: delta)
        map.update(sim: sim, now: now)
        advise(events: events, now: now)
        if let message = events.compactMap(Self.message(for:)).last {
            show(message, now: now)
        }
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
        publish(sim.snapshot)
        pitchInput = 0
        yawInput = 0
        rollLeftPressed = false
        rollRightPressed = false
        resetTranslationInput()
        toast = nil
        isPanelOpen = false
        maneuverDrag = nil
        map.invalidate()
        advisor = FlightAdvisor()
        totalStages = 0
        result = nil
        hint = nil
        feedback?.renderer?.reset()
        feedback?.recalibrate()
        pendingCamera = CameraInput(reset: true)
        resume()
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
        // Джойстик и кнопки крена исчезают из иерархии вместе с жестом: сбрасываем ввод вручную.
        pitchInput = 0
        yawInput = 0
        rollLeftPressed = false
        rollRightPressed = false
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
