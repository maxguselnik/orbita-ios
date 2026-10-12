import OrbitPhysics

/// Раздаёт кадр полёта рендеру (B), звуку, вибрации и наклону (D) по настройкам;
/// принимает жесты камеры от UI (C).
@MainActor
final class FlightFeedback {
    private let settings: GameSettings
    private let audio: any FlightAudio
    private let haptics: any FlightHaptics
    private let tilt = TiltInput()
    private var paused = false
    /// 3D-сцена; подключает RootView.
    var renderer: (any FlightRenderer)?

    init(settings: GameSettings,
         audio: any FlightAudio = ProceduralAudio(),
         haptics: any FlightHaptics = GameHaptics()) {
        self.settings = settings
        self.audio = audio
        self.haptics = haptics
    }

    /// Наклон телефона для ввода (ноль, если опция выключена).
    func tiltInput() -> (pitch: Double, roll: Double) {
        syncSettings()
        let sample = tilt.read()
        return (sample.pitch, sample.roll)
    }

    func frame(snapshot: WorldSnapshot, events: [SimEvent], frameDelta: Double) {
        renderer?.update(snapshot: snapshot, events: events, frameDelta: frameDelta)
        syncSettings()
        audio.update(snapshot: snapshot, events: events)
        haptics.update(snapshot: snapshot, events: events)
    }

    /// Жесты камеры за кадр (C → B).
    func camera(_ input: CameraInput) {
        renderer?.apply(input)
    }

    var cameraMode: CameraMode {
        get { renderer?.cameraMode ?? .follow }
        set { renderer?.cameraMode = newValue }
    }

    func setPaused(_ value: Bool) {
        paused = value
        syncSettings()
    }

    /// Выход из полёта (в ангар): звук, вибрация и наклон выключаются до следующего `setPaused(false)`.
    func stop() {
        setPaused(true)
        if tilt.isRunning { tilt.stop() }
    }

    /// Новый полёт: текущий наклон телефона станет нулём.
    func recalibrate() {
        tilt.calibrate()
    }

    private func syncSettings() {
        audio.isEnabled = settings.soundEnabled && !paused
        haptics.isEnabled = settings.hapticsEnabled && !paused
        if settings.tiltControl, !tilt.isRunning {
            tilt.start()
        } else if !settings.tiltControl, tilt.isRunning {
            tilt.stop()
        }
    }
}
