import Foundation
import Observation
import OrbitPhysics

/// Короткое сообщение поверх HUD (события, заглушки).
struct HUDToast: Equatable {
    let id: Int
    let text: String
}

/// Состояние HUD и игровой цикл UI: ввод → `advance` → снимок для отрисовки.
@MainActor
@Observable
final class FlightHUDModel {
    private(set) var snapshot: WorldSnapshot
    private(set) var toast: HUDToast?
    /// Тяга 0…1 — положение ползунка, сохраняется между кадрами.
    var throttle: Double = 0
    var isPaused = false
    var isPanelOpen = false

    /// Оси джойстика и крен −1…1; пишутся жестами, читаются в `tick`, перерисовки не вызывают.
    @ObservationIgnored var pitchInput = 0.0
    @ObservationIgnored var yawInput = 0.0
    @ObservationIgnored var rollInput = 0.0

    /// Звук, вибрация и наклон; подключает RootView.
    @ObservationIgnored var feedback: FlightFeedback?

    @ObservationIgnored private var sim: any FlightSimulation
    private let makeSimulation: () -> any FlightSimulation
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var toastExpiry = Date.distantPast
    @ObservationIgnored private var toastCounter = 0

    init(makeSimulation: @escaping () -> any FlightSimulation = { MockFlight() }) {
        self.makeSimulation = makeSimulation
        let sim = makeSimulation()
        self.sim = sim
        self.snapshot = sim.snapshot
    }

    var telemetry: FlightTelemetry { snapshot.telemetry }

    /// Один кадр игрового цикла.
    func tick(_ date: Date) {
        if toast != nil, date >= toastExpiry {
            self.toast = nil
        }
        guard !isPaused else { lastTick = nil; return }
        // Длинные паузы (фон, отладчик) не превращаем в скачок симуляции.
        let delta = lastTick.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        lastTick = date
        let tilt = feedback?.tiltInput() ?? (pitch: 0, roll: 0)
        sim.setInput(ControlInput(
            throttle: throttle,
            pitch: min(max(pitchInput + tilt.pitch, -1), 1),
            yaw: yawInput,
            roll: min(max(rollInput + tilt.roll, -1), 1)
        ))
        let events = sim.advance(realDelta: delta)
        snapshot = sim.snapshot
        feedback?.frame(snapshot: snapshot, events: events)
        if let message = events.compactMap(Self.message(for:)).last {
            show(message, now: date)
        }
    }

    func send(_ command: FlightCommand) {
        sim.send(command)
        snapshot = sim.snapshot
    }

    func toggleSAS() {
        send(.setSAS(telemetry.sas == .off ? .hold : .off))
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

    /// Перезапуск полёта (сейчас — новый MockFlight).
    func restart() {
        sim = makeSimulation()
        snapshot = sim.snapshot
        throttle = 0
        pitchInput = 0
        yawInput = 0
        rollInput = 0
        toast = nil
        isPanelOpen = false
        feedback?.recalibrate()
        resume()
    }

    /// Сообщение-заглушка для ещё не готовых функций.
    func notify(_ text: String) {
        show(text, now: Date())
    }

    private func show(_ text: String, now: Date) {
        toastCounter += 1
        toast = HUDToast(id: toastCounter, text: text)
        toastExpiry = now.addingTimeInterval(2.5)
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
