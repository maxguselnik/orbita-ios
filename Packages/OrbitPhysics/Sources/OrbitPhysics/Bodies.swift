import Foundation

public enum BodyID: String, Sendable, Hashable, Codable, CaseIterable {
    case sol, vella, terra, luna, arda, taros
}

/// Игровая система в СИ. Радиус газового гиганта — нижний предел полёта, не грунт.
public struct CelestialBody: Sendable, Hashable {
    public let id: BodyID
    public let name: String
    public let radius: Double
    public let mu: Double
    public let atmosphereHeight: Double
    public let seaLevelDensity: Double
    public let scaleHeight: Double
    public let rotationPeriod: Double
    public let soiRadius: Double
    public let parent: BodyID?
    public let orbitRadius: Double
    public let orbitPhase: Double
    public let inclination: Double
    public let hasSolidSurface: Bool
    /// Средняя температура поверхности / условного нижнего уровня, К.
    public let surfaceTemperature: Double
    public let lapseRate: Double
    public let dayNightVariation: Double
    /// Удельная газовая постоянная, Дж/(кг·К), для числа Маха.
    public let minimumTemperature: Double
    public let gasConstant: Double

    public init(id: BodyID, name: String, radius: Double, mu: Double,
                atmosphereHeight: Double, seaLevelDensity: Double, scaleHeight: Double,
                rotationPeriod: Double, soiRadius: Double, parent: BodyID?, orbitRadius: Double,
                orbitPhase: Double = 0, inclination: Double = 0, hasSolidSurface: Bool = true,
                surfaceTemperature: Double = 288, lapseRate: Double = 0.0065,
                dayNightVariation: Double = 15, gasConstant: Double = 287.05, minimumTemperature: Double = 216) {
        self.id = id; self.name = name; self.radius = radius; self.mu = mu
        self.atmosphereHeight = atmosphereHeight; self.seaLevelDensity = seaLevelDensity
        self.scaleHeight = scaleHeight; self.rotationPeriod = rotationPeriod
        self.soiRadius = soiRadius; self.parent = parent; self.orbitRadius = orbitRadius
        self.orbitPhase = orbitPhase; self.inclination = inclination
        self.hasSolidSurface = hasSolidSurface; self.surfaceTemperature = surfaceTemperature
        self.lapseRate = lapseRate; self.dayNightVariation = dayNightVariation; self.gasConstant = gasConstant
        self.minimumTemperature = minimumTemperature
    }

    public func density(altitude: Double) -> Double {
        guard atmosphereHeight > 0, altitude < atmosphereHeight else { return 0 }
        return seaLevelDensity * exp(-max(0, altitude) / scaleHeight)
    }

    /// Упрощённая тропосфера и изотермический верхний слой. В вакууме это температура грунта, не воздуха.
    public func temperature(altitude: Double, daylight: Double = 0) -> Double {
        let surface = surfaceTemperature + dayNightVariation * clamp(daylight, -1, 1)
        return max(atmosphereHeight > 0 ? minimumTemperature : 3, surface - lapseRate * max(0, altitude))
    }

    /// Статическое давление идеального газа, Па. В вакууме — 0.
    public func pressure(altitude: Double) -> Double {
        density(altitude: altitude) * gasConstant * temperature(altitude: altitude)
    }
    public func relativePressure(altitude: Double) -> Double {
        pressure(altitude: altitude) / (Bodies.terra.seaLevelDensity * Bodies.terra.gasConstant * Bodies.terra.surfaceTemperature)
    }

    public var surfaceGravity: Double { mu / (radius * radius) }
}

public enum Bodies {
    public static let sol = CelestialBody(
        id: .sol, name: "Сол", radius: 26_160_000, mu: 1.1723328e18,
        atmosphereHeight: 0, seaLevelDensity: 0, scaleHeight: 1, rotationPeriod: 432_000,
        soiRadius: .infinity, parent: nil, orbitRadius: 0,
        hasSolidSurface: false, surfaceTemperature: 5_778, lapseRate: 0, dayNightVariation: 0)
    public static let vella = CelestialBody(
        id: .vella, name: "Велла", radius: 700_000, mu: 8.17e12,
        atmosphereHeight: 100_000, seaLevelDensity: 5, scaleHeight: 9_500, rotationPeriod: 80_500,
        soiRadius: 85_000_000, parent: .sol, orbitRadius: 9_830_000_000,
        orbitPhase: 0.4, inclination: 0.035,
        surfaceTemperature: 735, lapseRate: 0.007, dayNightVariation: 5, gasConstant: 188.9, minimumTemperature: 180)
    public static let terra = CelestialBody(
        id: .terra, name: "Терра", radius: 600_000, mu: 3.5316e12,
        atmosphereHeight: 70_000, seaLevelDensity: 1.225, scaleHeight: 5_600, rotationPeriod: 21_600,
        soiRadius: 84_159_286, parent: .sol, orbitRadius: 13_599_840_256, orbitPhase: 4.04)
    public static let luna = CelestialBody(
        id: .luna, name: "Луна", radius: 200_000, mu: 6.5138e10,
        atmosphereHeight: 0, seaLevelDensity: 0, scaleHeight: 1, rotationPeriod: 0,
        soiRadius: 2_429_000, parent: .terra, orbitRadius: 12_000_000,
        orbitPhase: 2.6, surfaceTemperature: 245, lapseRate: 0, dayNightVariation: 140)
    public static let arda = CelestialBody(
        id: .arda, name: "Арда", radius: 320_000, mu: 3.0136e11,
        atmosphereHeight: 50_000, seaLevelDensity: 0.18, scaleHeight: 3_500, rotationPeriod: 65_517,
        soiRadius: 48_000_000, parent: .sol, orbitRadius: 20_720_000_000,
        orbitPhase: 1.3, inclination: 0.01,
        surfaceTemperature: 210, lapseRate: 0.003, dayNightVariation: 35, gasConstant: 188.9, minimumTemperature: 120)
    public static let taros = CelestialBody(
        id: .taros, name: "Тарос", radius: 3_000_000, mu: 7.65e13,
        atmosphereHeight: 200_000, seaLevelDensity: 10, scaleHeight: 27_000, rotationPeriod: 36_000,
        soiRadius: 1_200_000_000, parent: .sol, orbitRadius: 68_770_000_000,
        orbitPhase: 2.3, inclination: 0.02, hasSolidSurface: false,
        surfaceTemperature: 165, lapseRate: 0.0003, dayNightVariation: 2, gasConstant: 3_600, minimumTemperature: 90)

    public static func body(_ id: BodyID) -> CelestialBody {
        switch id {
        case .sol: sol
        case .vella: vella
        case .terra: terra
        case .luna: luna
        case .arda: arda
        case .taros: taros
        }
    }

    public static func children(of parent: BodyID) -> [BodyID] {
        BodyID.allCases.filter { body($0).parent == parent }
    }
}

/// Температуры в К; плотность в кг/м³. В вакууме газ не переносит тепло.
public struct ThermalEnvironment: Sendable {
    public var airTemperature: Double
    public var radiationTemperature: Double
    public var density: Double
    public init(airTemperature: Double = 290, radiationTemperature: Double = 290, density: Double = 0) {
        self.airTemperature = airTemperature
        self.radiationTemperature = radiationTemperature
        self.density = density
    }
}
