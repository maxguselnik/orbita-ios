import OrbitPhysics

/// Связывает кадр полёта со звуком, вибрацией и наклоном (поток D) по настройкам.
@MainActor
final class FlightFeedback {
    private let settings: GameSettings
    private let audio: any FlightAudio
    private let haptics: any FlightHaptics
    private let tilt = TiltInput()
    private var paused = false

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

    func frame(snapshot: WorldSnapshot, events: [SimEvent]) {
        syncSettings()
        audio.update(snapshot: snapshot, events: events)
        haptics.update(snapshot: snapshot, events: events)
    }

    func setPaused(_ value: Bool) {
        paused = value
        syncSettings()
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
