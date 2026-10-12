import Foundation
import QuartzCore

/// Лёгкий источник кадров для игрового цикла UI: CADisplayLink с частотой из настроек.
/// Сам ничего не рисует и не вызывает перерисовку SwiftUI — вьюхи обновляются только
/// через наблюдаемые поля модели, которые меняет обработчик кадра.
@MainActor
final class FrameDriver {
    private var link: CADisplayLink?
    private var onFrame: (@MainActor (TimeInterval) -> Void)?

    /// Желаемая частота; применяется сразу, в том числе к работающему драйверу.
    var frameRate: FrameRate = .hz90 {
        didSet { applyFrameRate() }
    }

    /// Запуск; `onFrame` получает время кадра (секунды, часы CACurrentMediaTime).
    func start(_ onFrame: @escaping @MainActor (TimeInterval) -> Void) {
        self.onFrame = onFrame
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(driver: self),
                                 selector: #selector(DisplayLinkTarget.step(_:)))
        self.link = link
        applyFrameRate()
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
    }

    fileprivate func step(_ link: CADisplayLink) {
        onFrame?(link.targetTimestamp)
    }

    private func applyFrameRate() {
        let hz = Float(frameRate.rawValue)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, hz), maximum: hz, preferred: hz)
    }
}

/// Цель CADisplayLink: держит драйвер слабо (CADisplayLink удерживает цель).
/// Если драйвер уже освобождён — останавливает ссылку сама.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var driver: FrameDriver?

    init(driver: FrameDriver) {
        self.driver = driver
    }

    @objc func step(_ link: CADisplayLink) {
        guard let driver else {
            link.invalidate()
            return
        }
        driver.step(link)
    }
}
