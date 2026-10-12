import Foundation
import OrbitPhysics

/// Совет помощника подъёма: одна строка текста и целевой тангаж для маркера на навболе.
struct AscentAdvice: Equatable {
    var text: String
    /// Целевой тангаж, рад (курс всегда 90° — восток); nil — маркер не нужен.
    var targetPitch: Double?
}

/// Помощник подъёма на Терре: по телеметрии выбирает фазу. Чистая логика без UI.
enum AscentGuide {
    static let verticalLimit = 1_000.0
    static let cutoffApoapsis = 80_000.0
    static let spaceAltitude = 70_000.0
    static let targetHeading = Double.pi / 2
    /// Допуск отклонения, град.
    static let tolerance = 3.0
    /// Оценка времени прожига скругления, если посчитать нельзя, с.
    static let defaultBurn = 30.0

    /// Целевой тангаж, град: 90° до 1 км, 45° на 10 км, 10° на 45 км, 0° с 60 км (линейно по высоте).
    static func targetPitchDegrees(altitude: Double) -> Double {
        let points: [(alt: Double, pitch: Double)] = [
            (verticalLimit, 90), (10_000, 45), (45_000, 10), (60_000, 0),
        ]
        guard altitude > points[0].alt else { return 90 }
        for (a, b) in zip(points, points.dropFirst()) where altitude <= b.alt {
            return a.pitch + (b.pitch - a.pitch) * (altitude - a.alt) / (b.alt - a.alt)
        }
        return 0
    }

    static func advice(_ t: FlightTelemetry) -> AscentAdvice? {
        guard t.body == .terra else { return nil }
        switch t.situation {
        case .prelaunch:
            let text = t.nextStageAction == .ignite ? "Зажигание → Тяга MAX"
                : (t.thrust < 1 ? "Тяга MAX" : "Тяга MAX · ждите отрыва")
            return AscentAdvice(text: text, targetPitch: .pi / 2)
        case .orbiting:
            return AscentAdvice(text: "Вы на орбите", targetPitch: nil)
        case .flying, .suborbital:
            guard t.mission.launched else { return nil }
            if let orbit = t.orbit, orbit.periapsisAltitude > spaceAltitude {
                return AscentAdvice(text: "Вы на орбите", targetPitch: nil)
            }
            if t.altitude > spaceAltitude {
                return AscentAdvice(text: circularization(t), targetPitch: 0)
            }
            if t.verticalSpeed < -5, t.thrust < 1 { return nil }
            let target = targetPitchDegrees(altitude: t.altitude)
            let targetRad = target * .pi / 180
            if let apo = t.orbit?.apoapsisAltitude, apo >= cutoffApoapsis {
                let text = t.thrust >= 1 ? "Ап 80 км — тяга 0" : "Ап 80 км — инерция до космоса"
                return AscentAdvice(text: text, targetPitch: targetRad)
            }
            return AscentAdvice(text: ascent(t, target: target), targetPitch: targetRad)
        default:
            return nil
        }
    }

    private static func ascent(_ t: FlightTelemetry, target: Double) -> String {
        let dp = t.pitch * 180 / .pi - target
        var parts: [String] = []
        if abs(dp) >= tolerance {
            parts.append("\(dp > 0 ? "выше" : "ниже") на \(Int(abs(dp).rounded()))°")
        }
        if t.altitude <= verticalLimit {
            let head = "Вертикально до 1 км"
            return parts.isEmpty ? head : head + " · нос " + parts.joined(separator: ", ")
        }
        let dh = headingError(t.heading)
        if abs(dh) >= tolerance {
            parts.append("\(dh < 0 ? "левее" : "правее") на \(Int(abs(dh).rounded()))°")
        }
        let head = "Разворот на восток · цель \(Int(target.rounded()))°"
        return head + " · " + (parts.isEmpty ? "курс и тангаж верны" : "нос " + parts.joined(separator: ", "))
    }

    /// Отклонение курса от востока, град, −180…180 (минус — нос левее цели).
    static func headingError(_ heading: Double) -> Double {
        var d = (heading - targetHeading) * 180 / .pi
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private static func circularization(_ t: FlightTelemetry) -> String {
        if t.thrust >= 1 { return "Скругление: держите ПРОГРАДИЕНТ, тяга до Пе 70 км" }
        guard let toApo = t.orbit?.timeToApoapsis, toApo.isFinite else {
            return "Скругление у Ап: ПРОГРАДИЕНТ, тяга MAX за ~\(Int(defaultBurn)) с"
        }
        let burn = circularizationBurn(t) ?? defaultBurn
        let lead = Int((toApo - burn / 2).rounded())
        return lead <= 0 ? "Скругление: ПРОГРАДИЕНТ, тяга MAX сейчас"
            : "Скругление у Ап: ПРОГРАДИЕНТ, тяга MAX за ~\(lead) с"
    }

    /// Оценка времени прожига скругления у апоцентра: Δv до круговой скорости, пропорционально Δv ступени.
    static func circularizationBurn(_ t: FlightTelemetry) -> Double? {
        guard let o = t.orbit, o.apoapsisAltitude.isFinite, let stage = t.stages.first,
              stage.deltaV > 1, stage.burnTime > 0 else { return nil }
        let body = Bodies.body(t.body)
        let rA = body.radius + o.apoapsisAltitude
        let rP = body.radius + o.periapsisAltitude
        guard rP > 0, rA >= rP else { return nil }
        let a = (rA + rP) / 2
        let dv = (body.mu / rA).squareRoot() - (body.mu * (2 / rA - 1 / a)).squareRoot()
        guard dv > 0 else { return nil }
        return stage.burnTime * min(1, dv / stage.deltaV)
    }
}
