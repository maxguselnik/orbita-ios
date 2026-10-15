import Foundation

/// Иерархические круговые эфемериды и системы координат патченных коник.
public enum World {
    public static let terraRotationRate = 2 * Double.pi / Bodies.terra.rotationPeriod
    public static let lunaAngularRate = orbitalRate(.luna)
    public static let lunaPeriod = 2 * Double.pi / lunaAngularRate
    public static let lunaInitialPhase = Bodies.luna.orbitPhase
    public static let padDirection = Vec3.unitX

    public static func orbitalRate(_ id: BodyID) -> Double {
        let b = Bodies.body(id)
        guard let parent = b.parent, b.orbitRadius > 0 else { return 0 }
        return (Bodies.body(parent).mu / pow(b.orbitRadius, 3)).squareRoot()
    }

    private static func relativeState(_ id: BodyID, at t: Double) -> StateVector {
        let b = Bodies.body(id)
        let rate = orbitalRate(id)
        let a = b.orbitPhase + rate * t
        let c: Double = cos(b.inclination), s: Double = sin(b.inclination)
        let ca: Double = cos(a), sa: Double = sin(a)
        let speed: Double = b.orbitRadius * rate
        let p = Vec3(ca, sa * c, sa * s) * b.orbitRadius
        let v = Vec3(-sa, ca * c, ca * s) * speed
        return StateVector(position: p, velocity: v)
    }

    private static func absoluteState(_ id: BodyID, at t: Double) -> StateVector {
        let local = relativeState(id, at: t)
        guard let parent = Bodies.body(id).parent else { return local }
        let p = absoluteState(parent, at: t)
        return StateVector(position: p.position + local.position, velocity: p.velocity + local.velocity)
    }

    public static func position(of id: BodyID, relativeTo frame: BodyID, at t: Double) -> Vec3 {
        if id == frame { return .zero }
        // Родитель/спутник без вычитания двух больших гелиоцентрических координат.
        if Bodies.body(id).parent == frame { return relativeState(id, at: t).position }
        if Bodies.body(frame).parent == id { return -relativeState(frame, at: t).position }
        return absoluteState(id, at: t).position - absoluteState(frame, at: t).position
    }

    public static func velocity(of id: BodyID, relativeTo frame: BodyID, at t: Double) -> Vec3 {
        if id == frame { return .zero }
        if Bodies.body(id).parent == frame { return relativeState(id, at: t).velocity }
        if Bodies.body(frame).parent == id { return -relativeState(frame, at: t).velocity }
        return absoluteState(id, at: t).velocity - absoluteState(frame, at: t).velocity
    }

    public static func lunaPhase(at t: Double) -> Double { wrap2Pi(lunaInitialPhase + lunaAngularRate * t) }
    public static func lunaPosition(at t: Double) -> Vec3 { relativeState(.luna, at: t).position }
    public static func lunaVelocity(at t: Double) -> Vec3 { relativeState(.luna, at: t).velocity }
    public static func terraRotation(at t: Double) -> Double { rotation(.terra, at: t) }

    public static func spin(_ body: BodyID) -> Vec3 {
        let period = Bodies.body(body).rotationPeriod
        return period == 0 ? .zero : Vec3(0, 0, 2 * Double.pi / period)
    }

    public static func rotation(_ body: BodyID, at time: Double) -> Double { wrap2Pi(spin(body).z * time) }
    public static func toBodyFixed(_ p: Vec3, body: BodyID, time: Double) -> Vec3 {
        let a = rotation(body, at: time), c = cos(a), s = sin(a)
        return Vec3(c * p.x + s * p.y, -s * p.x + c * p.y, p.z)
    }
    public static func fromBodyFixed(_ p: Vec3, body: BodyID, time: Double) -> Vec3 {
        let a = rotation(body, at: time), c = cos(a), s = sin(a)
        return Vec3(c * p.x - s * p.y, s * p.x + c * p.y, p.z)
    }
    static func bodyRotation(_ body: BodyID, time: Double) -> Quat {
        Quat(axis: .unitZ, angle: rotation(body, at: time))
    }
    public static func surfaceVelocity(body: BodyID, position: Vec3) -> Vec3 { spin(body).cross(position) }
    public static func railsMinimumAltitude(_ body: BodyID) -> Double {
        max(Bodies.body(body).atmosphereHeight, 6_000)
    }
    public static func speedOfSound(altitude: Double, body: BodyID = .terra) -> Double {
        let b = Bodies.body(body)
        return (1.4 * b.gasConstant * b.temperature(altitude: altitude)).squareRoot()
    }

    public static func convert(_ s: StateVector, from: BodyID, to: BodyID, time: Double) -> StateVector {
        StateVector(position: s.position + position(of: from, relativeTo: to, at: time),
                    velocity: s.velocity + velocity(of: from, relativeTo: to, at: time))
    }

    public static func soiTarget(body: BodyID, position r: Vec3, time: Double) -> BodyID? {
        for child in Bodies.children(of: body) {
            if (r - position(of: child, relativeTo: body, at: time)).length < Bodies.body(child).soiRadius {
                return child
            }
        }
        let b = Bodies.body(body)
        return r.length > b.soiRadius ? b.parent : nil
    }

    /// Газ и излучение считаются отдельно: в вакууме нет «температуры воздуха».
    public static func thermalEnvironment(body id: BodyID, position r: Vec3, time: Double) -> ThermalEnvironment {
        let b = Bodies.body(id)
        let altitude = r.length - b.radius
        let sun = position(of: .sol, relativeTo: id, at: time) - r
        let daylight = id == .sol ? 1 : r.normalized.dot(sun.normalized)
        let ground = b.temperature(altitude: 0, daylight: daylight)
        let air = b.temperature(altitude: altitude, daylight: daylight)
        let density = b.density(altitude: altitude)
        // Средняя поглощённая звёздная энергия ∝ 1/d²; тень от текущего тела.
        let distance = max(Bodies.sol.radius, sun.length)
        let inShadow = id != .sol && r.dot(sun.normalized) < 0 && r.cross(sun.normalized).length < b.radius
        let stellar = inShadow ? 3 : min(Bodies.sol.surfaceTemperature,
                                         278 * (Bodies.terra.orbitRadius / distance).squareRoot())
        // Излучение самой звезды уже в `stellar`: у Сол «грунт» второй раз не учитываем.
        let view = id == .sol ? 0 : min(0.5, 0.5 * pow(b.radius / max(b.radius, r.length), 2))
        let radiation = pow(pow(stellar, 4) + view * pow(ground, 4), 0.25)
        return ThermalEnvironment(airTemperature: air, radiationTemperature: radiation, density: density)
    }
}

// MARK: - Рельеф и биомы

public enum Biome: String, Sendable, Hashable, Codable, CaseIterable {
    // Терра
    case launchPad, ocean, shores, lowlands, highlands, mountains, polarIce
    // Луна
    case lunarPlains, lunarCraters, lunarHighlands, lunarPoles
    case vellaPlains, vellaHighlands, ardaDunes, ardaHighlands, ardaPolarIce, gasBands, stellarSurface
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


    // MARK: Малые кратеры Луны (процедурные, по хешу ячейки)

    private struct CraterScale: Sendable {
        let cell: Double      // размер кубической ячейки, м
        let rMin: Double      // радиус кратера, м
        let rMax: Double
        let chance: Double    // вероятность кратера в ячейке
        let salt: UInt64
    }

    // Влияние кратера (вал) доходит до 1.5 радиуса < размера ячейки, поэтому хватает 3×3×3 ячеек.
    private static let craterScales: [CraterScale] = [
        CraterScale(cell: 6_000, rMin: 300, rMax: 2_500, chance: 0.85, salt: 0x1111),
        CraterScale(cell: 1_500, rMin: 80, rMax: 500, chance: 0.85, salt: 0x2222),
        CraterScale(cell: 400, rMin: 25, rMax: 130, chance: 0.75, salt: 0x3333),
    ]

    private static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private static func unitRand(_ h: UInt64) -> Double { Double(h >> 11) / Double(1 << 53) }

    /// Высота (м) и оттенок (−1 дно … +1 вал) малых кратеров в точке `d` (единичный вектор).
    private static func smallCraters(_ d: Vec3) -> (height: Double, shade: Double) {
        let R = Bodies.luna.radius
        let p = d * R
        var height = 0.0, shade = 0.0
        for sc in craterScales {
            let inv = 1 / sc.cell
            let ix = Int(floor(p.x * inv)), iy = Int(floor(p.y * inv)), iz = Int(floor(p.z * inv))
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                let cx = ix + dx, cy = iy + dy, cz = iz + dz
                var h = mix(UInt64(bitPattern: Int64(cx)) &* 0x9E37_79B1 ^ sc.salt)
                h = mix(h ^ UInt64(bitPattern: Int64(cy)) &* 0x85EB_CA77)
                h = mix(h ^ UInt64(bitPattern: Int64(cz)) &* 0xC2B2_AE3D)
                if unitRand(h) >= sc.chance { continue }
                h = mix(h)
                let jx = unitRand(h)
                h = mix(h)
                let jy = unitRand(h)
                h = mix(h)
                let jz = unitRand(h)
                h = mix(h)
                let rr = unitRand(h)
                h = mix(h)
                let depthK = 0.8 + 0.4 * unitRand(h)
                // Центр — на поверхности: проекция точки ячейки; кратер принадлежит ячейке,
                // только если проекция осталась внутри неё (иначе его не найдут соседи).
                let raw = Vec3((Double(cx) + jx) * sc.cell, (Double(cy) + jy) * sc.cell, (Double(cz) + jz) * sc.cell)
                let len = raw.length
                if len < 1 { continue }
                let c = raw * (R / len)
                if Int(floor(c.x * inv)) != cx || Int(floor(c.y * inv)) != cy || Int(floor(c.z * inv)) != cz { continue }
                let r = sc.rMin + (sc.rMax - sc.rMin) * rr * rr
                let dist = (p - c).length
                let x = dist / r
                if x >= 1.5 { continue }
                let depth = 0.2 * r * depthK
                var bowl = 0.0
                if x < 1 { let q = 1 - x * x; bowl = q * q }
                var rim = 0.0
                if x > 0.6 { let t = (x - 0.6) / 0.9; let s = sin(Double.pi * t); rim = s * s }
                height += -depth * bowl + 0.04 * r * depthK * rim
                shade += rim - bowl
            }}}
        }
        return (height, max(-1, min(1, shade)))
    }

    /// Оттенок малых кратеров Луны: −1 дно, +1 вал, 0 вне кратеров (для раскраски рендером).
    public static func craterShade(body: BodyID, direction: Vec3) -> Double {
        body == .luna ? smallCraters(direction.normalized).shade : 0
    }

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
            var h = lunaBase + waves(lunaWaves, d) + smallCraters(d).height
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
        case .vella:
            return 1_300 + 1_000 * sin(d.x * 9 + d.y * 4) + 650 * sin(d.z * 23 + d.x * 11)
                + 180 * sin(d.y * 83 - d.z * 47) + 45 * sin(d.x * 311 + d.z * 217)
        case .arda:
            return 800 + 650 * sin(d.x * 7 - d.y * 3) + 420 * sin(d.y * 19 + d.z * 9)
                + 130 * sin(d.z * 67 + d.x * 41) + 30 * sin(d.y * 283 + d.z * 191)
        case .sol, .taros: return 0
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
        case .vella: return height(body: body, direction: d) > 1_600 ? .vellaHighlands : .vellaPlains
        case .arda:
            if abs(lat) > 68 * Double.pi / 180 { return .ardaPolarIce }
            return height(body: body, direction: d) > 1_100 ? .ardaHighlands : .ardaDunes
        case .taros: return .gasBands
        case .sol: return .stellarSurface
        }
    }
}
