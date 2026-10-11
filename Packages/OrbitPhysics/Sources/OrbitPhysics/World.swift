import Foundation

/// Мир: вращение Терры, Луна «на рельсах», переходы между системами координат.
public enum World {
    /// Угловая скорость вращения Терры вокруг +Z, рад/с.
    public static let terraRotationRate = 2 * Double.pi / Bodies.terra.rotationPeriod
    /// Угловая скорость Луны по круговой орбите (из μ Терры), рад/с. Луна движется против часовой стрелки (как вращение Терры).
    public static let lunaAngularRate = (Bodies.terra.mu / pow(Bodies.luna.orbitRadius, 3)).squareRoot()
    public static let lunaPeriod = 2 * Double.pi / lunaAngularRate
    /// Фаза Луны (угол от +X) в момент t = 0, рад.
    public static let lunaInitialPhase = 2.6
    /// Направление на стартовую площадку в системе, связанной с Террой (экватор, долгота 0).
    public static let padDirection = Vec3.unitX

    public static func lunaPhase(at t: Double) -> Double { wrap2Pi(lunaInitialPhase + lunaAngularRate * t) }

    public static func lunaPosition(at t: Double) -> Vec3 {
        let a = lunaInitialPhase + lunaAngularRate * t
        return Vec3(cos(a), sin(a), 0) * Bodies.luna.orbitRadius
    }

    public static func lunaVelocity(at t: Double) -> Vec3 {
        let a = lunaInitialPhase + lunaAngularRate * t
        let s: Double = sin(a)
        let c: Double = cos(a)
        return Vec3(-s, c, 0) * (Bodies.luna.orbitRadius * lunaAngularRate)
    }

    /// Угол поворота Терры вокруг +Z, рад, в [0, 2π).
    public static func terraRotation(at t: Double) -> Double { wrap2Pi(terraRotationRate * t) }

    /// Угловая скорость вращения тела (вектор), рад/с.
    public static func spin(_ body: BodyID) -> Vec3 {
        body == .terra ? Vec3(0, 0, terraRotationRate) : .zero
    }

    /// Инерциальная система тела → система, связанная с поверхностью.
    public static func toBodyFixed(_ p: Vec3, body: BodyID, time: Double) -> Vec3 {
        guard body == .terra else { return p }
        let a = terraRotationRate * time
        let c = cos(a), s = sin(a)
        return Vec3(c * p.x + s * p.y, -s * p.x + c * p.y, p.z)
    }

    /// Связанная с поверхностью система → инерциальная.
    public static func fromBodyFixed(_ p: Vec3, body: BodyID, time: Double) -> Vec3 {
        guard body == .terra else { return p }
        let a = terraRotationRate * time
        let c = cos(a), s = sin(a)
        return Vec3(c * p.x - s * p.y, s * p.x + c * p.y, p.z)
    }

    /// Поворот тела на момент `time` (для ориентаций).
    static func bodyRotation(_ body: BodyID, time: Double) -> Quat {
        body == .terra ? Quat(axis: .unitZ, angle: terraRotationRate * time) : .identity
    }

    /// Скорость поверхности (и воздуха) в точке `position`, м/с.
    public static func surfaceVelocity(body: BodyID, position: Vec3) -> Vec3 {
        spin(body).cross(position)
    }

    /// Минимальная высота над уровнем моря, где разрешено ускорение «на рельсах».
    public static func railsMinimumAltitude(_ body: BodyID) -> Double {
        body == .terra ? Bodies.terra.atmosphereHeight : 6_000
    }

    /// Скорость звука на высоте, м/с.
    public static func speedOfSound(altitude: Double) -> Double {
        340.3 - 4.5e-3 * clamp(altitude, 0, 11_000)
    }

    /// Пересчёт состояния из системы `from` в систему `to` на момент `time`.
    public static func convert(_ s: StateVector, from: BodyID, to: BodyID, time: Double) -> StateVector {
        if from == to { return s }
        let lp = lunaPosition(at: time), lv = lunaVelocity(at: time)
        if from == .terra { return StateVector(position: s.position - lp, velocity: s.velocity - lv) }
        return StateVector(position: s.position + lp, velocity: s.velocity + lv)
    }
}

// MARK: - Рельеф и биомы

public enum Biome: String, Sendable, Hashable, Codable, CaseIterable {
    // Терра
    case launchPad, ocean, shores, lowlands, highlands, mountains, polarIce
    // Луна
    case lunarPlains, lunarCraters, lunarHighlands, lunarPoles
}

/// Процедурный рельеф: детерминированная функция от направления в системе, связанной с телом.
public enum Terrain {
    private struct Wave: Sendable {
        let dir: Vec3
        let freq: Double
        let amp: Double
        let phase: Double
    }

    private struct Crater: Sendable {
        let center: Vec3
        let radius: Double   // угловой, рад
        let depth: Double    // м
    }

    private static func unit(_ x: Double, _ y: Double, _ z: Double) -> Vec3 { Vec3(x, y, z).normalized }

    // Порт terraBase в 3D: сумма синусов от проекций на фиксированные направления.
    private static let terraWaves: [Wave] = [
        Wave(dir: unit(0.31, 0.92, 0.24), freq: 2.1, amp: 1_500, phase: 1.0),
        Wave(dir: unit(-0.62, 0.35, 0.70), freq: 3.7, amp: 900, phase: 2.0),
        Wave(dir: unit(0.80, -0.20, 0.56), freq: 9.0, amp: 400, phase: 0.5),
        Wave(dir: unit(-0.15, -0.71, 0.69), freq: 31, amp: 160, phase: 1.3),
        Wave(dir: unit(0.57, 0.57, -0.59), freq: 97, amp: 60, phase: 0.7),
        Wave(dir: unit(-0.70, 0.10, -0.71), freq: 311, amp: 20, phase: 0.2),
    ]
    private static let terraOffset = 150.0

    private static let lunaWaves: [Wave] = [
        Wave(dir: unit(0.20, 0.95, 0.24), freq: 5, amp: 900, phase: 0),
        Wave(dir: unit(-0.66, 0.30, 0.69), freq: 13, amp: 500, phase: 1),
        Wave(dir: unit(0.73, -0.36, 0.58), freq: 41, amp: 250, phase: 2),
        Wave(dir: unit(-0.20, -0.66, 0.72), freq: 131, amp: 90, phase: 0.4),
        Wave(dir: unit(0.52, 0.61, -0.60), freq: 419, amp: 30, phase: 2.2),
    ]
    private static let lunaBase = 1_700.0

    /// Кратеры Луны: детерминированный псевдослучайный набор.
    private static let craters: [Crater] = {
        var out: [Crater] = []
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<48 {
            let z = 2 * rnd() - 1
            let lon = 2 * Double.pi * rnd()
            let rxy = (1 - z * z).squareRoot()
            let c = Vec3(rxy * cos(lon), rxy * sin(lon), z)
            let radius = 0.01 + 0.11 * pow(rnd(), 2)      // 2…24 км при R = 200 км
            let depth = radius * Bodies.luna.radius * 0.12
            out.append(Crater(center: c, radius: radius, depth: depth))
        }
        return out
    }()

    private static func waves(_ ws: [Wave], _ d: Vec3) -> Double {
        var h = 0.0
        for w in ws { h += w.amp * sin(w.freq * d.dot(w.dir) + w.phase) }
        return h
    }

    private static func rawTerra(_ d: Vec3) -> Double { terraOffset + waves(terraWaves, d) }

    /// Высота стартовой площадки над уровнем моря, м.
    public static let padHeight: Double = max(60, rawTerra(World.padDirection))

    private static func padBlend(_ d: Vec3) -> Double {
        let ang = acos(clamp(d.dot(World.padDirection), -1, 1))
        let x = ang / 0.012
        return exp(-(x * x * x * x))
    }

    /// Высота рельефа над уровнем моря, м. `direction` — направление в системе, связанной с телом.
    /// На Терре отрицательная высота — дно океана.
    public static func height(body: BodyID, direction: Vec3) -> Double {
        let d = direction.normalized
        switch body {
        case .terra:
            let w = padBlend(d)
            return rawTerra(d) * (1 - w) + padHeight * w
        case .luna:
            var h = lunaBase + waves(lunaWaves, d)
            for c in craters {
                let cosA = d.dot(c.center)
                // Быстрый отсев: дальше 2 радиусов кратера.
                if cosA < cos(min(Double.pi, 2 * c.radius)) { continue }
                let x = acos(clamp(cosA, -1, 1)) / c.radius
                if x < 1 { h += c.depth * (x * x - 1) }
                let rim = (x - 1) / 0.25
                h += 0.3 * c.depth * exp(-rim * rim)
            }
            return h
        }
    }

    /// Высота твёрдой или водной поверхности над уровнем моря (океан — 0), м.
    public static func surfaceHeight(body: BodyID, direction: Vec3) -> Double {
        let h = height(body: body, direction: direction)
        return body == .terra ? max(0, h) : h
    }

    /// Океан ли в этой точке.
    public static func isOcean(body: BodyID, direction: Vec3) -> Bool {
        body == .terra && height(body: body, direction: direction) < 0
    }

    /// Биом в точке поверхности.
    public static func biome(body: BodyID, direction: Vec3) -> Biome {
        let d = direction.normalized
        let lat = asin(clamp(d.z, -1, 1))
        switch body {
        case .terra:
            if acos(clamp(d.dot(World.padDirection), -1, 1)) < 0.005 { return .launchPad }
            if abs(lat) > 70 * Double.pi / 180 { return .polarIce }
            let h = height(body: .terra, direction: d)
            if h < 0 { return .ocean }
            if h < 150 { return .shores }
            if h < 1_200 { return .lowlands }
            if h < 2_500 { return .highlands }
            return .mountains
        case .luna:
            if abs(lat) > 75 * Double.pi / 180 { return .lunarPoles }
            for c in craters where acos(clamp(d.dot(c.center), -1, 1)) < 1.2 * c.radius { return .lunarCraters }
            return height(body: .luna, direction: d) > 2_500 ? .lunarHighlands : .lunarPlains
        }
    }
}
