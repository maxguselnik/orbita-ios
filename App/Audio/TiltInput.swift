import CoreMotion
import Foundation

/// Управление наклоном телефона (по умолчанию выключено, включается `GameSettings.tiltControl`).
/// Опрос без обработчиков: `start()`, затем каждый кадр `read()`.
///
/// Знаки (одинаково для обеих альбомных ориентаций):
/// - `pitch` > 0 — верхний край экрана наклонён к себе («ручку на себя»);
/// - `roll` > 0 — телефон повёрнут по часовой стрелке, как руль вправо.
@MainActor
final class TiltInput {
    struct Sample: Sendable, Equatable {
        var pitch: Double
        var roll: Double
        static let zero = Sample(pitch: 0, roll: 0)
    }

    /// Мёртвая зона и угол полного отклонения, рад.
    var deadZone = 3.0 * .pi / 180
    var fullDeflection = 25.0 * .pi / 180
    /// Сглаживание выхода 0…1 (1 — без сглаживания).
    var responsiveness = 0.35

    private let manager = CMMotionManager()
    private(set) var isRunning = false
    private var reference: (elevation: Double, angle: Double)?
    private var output = Sample.zero

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard !isRunning, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates()
        isRunning = true
        reference = nil
        output = .zero
    }

    func stop() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        isRunning = false
        output = .zero
    }

    /// Текущее положение станет нулём (на следующем чтении).
    func calibrate() {
        reference = nil
    }

    /// Тангаж и крен −1…1. Если датчик выключен или ещё нет данных — ноль.
    func read() -> Sample {
        guard isRunning, let motion = manager.deviceMotion else { return .zero }
        let g = motion.gravity
        // Угол экрана к вертикали: 0 — экран вертикально, π/2 — лежит экраном вверх.
        let elevation = asin(min(max(-g.z, -1), 1))
        // Поворот в плоскости экрана (как руль); при телефоне плашмя теряет смысл.
        let planar = (g.x * g.x + g.y * g.y).squareRoot()
        let angle = atan2(g.y, g.x)

        guard let zero = reference else {
            reference = (elevation, angle)
            return output
        }

        let rawPitch = shape(zero.elevation - elevation)
        let rawRoll = shape(wrap(angle - zero.angle)) * min(planar / 0.3, 1)
        output.pitch += (rawPitch - output.pitch) * responsiveness
        output.roll += (rawRoll - output.roll) * responsiveness
        return output
    }

    private func shape(_ radians: Double) -> Double {
        let magnitude = abs(radians)
        guard magnitude > deadZone else { return 0 }
        let span = max(fullDeflection - deadZone, 0.01)
        let value = min((magnitude - deadZone) / span, 1)
        return radians < 0 ? -value : value
    }

    private func wrap(_ a: Double) -> Double {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x < -.pi { x += 2 * .pi }
        return x
    }
}
