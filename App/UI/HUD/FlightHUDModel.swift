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
    private(set) var toast: HUDToast?
    /// Панель итогов полёта: авария или посадка.
    private(set) var result: FlightResult?
    /// Подсказка первого полёта (показывает вьюха, если подсказки включены).
    private(set) var hint: HUDHint?
    /// Тяга 0…1 — положение ползунка, сохраняется между кадрами.
    var throttle: Double = 0
    var isPaused = false
    var isPanelOpen = false
    /// Режим камеры (зеркало `feedback.cameraMode`).
    private(set) var cameraMode: CameraMode = .follow
    /// Скорость на навболе: nil — авто (у поверхности — относительно поверхности).
    private(set) var speedFrameOverride: SpeedFrame? = nil

    /// Оси джойстика и кнопки крена; пишутся жестами, читаются в `tick`, перерисовки не вызывают.
    @ObservationIgnored var pitchInput = 0.0
    @ObservationIgnored var yawInput = 0.0
    @ObservationIgnored var rollLeftPressed = false
    @ObservationIgnored var rollRightPressed = false
    /// Крен −1…1: обе кнопки учитываются отдельно, отпускание одной не сбрасывает другую.
    var rollInput: Double { (rollRightPressed ? 1 : 0) - (rollLeftPressed ? 1 : 0) }

    /// Рендер, звук, вибрация и наклон; подключает RootView.
    @ObservationIgnored var feedback: FlightFeedback? {
        didSet {
            if let feedback { cameraMode = feedback.cameraMode }
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

    init(makeSimulation: @escaping () -> any FlightSimulation = { MockFlight() }) {
        self.makeSimulation = makeSimulation
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
            roll: min(max(rollInput + tilt.roll, -1), 1)
        ))
        let events = sim.advance(realDelta: delta)
        publish(sim.snapshot)
        feedback?.frame(snapshot: snapshot, events: events, frameDelta: delta)
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
        sim = makeSimulation()
        publish(sim.snapshot)
        throttle = 0
        pitchInput = 0
        yawInput = 0
        rollLeftPressed = false
        rollRightPressed = false
        toast = nil
        isPanelOpen = false
        advisor = FlightAdvisor()
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

    // MARK: - Публикация кадра

    private func publish(_ snapshot: WorldSnapshot) {
        self.snapshot = snapshot
        let t = snapshot.telemetry
        telemetry = t
        if sas != t.sas { sas = t.sas }
        let stage = Self.stageStatus(t)
        if stageStatus != stage { stageStatus = stage }
        let warp = Self.warpStatus(t)
        if self.warp != warp { self.warp = warp }
        let solid = Self.solidLocked(t)
        if solidLocked != solid { solidLocked = solid }
    }

    private static func stageStatus(_ t: FlightTelemetry) -> StageStatus {
        StageStatus(remaining: t.stages.count, chute: t.chute)
    }

    private static func warpStatus(_ t: FlightTelemetry) -> WarpStatus {
        WarpStatus(index: t.warpIndex, factor: t.warpFactor, blocked: t.warpBlocked)
    }

    private static func solidLocked(_ t: FlightTelemetry) -> Bool {
        t.stages.first?.hasSolid == true && t.solidBurning
    }

    private func show(_ text: String, now: TimeInterval) {
        toastCounter += 1
        toast = HUDToast(id: toastCounter, text: text)
        toastExpiry = now + 2.5
    }

    nonisolated static func message(for event: SimEvent) -> String? {
        switch event {
        case .ignition(let stage, let solid):
            return solid ? "Зажигание РДТТ · ступень \(stage)" : "Зажигание · ступень \(stage)"
        case .flameout(let stage, _):
            return "Топливо ступени \(stage) выработано"
        case .separation(let stage):
            return "Отделение ступени \(stage)"
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
        }
    }
}
