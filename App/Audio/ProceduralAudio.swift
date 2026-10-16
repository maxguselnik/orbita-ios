import AVFoundation
import Synchronization
import UIKit
import OrbitPhysics

/// Звук полёта: всё синтезируется процедурно (`SynthDSP`) в одном AVAudioSourceNode.
/// Аудиосессия `.ambient` — смешивается с музыкой пользователя и молчит при беззвучном режиме.
@MainActor
final class ProceduralAudio: FlightAudio {
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { resumeClean() } else { fadeOutAndStop() }
        }
    }

    private var engine = AVAudioEngine()
    private let dsp = SynthDSP()
    private var source: AVAudioSourceNode?
    private var connectedRate = 0.0
    private var control = SynthControl()
    private let flags = AudioFlags()
    private let sessionObservers = ObserverBag()
    private var engineObservers = ObserverBag()
    private var sessionReady = false
    private var lastStartAttempt: ContinuousClock.Instant?
    private var pendingStop: Task<Void, Never>?

    init() {
        Self.observeSession(into: sessionObservers, flags: flags, didBecomeActive: UIApplication.didBecomeActiveNotification)
        Self.observeEngine(engine, into: engineObservers, flags: flags)
    }

    func update(snapshot: WorldSnapshot, events: [SimEvent]) {
        guard isEnabled else { return }
        let t = snapshot.telemetry

        control.master = 1
        let crashed = t.situation == .crashed
        let thrust = t.maxThrust > 0 ? min(max(t.thrust / t.maxThrust, 0), 1) : 0
        control.thrust = crashed ? 0 : thrust
        control.solid = (t.solidBurning && !crashed) ? 1 : 0
        // Статическое давление в атм: логарифмически, чтобы разреженный воздух ещё был слышен.
        let p = min(max(t.staticPressure, 0), 1.5) // плотные атмосферы (Велла, Тарос) не раздувают громкость
        control.air = p > 0 ? min(max(log10(p / 1e-4) / 4, 0), 1) : 0
        control.wind = crashed ? 0 : min(max(t.dynamicPressure / 25_000, 0), 1)
        control.heat = crashed ? 0 : min(max(t.heating, 0), 1)
        control.chute = (t.chute == .open && !crashed) ? min(control.wind * 4, 1) : 0
        control.space = (p < 1e-5 && !crashed) ? 1 : 0
        control.serial &+= 1

        for event in events {
            switch event {
            case .ignition(_, let solid):
                if solid { control.shots.solidIgnition &+= 1 } else { control.shots.ignition &+= 1 }
            case .flameout:
                control.shots.flameout &+= 1
            case .separation:
                control.shots.separation &+= 1
            case .chuteDeployed:
                control.shots.chuteDeployed &+= 1
            case .chuteOpened:
                control.shots.chuteOpened &+= 1
            case .touchdown(let speed):
                control.impactSpeed = speed
                control.shots.touchdown &+= 1
            case .splashdown(let speed):
                control.impactSpeed = speed
                control.shots.splashdown &+= 1
            case .crash(let speed):
                control.impactSpeed = speed
                control.shots.crash &+= 1
            default:
                break
            }
        }

        push()
        ensureRunning()
    }

    /// Голоса экипажа: короткие синтезированные звуки без слов, не больше трёх за вызов.
    func crew(_ cues: [CrewCue]) {
        guard isEnabled else { return }
        var voices: [CrewVoiceCue] = []
        for cue in cues {
            guard voices.count < 3, let kind = Self.voiceKind(cue.mood) else { continue }
            let tone = Self.tone(for: cue.memberID)
            voices.append(CrewVoiceCue(kind: kind, pitch: tone.pitch, formantScale: tone.formants,
                                       delay: Double(voices.count) * 0.11))
        }
        guard !voices.isEmpty else { return }
        control.crewCount = voices.count
        control.crew0 = voices[0]
        control.crew1 = voices.count > 1 ? voices[1] : CrewVoiceCue()
        control.crew2 = voices.count > 2 ? voices[2] : CrewVoiceCue()
        control.crewSerial &+= 1
        push()
        ensureRunning()
    }

    private static func voiceKind(_ mood: CrewMood) -> CrewVoiceKind? {
        switch mood {
        case .calm: nil
        case .awe: .awe
        case .joy: .joy
        case .strain: .strain
        case .panic: .panic
        case .crash: .crash
        }
    }

    /// Основной тон и сдвиг формант по члену экипажа; Гоша — повыше, неизвестный id — средний тон.
    private static func tone(for id: String) -> (pitch: Double, formants: Double) {
        switch id {
        case "lera": (215, 1.04)
        case "anton": (115, 0.92)
        case "mira": (235, 1.08)
        case "gosha": (225, 1.12)
        default: (170, 1.0)
        }
    }

    // MARK: - Движок

    private func push() {
        let value = control
        dsp.control.withLock { $0 = value }
    }

    private func ensureRunning() {
        if flags.mediaReset.exchange(false, ordering: .relaxed) {
            rebuildEngine()
        }
        guard !flags.interrupted.load(ordering: .relaxed) else { return }
        let reconnect = flags.needsReconnect.exchange(false, ordering: .relaxed)
        if engine.isRunning && !reconnect { return }

        let now = ContinuousClock.now
        if !reconnect, let last = lastStartAttempt, now - last < .seconds(1) { return }
        lastStartAttempt = now

        if !sessionReady {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.ambient, mode: .default, options: [])
                sessionReady = true
            } catch {
                return
            }
        }
        try? AVAudioSession.sharedInstance().setActive(true)

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0 else { return }
        if source == nil || rate != connectedRate || reconnect {
            if engine.isRunning { engine.stop() }
            connect(rate: rate)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Повторим не раньше чем через секунду, на следующем кадре.
        }
    }

    private func connect(rate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        control.sampleRate = rate
        push()
        let node: AVAudioSourceNode
        if let source {
            node = source
            engine.disconnectNodeOutput(node)
        } else {
            node = AVAudioSourceNode(format: format, renderBlock: dsp.makeRenderBlock())
            engine.attach(node)
            source = node
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        connectedRate = rate
    }

    /// После сброса медиасервисов старый движок мёртв — собираем заново.
    private func rebuildEngine() {
        if engine.isRunning { engine.stop() }
        if let source { engine.detach(source) }
        source = nil
        connectedRate = 0
        sessionReady = false
        engine = AVAudioEngine()
        engineObservers = ObserverBag()
        Self.observeEngine(engine, into: engineObservers, flags: flags)
    }

    /// Новый полёт или снятие с паузы: отменяем остановку и просим синтезатор сбросить прошлые уровни и хвосты.
    private func resumeClean() {
        pendingStop?.cancel()
        pendingStop = nil
        let old = control
        control = SynthControl()
        control.sampleRate = old.sampleRate
        control.serial = old.serial &+ 1
        control.shots = old.shots
        control.crewSerial = old.crewSerial
        control.resetToken = old.resetToken &+ 1
        push()
    }

    private func fadeOutAndStop() {
        control.master = 0
        control.serial &+= 1
        push()
        pendingStop?.cancel()
        pendingStop = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, !self.isEnabled else { return }
            self.engine.stop()
            self.lastStartAttempt = nil
            self.pendingStop = nil
        }
    }

    // MARK: - Уведомления (обработчики вне main actor: только выставляют флаги)

    nonisolated private static func observeSession(into bag: ObserverBag, flags: AudioFlags,
                                                   didBecomeActive: Notification.Name) {
        let center = NotificationCenter.default
        bag.add(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                   object: nil, queue: nil) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                flags.interrupted.store(true, ordering: .relaxed)
            case .ended:
                flags.interrupted.store(false, ordering: .relaxed)
                flags.needsReconnect.store(true, ordering: .relaxed)
            @unknown default:
                break
            }
        })
        bag.add(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                   object: nil, queue: nil) { _ in
            // Частота вывода могла смениться (наушники, AirPlay) — переподключимся.
            flags.needsReconnect.store(true, ordering: .relaxed)
        })
        bag.add(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                   object: nil, queue: nil) { _ in
            flags.mediaReset.store(true, ordering: .relaxed)
            flags.interrupted.store(false, ordering: .relaxed)
        })
        bag.add(center.addObserver(forName: didBecomeActive,
                                   object: nil, queue: nil) { _ in
            // Конец прерывания приходит не всегда — при возврате в приложение пробуем снова.
            flags.interrupted.store(false, ordering: .relaxed)
            flags.needsReconnect.store(true, ordering: .relaxed)
        })
    }

    nonisolated private static func observeEngine(_ engine: AVAudioEngine, into bag: ObserverBag, flags: AudioFlags) {
        bag.add(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                       object: engine, queue: nil) { _ in
            flags.needsReconnect.store(true, ordering: .relaxed)
        })
    }
}

/// Флаги от системных уведомлений к главному актору.
final class AudioFlags: Sendable {
    let interrupted = Atomic<Bool>(false)
    let needsReconnect = Atomic<Bool>(false)
    let mediaReset = Atomic<Bool>(false)
}

/// Держит токены наблюдателей и снимает их при освобождении.
/// Наполняется только с главного актора при создании; дальше не меняется.
final class ObserverBag: @unchecked Sendable {
    private var tokens: [any NSObjectProtocol] = []

    func add(_ token: any NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
