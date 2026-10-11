import Observation

/// Частота кадров рендера.
enum FrameRate: Int, CaseIterable, Codable, Sendable {
    case hz60 = 60
    case hz90 = 90
    case hz120 = 120
}

/// Настройки игры. Сохранение в JSON — этап 10.
@MainActor
@Observable
final class GameSettings {
    var frameRate: FrameRate = .hz90
    var soundEnabled = true
    var hapticsEnabled = true
    /// Управление наклоном телефона, по умолчанию выключено.
    var tiltControl = false
}
