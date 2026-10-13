import CoreGraphics
import Foundation
import OrbitPhysics

/// Перевод жеста в поворот и сдвиг детали (инструменты «Поворот» и «Сдвиг»). Чистые функции.
enum HangarGizmoMath {
    /// Шаг поворота и сдвига при включённом «шаге».
    static let angleStep = 15.0
    static let offsetStep = 0.1

    /// Оси корабля: 0 — X (тангаж), 1 — Y (крен), 2 — Z (рыскание).
    static func axis(_ index: Int) -> Vec3 {
        switch index {
        case 0: Vec3(1, 0, 0)
        case 1: Vec3(0, 1, 0)
        default: Vec3(0, 0, 1)
        }
    }

    /// Компонента вектора по индексу оси.
    static func component(_ v: Vec3, _ index: Int) -> Double {
        switch index {
        case 0: v.x
        case 1: v.y
        default: v.z
        }
    }

    static func setting(_ v: Vec3, _ index: Int, to value: Double) -> Vec3 {
        switch index {
        case 0: Vec3(value, v.y, v.z)
        case 1: Vec3(v.x, value, v.z)
        default: Vec3(v.x, v.y, value)
        }
    }

    /// Угол в диапазон −180…180.
    static func wrapped(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Привязка к шагу; `step == nil` — плавно.
    static func snapped(_ value: Double, step: Double?) -> Double {
        guard let step, step > 0 else { return value }
        return (value / step).rounded() * step
    }

    /// Поворот пальца вокруг центра детали на экране, градусы (по часовой на экране — плюс, ось Y вниз).
    static func angleDelta(center: CGPoint, from a: CGPoint, to b: CGPoint) -> Double {
        let a0 = atan2(a.y - center.y, a.x - center.x)
        let a1 = atan2(b.y - center.y, b.x - center.x)
        return wrapped((a1 - a0) * 180 / .pi)
    }

    /// Знак поворота вокруг оси `index`: положительный поворот переводит первую ось плоскости кольца
    /// во вторую (правая тройка); на экране это по часовой (+1) или против (−1) в зависимости от ракурса.
    /// `first` и `second` — экранные направления этих осей (`HangarPreview.screenDirection`).
    static func handedness(first: CGVector, second: CGVector) -> Double {
        let cross = first.dx * second.dy - first.dy * second.dx
        return cross >= 0 ? 1 : -1
    }

    /// Оси плоскости кольца вокруг оси `index`: (index+1)%3 × (index+2)%3 = index.
    static func ringAxes(_ index: Int) -> (Int, Int) {
        ((index + 1) % 3, (index + 2) % 3)
    }

    /// Сдвиг вдоль оси, м: проекция смещения пальца на экранное направление оси, делённая на длину метра на экране.
    static func offsetMeters(translation: CGSize, direction: CGVector, pointsPerMeter: Double) -> Double {
        guard pointsPerMeter > 1e-6 else { return 0 }
        return (Double(translation.width * direction.dx + translation.height * direction.dy)) / pointsPerMeter
    }

    /// Строка значения угла: «15°», «−30°».
    static func degreesText(_ value: Double) -> String {
        let v = (value * 10).rounded() / 10
        let body = v == v.rounded() ? String(Int(abs(v))) : String(format: "%.1f", abs(v))
        return (v < 0 ? "−" : "") + body + "°"
    }

    /// Строка значения сдвига: «0.2 м», «−0.1 м».
    static func metersText(_ value: Double) -> String {
        let v = (value * 100).rounded() / 100
        return (v < 0 ? "−" : "") + String(format: "%.2f", abs(v)) + " м"
    }
}
