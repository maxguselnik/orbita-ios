import AVFoundation
import Synchronization
import UIKit
import OrbitPhysics

/// Фоновая музыка: генерируется процедурно (`MusicSynth`) в своём AVAudioEngine, без аудиофайлов.
/// Аудиосессия `.ambient` — смешивается с музыкой пользователя и молчит при беззвучном режиме.
@MainActor
final class ProceduralMusic: GameMusic {
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { resume() } else { fadeOutAndStop() }
        }
    }

    private var engine = AVAudioEngine()
    private let synth = MusicSynth()
    private var source: AVAudioSourceNode?
    private var connectedRate = 0.0
    private var control = MusicControl()
    private var lastCue: MusicCue?
    private let flags = AudioFlags()
    private let sessionObservers = ObserverBag()
    private var engineObservers = ObserverBag()
    private var sessionReady = false
    private var lastStartAttempt: ContinuousClock.Instant?
    private var pendingStop: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private let waker = MusicWaker()

    init() {
        waker.target = self
        let wake = waker.callback
        Self.observeSession(into: sessionObservers, flags: flags, wake: wake,
                            didBecomeActive: UIApplication.didBecomeActiveNotification)
        Self.observeEngine(engine, into: engineObservers, flags: flags, wake: wake)
    }

    /// Каждый кадр полёта: поднимает движок после прерывания или смены маршрута. Дёшево, если всё играет.
    func tick() {
        guard isEnabled, lastCue != nil else { return }
        ensureRunning()
    }

    /// Вызывается обработчиками уведомлений (через главный актор): в меню кадров нет.
    fileprivate func wake() {
        tick()
    }

    func play(_ cue: MusicCue) {
        let moodChanged = lastCue?.mood != cue.mood
        lastCue = cue
        guard isEnabled else { return }
        apply(cue, moodChanged: moodChanged)
        control.master = 1
        push()
        ensureRunning()
    }

    private func apply(_ cue: MusicCue, moodChanged: Bool) {
        control.profile = MusicProfile.make(mood: cue.mood, body: cue.body)
        control.intensity = min(max(cue.intensity, 0), 1)
        if moodChanged { control.moodSerial &+= 1 }
    }

    // MARK: - Движок

    private func push() {
        let value = control
        synth.control.withLock { $0 = value }
    }

    private func ensureRunning(allowRetry: Bool = true) {
        if flags.mediaReset.exchange(false, ordering: .relaxed) {
            rebuildEngine()
        }
        guard !flags.interrupted.load(ordering: .relaxed) else { return }
        let reconnect = flags.needsReconnect.exchange(false, ordering: .relaxed)
        if engine.isRunning && !reconnect { return }

        let now = ContinuousClock.now
        if !reconnect, let last = lastStartAttempt, now - last < .seconds(1) { return }
        lastStartAttempt = now
        func retryLater() {
            guard allowRetry else { return }
            scheduleRetry()
        }

        if !sessionReady {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.ambient, mode: .default, options: [])
                sessionReady = true
            } catch {
                retryLater()
                return
            }
        }
        try? AVAudioSession.sharedInstance().setActive(true)

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0 else { retryLater(); return }
        // Работающий движок с прежней частотой вывода пересоединять не нужно (смена маршрута без смены формата).
        if engine.isRunning && rate == connectedRate { return }
        if source == nil || rate != connectedRate {
            if engine.isRunning { engine.stop() }
            connect(rate: rate)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            retryLater()
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
            node = AVAudioSourceNode(format: format, renderBlock: synth.makeRenderBlock())
            engine.attach(node)
            source = node
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        connectedRate = rate
    }

    /// Один отложенный повтор запуска через ~1 с (в меню кадров нет).
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            guard self.isEnabled, self.lastCue != nil else { return }
            self.ensureRunning(allowRetry: false)
        }
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
        Self.observeEngine(engine, into: engineObservers, flags: flags, wake: waker.callback)
    }

    /// Включили снова: продолжаем последнюю реплику.
    private func resume() {
        pendingStop?.cancel()
        pendingStop = nil
        guard let cue = lastCue else { return }
        apply(cue, moodChanged: false)
        control.master = 1
        push()
        ensureRunning()
    }

    private func fadeOutAndStop() {
        retryTask?.cancel()
        retryTask = nil
        control.master = 0
        push()
        pendingStop?.cancel()
        pendingStop = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !Task.isCancelled, !self.isEnabled else { return }
            self.engine.stop()
            self.lastStartAttempt = nil
            self.pendingStop = nil
        }
    }

    // MARK: - Уведомления (обработчики вне main actor: выставляют флаги и будят главный актор)

    nonisolated private static func observeSession(into bag: ObserverBag, flags: AudioFlags,
                                                   wake: @escaping @Sendable () -> Void,
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
                wake()
            @unknown default:
                break
            }
        })
        bag.add(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                   object: nil, queue: nil) { note in
            // Смена категории сессии (например, звуками полёта) не требует пересоединения.
            if let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue: raw) == .categoryChange { return }
            flags.needsReconnect.store(true, ordering: .relaxed)
            wake()
        })
        bag.add(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                   object: nil, queue: nil) { _ in
            flags.mediaReset.store(true, ordering: .relaxed)
            flags.interrupted.store(false, ordering: .relaxed)
            wake()
        })
        bag.add(center.addObserver(forName: didBecomeActive,
                                   object: nil, queue: nil) { _ in
            flags.interrupted.store(false, ordering: .relaxed)
            flags.needsReconnect.store(true, ordering: .relaxed)
            wake()
        })
    }

    nonisolated private static func observeEngine(_ engine: AVAudioEngine, into bag: ObserverBag, flags: AudioFlags,
                                                  wake: @escaping @Sendable () -> Void) {
        bag.add(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                       object: engine, queue: nil) { _ in
            flags.needsReconnect.store(true, ordering: .relaxed)
            wake()
        })
    }
}

/// Слабая ссылка на музыку для обработчиков уведомлений: будит главный актор и вызывает `wake()`.
private final class MusicWaker: @unchecked Sendable {
    // @unchecked: `target` выставляется один раз в init на главном акторе.
    nonisolated(unsafe) weak var target: ProceduralMusic?

    var callback: @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor in self?.target?.wake() }
        }
    }
}
