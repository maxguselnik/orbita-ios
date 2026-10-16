import Foundation
import OrbitPhysics

/// Музыка на всё приложение: дирижёр выбирает настроение, `GameMusic` (D) играет.
/// Время смены — реальное (ускорение времени не торопит музыку).
@MainActor
final class MusicController {
    private let settings: GameSettings
    private let music: any GameMusic
    private let director = MusicDirector()
    private let start = ContinuousClock.now

    init(settings: GameSettings, music: any GameMusic = ProceduralMusic()) {
        self.settings = settings
        self.music = music
    }

    /// Космоцентр, цех, исследования.
    func menu() {
        apply(.menu)
    }

    /// Новый полёт: первая реплика без ожидания.
    func beginFlight() {
        director.reset()
    }

    /// Кадр полёта.
    func flight(_ telemetry: FlightTelemetry) {
        apply(.flight(telemetry))
    }

    /// Переключили «Музыка» в настройках.
    func syncSettings() {
        music.isEnabled = settings.musicEnabled
    }

    private func apply(_ place: MusicPlace) {
        music.isEnabled = settings.musicEnabled
        // Директор обновляется и при выключенном звуке: после включения играет текущее место.
        let elapsed = ContinuousClock.now - start
        let now = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        if let cue = director.update(place, now: now) {
            music.play(cue)
        }
        if case .flight = place { music.tick() }
    }
}
