import Foundation

public enum BodyID: String, Sendable, Hashable, Codable, CaseIterable {
    case terra
    case luna
}

/// Небесное тело. Значения из docs/SPEC.md, раздел «Мир».
public struct CelestialBody: Sendable, Hashable {
    public let id: BodyID
    public let name: String
    /// Радиус, м.
    public let radius: Double
    /// Гравитационный параметр μ, м³/с².
    public let mu: Double
    /// Высота верхней границы атмосферы, м (0 — без атмосферы).
    public let atmosphereHeight: Double
    /// Плотность на уровне моря, кг/м³.
    public let seaLevelDensity: Double
    /// Шкала высоты, м.
    public let scaleHeight: Double
    /// Звёздные сутки, с (0 — не вращается).
    public let rotationPeriod: Double
    /// Радиус сферы влияния, м (`.infinity` для центрального тела).
    public let soiRadius: Double
    /// Родитель и радиус круговой орбиты «на рельсах», м.
    public let parent: BodyID?
    public let orbitRadius: Double

    /// Плотность атмосферы на высоте `altitude` над уровнем моря, кг/м³.
    public func density(altitude: Double) -> Double {
        guard atmosphereHeight > 0, altitude < atmosphereHeight else { return 0 }
        return seaLevelDensity * exp(-max(0, altitude) / scaleHeight)
    }

    /// Ускорение свободного падения на поверхности, м/с².
    public var surfaceGravity: Double { mu / (radius * radius) }
}

public enum Bodies {
    public static let terra = CelestialBody(
        id: .terra, name: "Терра",
        radius: 600_000, mu: 3.5316e12,
        atmosphereHeight: 70_000, seaLevelDensity: 1.225, scaleHeight: 5_600,
        rotationPeriod: 6 * 3_600,
        soiRadius: .infinity, parent: nil, orbitRadius: 0
    )

    public static let luna = CelestialBody(
        id: .luna, name: "Луна",
        radius: 200_000, mu: 6.5138e10,
        atmosphereHeight: 0, seaLevelDensity: 0, scaleHeight: 1,
        rotationPeriod: 0,
        soiRadius: 2_429_000, parent: .terra, orbitRadius: 12_000_000
    )

    public static func body(_ id: BodyID) -> CelestialBody {
        switch id {
        case .terra: terra
        case .luna: luna
        }
    }
}
