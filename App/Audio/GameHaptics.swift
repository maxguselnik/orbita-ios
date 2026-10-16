import CoreHaptics
import Synchronization
import OrbitPhysics

/// Вибрация полёта на Core Haptics: удары на события и непрерывный гул при работе двигателей.
/// Гул — один зацикленный плеер, интенсивность меняется динамическими параметрами не чаще ~12 раз/с.
@MainActor
final class GameHaptics: FlightHaptics {
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { shutDown() }
        }
    }

    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var engineRunning = false
    private let flags = HapticFlags()
    private var lastStartAttempt: ContinuousClock.Instant?

    private var rumble: CHHapticAdvancedPatternPlayer?
    private var rumbleOn = false
    private var sentIntensity: Float = -1
    private var sentSharpness: Float = -1
    private var lastSend: ContinuousClock.Instant?
    private var lastUpdate = ContinuousClock.now
    private var watchdog: Task<Void, Never>?

    private lazy var patterns = HapticPatterns()
    private var gripTracker = GripTracker()

    init() {}

    func update(snapshot: WorldSnapshot, events: [SimEvent]) {
        guard isEnabled, supported else { return }
        lastUpdate = .now
        guard ensureEngine() else { return }

        for event in events {
            switch event {
            case .ignition(_, let solid):
                play(solid ? patterns.solidIgnition : patterns.ignition)
            case .separation:
                play(patterns.separation)
            case .maxQ:
                play(patterns.maxQ)
            case .chuteOpened:
                play(patterns.chuteOpened)
            case .touchdown(let speed):
                play(HapticPatterns.touchdown(speed: speed))
            case .splashdown(let speed):
                play(HapticPatterns.splashdown(speed: speed))
            case .crash(let speed):
                stopRumble()
                play(HapticPatterns.crash(speed: speed))
            case .evaLanded(_, let speed):
                play(HapticPatterns.evaLanded(speed: speed))
            case .evaInjured, .evaDied:
                play(patterns.evaHurt)
            case .flagPlanted, .evaScienceCollected:
                play(patterns.evaTap)
            case .evaExited, .evaBoarded:
                play(patterns.evaHatch)
            default:
                break
            }
        }

        switch gripTracker.update(snapshot.controlled) {
        case .grabbed: play(patterns.evaGrip)
        case .released: play(patterns.evaTap)
        default: break
        }

        updateRumble(snapshot.telemetry)
    }

    /// Экипаж: лёгкий двойной тап на радость, резкий короткий на панику и аварию. Остальное — без вибрации.
    func crew(_ cues: [CrewCue]) {
        guard isEnabled, supported else { return }
        let pattern: CHHapticPattern?
        if cues.contains(where: { $0.mood == .panic || $0.mood == .crash }) {
            pattern = patterns.crewSharp
        } else if cues.contains(where: { $0.mood == .joy }) {
            pattern = patterns.crewJoy
        } else {
            return
        }
        lastUpdate = .now
        guard ensureEngine() else { return }
        play(pattern)
    }

    // MARK: - Движок

    private func ensureEngine() -> Bool {
        if flags.needsRestart.exchange(false, ordering: .relaxed) {
            // После сброса сервера все плееры недействительны.
            engineRunning = false
            dropRumble()
        }
        if flags.stopped.exchange(false, ordering: .relaxed) {
            engineRunning = false
            dropRumble()
        }
        if engineRunning { return true }

        let now = ContinuousClock.now
        if let last = lastStartAttempt, now - last < .seconds(1) { return false }
        lastStartAttempt = now

        if engine == nil {
            guard let created = try? CHHapticEngine() else { return false }
            created.playsHapticsOnly = true
            created.isAutoShutdownEnabled = false
            Self.installHandlers(on: created, flags: flags)
            engine = created
        }
        do {
            try engine?.start()
            engineRunning = true
        } catch {
            engineRunning = false
        }
        return engineRunning
    }

    /// Обработчики вызываются на служебной очереди Core Haptics — только флаги, без main actor.
    nonisolated private static func installHandlers(on engine: CHHapticEngine, flags: HapticFlags) {
        engine.resetHandler = {
            flags.needsRestart.store(true, ordering: .relaxed)
        }
        engine.stoppedHandler = { _ in
            flags.stopped.store(true, ordering: .relaxed)
        }
    }

    private func play(_ pattern: CHHapticPattern?) {
        guard let pattern, let engine else { return }
        do {
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            engineRunning = false
        }
    }

    private func shutDown() {
        stopRumble()
        dropRumble()
        engine?.stop(completionHandler: nil)
        engineRunning = false
        lastStartAttempt = nil
        lastSend = nil
    }

    // MARK: - Гул двигателей

    private func updateRumble(_ t: FlightTelemetry) {
        let thrust = t.maxThrust > 0 ? min(max(t.thrust / t.maxThrust, 0), 1) : 0
        let burning = thrust > 0.02 && t.situation != .crashed
        guard burning else {
            stopRumble()
            return
        }
        let shake = min(max(t.dynamicPressure / 40_000, 0), 1)
        var intensity = 0.25 + 0.55 * thrust + 0.15 * shake
        if t.solidBurning { intensity += 0.15 }
        let target = Float(min(intensity, 1))
        let sharpness: Float = t.solidBurning ? 0.25 : 0

        if !rumbleOn {
            startRumble(intensity: target, sharpness: sharpness)
            return
        }
        let now = ContinuousClock.now
        if let last = lastSend, now - last < .milliseconds(80) { return }
        guard abs(target - sentIntensity) > 0.04 || sharpness != sentSharpness else { return }
        send(intensity: target, sharpness: sharpness)
        lastSend = now
    }

    private func startRumble(intensity: Float, sharpness: Float) {
        guard let engine else { return }
        if rumble == nil {
            guard let pattern = patterns.rumble,
                  let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
            player.loopEnabled = true
            rumble = player
        }
        do {
            try rumble?.start(atTime: CHHapticTimeImmediate)
            rumbleOn = true
            send(intensity: intensity, sharpness: sharpness)
            lastSend = .now
            startWatchdog()
        } catch {
            dropRumble()
        }
    }

    private func send(intensity: Float, sharpness: Float) {
        let params = [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0),
        ]
        try? rumble?.sendParameters(params, atTime: CHHapticTimeImmediate)
        sentIntensity = intensity
        sentSharpness = sharpness
    }

    private func stopRumble() {
        guard rumbleOn else { return }
        try? rumble?.stop(atTime: CHHapticTimeImmediate)
        rumbleOn = false
        sentIntensity = -1
        watchdog?.cancel()
        watchdog = nil
    }

    private func dropRumble() {
        rumbleOn = false
        rumble = nil
        sentIntensity = -1
        watchdog?.cancel()
        watchdog = nil
    }

    /// Если кадры перестали приходить (пауза, фон), гул не должен жужжать бесконечно.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                if ContinuousClock.now - self.lastUpdate > .milliseconds(300) {
                    self.stopRumble()
                    return
                }
            }
        }
    }
}

/// Флаги от обработчиков Core Haptics к главному актору.
final class HapticFlags: Sendable {
    let needsRestart = Atomic<Bool>(false)
    let stopped = Atomic<Bool>(false)
}

/// Готовые паттерны (создаются один раз).
struct HapticPatterns {
    let ignition = HapticPatterns.make([
        .transient(0, intensity: 0.8, sharpness: 0.6),
        .continuous(0, duration: 0.35, intensity: 0.6, sharpness: 0.2, fade: true),
    ])
    let solidIgnition = HapticPatterns.make([
        .transient(0, intensity: 1, sharpness: 0.8),
        .continuous(0, duration: 0.45, intensity: 0.85, sharpness: 0.4, fade: true),
    ])
    let separation = HapticPatterns.make([
        .transient(0, intensity: 1, sharpness: 0.9),
        .transient(0.07, intensity: 0.7, sharpness: 0.5),
    ])
    let maxQ = HapticPatterns.make([
        .continuous(0, duration: 0.5, intensity: 0.5, sharpness: 0.1, fade: true),
    ])
    let chuteOpened = HapticPatterns.make([
        .transient(0, intensity: 0.6, sharpness: 0.3),
        .continuous(0.02, duration: 0.25, intensity: 0.4, sharpness: 0.1, fade: true),
    ])
    let crewJoy = HapticPatterns.make([
        .transient(0, intensity: 0.35, sharpness: 0.3),
        .transient(0.09, intensity: 0.3, sharpness: 0.3),
    ])
    let crewSharp = HapticPatterns.make([
        .transient(0, intensity: 0.9, sharpness: 0.9),
    ])
    let evaHurt = HapticPatterns.make([
        .transient(0, intensity: 1, sharpness: 0.9),
        .continuous(0, duration: 0.5, intensity: 0.8, sharpness: 0.3, fade: true),
        .transient(0.12, intensity: 0.8, sharpness: 0.7),
    ])
    let evaTap = HapticPatterns.make([
        .transient(0, intensity: 0.3, sharpness: 0.4),
    ])
    let evaGrip = HapticPatterns.make([
        .transient(0, intensity: 0.5, sharpness: 0.7),
    ])
    let evaHatch = HapticPatterns.make([
        .transient(0, intensity: 0.6, sharpness: 0.6),
        .transient(0.08, intensity: 0.45, sharpness: 0.3),
    ])
    /// Гул двигателей: долгое непрерывное событие, зацикливается плеером.
    let rumble = HapticPatterns.make([
        .continuous(0, duration: 30, intensity: 1, sharpness: 0.2, fade: false),
    ])

    static func touchdown(speed: Double) -> CHHapticPattern? {
        let k = Float(0.35 + min(max(speed, 0) / 10, 1) * 0.65)
        return make([.transient(0, intensity: k, sharpness: 0.4)])
    }

    /// Касание космонавта: лёгкая, растёт со скоростью.
    static func evaLanded(speed: Double) -> CHHapticPattern? {
        let k = Float(0.15 + min(max(speed, 0) / 8, 1) * 0.45)
        return make([.transient(0, intensity: k, sharpness: 0.3)])
    }

    /// Авария: сила растёт со скоростью удара (от 0.6 до 1 на 30 м/с).
    static func crash(speed: Double) -> CHHapticPattern? {
        let k = Float(0.6 + min(max(speed, 0) / 30, 1) * 0.4)
        return make([
            .transient(0, intensity: k, sharpness: 1),
            .continuous(0, duration: 0.8, intensity: k, sharpness: 0.3, fade: true),
            .transient(0.15, intensity: k * 0.8, sharpness: 0.7),
        ])
    }

    static func splashdown(speed: Double) -> CHHapticPattern? {
        let k = Float(0.4 + min(max(speed, 0) / 15, 1) * 0.5)
        return make([
            .transient(0, intensity: k, sharpness: 0.2),
            .continuous(0, duration: 0.4, intensity: k * 0.8, sharpness: 0.05, fade: true),
        ])
    }

    enum Step {
        case transient(TimeInterval, intensity: Float, sharpness: Float)
        case continuous(TimeInterval, duration: TimeInterval, intensity: Float, sharpness: Float, fade: Bool)
    }

    static func make(_ steps: [Step]) -> CHHapticPattern? {
        var events: [CHHapticEvent] = []
        var curves: [CHHapticParameterCurve] = []
        for step in steps {
            switch step {
            case let .transient(time, intensity, sharpness):
                events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ], relativeTime: time))
            case let .continuous(time, duration, intensity, sharpness, fade):
                events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                ], relativeTime: time, duration: duration))
                if fade {
                    curves.append(CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                        .init(relativeTime: time, value: 1),
                        .init(relativeTime: time + duration, value: 0),
                    ], relativeTime: 0))
                }
            }
        }
        return try? CHHapticPattern(events: events, parameterCurves: curves)
    }
}
