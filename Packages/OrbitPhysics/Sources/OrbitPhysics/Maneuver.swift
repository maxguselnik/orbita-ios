import Foundation

/// Узел манёвра: импульс Δv (м/с) в момент `time` (время симуляции) в осях орбиты.
public struct ManeuverNode: Sendable, Hashable, Codable {
    public var time: Double
    public var prograde: Double
    public var normal: Double
    public var radial: Double

    public init(time: Double, prograde: Double = 0, normal: Double = 0, radial: Double = 0) {
        self.time = time
        self.prograde = prograde
        self.normal = normal
        self.radial = radial
    }

    public var deltaV: Double { (prograde * prograde + normal * normal + radial * radial).squareRoot() }
}

/// Чем закончился участок траектории.
public enum PatchEnd: Sendable, Hashable {
    /// Участок не закончился в горизонте прогноза (замкнутая орбита или улёт далеко).
    case none
    /// Падение на тело (ниже уровня моря).
    case impact
    /// Вход в сферу влияния тела.
    case enterSOI(BodyID)
    /// Выход из сферы влияния в систему родителя.
    case exitSOI(BodyID)
}

/// Участок траектории — коническое сечение в системе одного тела.
public struct TrajectoryPatch: Sendable {
    public let body: BodyID
    public let startTime: Double
    /// Конец участка (∞ — не ограничен).
    public let endTime: Double
    public let start: StateVector
    public let elements: OrbitElements
    public let end: PatchEnd

    /// Состояние в момент `t` (в системе `body`).
    public func state(at t: Double) -> StateVector {
        Kepler.propagate(position: start.position, velocity: start.velocity, mu: Bodies.body(body).mu, dt: t - startTime)
    }

    /// Точки для отрисовки (в системе `body`), до конца участка или одного оборота.
    public func points(count: Int = 128) -> [Vec3] {
        let span: Double
        if endTime.isFinite { span = endTime - startTime } else if elements.period.isFinite { span = elements.period } else { span = 6e5 }
        return (0...max(1, count)).map { state(at: startTime + span * Double($0) / Double(max(1, count))).position }
    }
}

/// Встреча с телом: время входа в SOI и высота перицентра там.
public struct Encounter: Sendable, Hashable {
    public var body: BodyID
    public var time: Double
    public var periapsisAltitude: Double
}

public struct Trajectory: Sendable {
    public var patches: [TrajectoryPatch]

    /// Первая встреча с Луной.
    public var encounter: Encounter? {
        for (i, p) in patches.enumerated() {
            if case .enterSOI(let b) = p.end, i + 1 < patches.count {
                let next = patches[i + 1]
                return Encounter(body: b, time: next.startTime,
                                 periapsisAltitude: next.elements.periapsisRadius - Bodies.body(b).radius)
            }
        }
        return nil
    }

    /// Возврат в SOI Терры: время выхода и перицентр у Терры.
    public var returnToTerra: Encounter? {
        for (i, p) in patches.enumerated() {
            if case .exitSOI(let b) = p.end, i + 1 < patches.count {
                let next = patches[i + 1]
                return Encounter(body: b, time: next.startTime,
                                 periapsisAltitude: next.elements.periapsisRadius - Bodies.body(b).radius)
            }
        }
        return nil
    }

    /// Падение: тело и время.
    public var impact: (body: BodyID, time: Double)? {
        for p in patches where p.end == .impact { return (p.body, p.endTime) }
        return nil
    }

    /// Участок и состояние в момент `t`.
    public func state(at t: Double) -> (body: BodyID, state: StateVector)? {
        for p in patches where t >= p.startTime - 1e-9 && t <= p.endTime {
            return (p.body, p.state(at: t))
        }
        return nil
    }
}

/// Результат планирования манёвра.
public struct ManeuverPrediction: Sendable {
    public var node: ManeuverNode
    /// Тело, в системе которого выполняется импульс.
    public var body: BodyID
    /// Вектор Δv в инерциальной системе тела.
    public var deltaVVector: Vec3
    /// Время прожига на текущей тяге, с (∞ — нет тяги).
    public var burnTime: Double
    /// Траектория после манёвра (первый участок начинается в момент узла).
    public var trajectory: Trajectory
}

public enum TrajectoryPredictor {
    /// Число участков прогноза по умолчанию для карты и узла манёвра.
    public static let defaultMapPatches = 4

    /// Орты манёвра: прогрейд, нормаль, радиально наружу (перпендикулярно прогрейду в плоскости орбиты).
    public static func maneuverBasis(position r: Vec3, velocity v: Vec3) -> (prograde: Vec3, normal: Vec3, radial: Vec3) {
        let pro = v.normalized
        var n = r.cross(v).normalized
        if n.lengthSquared == 0 { n = .unitZ }
        return (pro, n, pro.cross(n))
    }

    public static func deltaVVector(node: ManeuverNode, position: Vec3, velocity: Vec3) -> Vec3 {
        let b = maneuverBasis(position: position, velocity: velocity)
        return b.prograde * node.prograde + b.normal * node.normal + b.radial * node.radial
    }

    /// Время прожига по уравнению Циолковского при постоянной тяге.
    public static func burnTime(deltaV: Double, mass: Double, thrust: Double, isp: Double) -> Double {
        guard thrust > 0, isp > 0, mass > 0 else { return deltaV > 0 ? .infinity : 0 }
        let ve = isp * standardGravity
        let mf = mass * exp(-deltaV / ve)
        return (mass - mf) * ve / thrust
    }

    /// Прогноз патченными кониками: до `maxPatches` участков (Терра ↔ Луна).
    public static func predict(body: BodyID, state: StateVector, time: Double, maxPatches: Int = 3) -> Trajectory {
        var patches: [TrajectoryPatch] = []
        var frame = body
        var r = state.position, v = state.velocity
        var t0 = time
        for k in 0..<max(1, maxPatches) {
            let b = Bodies.body(frame)
            let el = OrbitElements(position: r, velocity: v, mu: b.mu)
            let canChange = k < maxPatches - 1
            var horizon: Double
            var n: Int
            if frame == .terra {
                horizon = el.isClosed ? min(el.period, 6e6) : 6e6
                n = 520
            } else {
                let vinf = max(0, v.lengthSquared - 2 * b.mu / r.length).squareRoot()
                horizon = min(el.isClosed ? el.period : .infinity, 4 * b.soiRadius / max(60, vinf))
                if el.isClosed && el.apoapsisRadius > b.soiRadius { horizon = min(el.period, 6e6) }
                n = 320
            }
            func stop(_ rr: Vec3, _ dt: Double) -> PatchEnd? {
                let rm = rr.length
                if rm < b.radius { return .impact }
                if frame == .terra {
                    if canChange && (rr - World.lunaPosition(at: t0 + dt)).length < Bodies.luna.soiRadius {
                        return .enterSOI(.luna)
                    }
                } else if rm > b.soiRadius {
                    return .exitSOI(.terra)
                }
                return nil
            }
            var prev = 0.0
            var endT = Double.infinity
            var end = PatchEnd.none
            for i in 1...n {
                let dt = horizon * Double(i) / Double(n)
                let rr = Kepler.propagate(position: r, velocity: v, mu: b.mu, dt: dt).position
                if let e = stop(rr, dt) {
                    var lo = prev, hi = dt
                    for _ in 0..<40 {
                        let mid = 0.5 * (lo + hi)
                        if stop(Kepler.propagate(position: r, velocity: v, mu: b.mu, dt: mid).position, mid) != nil { hi = mid } else { lo = mid }
                    }
                    endT = t0 + hi
                    end = e
                    break
                }
                prev = dt
            }
            let patch = TrajectoryPatch(body: frame, startTime: t0, endTime: endT,
                                        start: StateVector(position: r, velocity: v), elements: el, end: end)
            patches.append(patch)
            switch end {
            case .enterSOI(let to), .exitSOI(let to):
                let sv = patch.state(at: endT)
                let c = World.convert(sv, from: frame, to: to, time: endT)
                r = c.position
                v = c.velocity
                frame = to
                t0 = endT
            case .none, .impact:
                return Trajectory(patches: patches)
            }
        }
        return Trajectory(patches: patches)
    }

    /// Прогноз после узла манёвра. Состояние в момент узла берётся из текущей траектории.
    public static func predict(node: ManeuverNode, body: BodyID, state: StateVector, time: Double,
                               mass: Double, thrust: Double, isp: Double, maxPatches: Int = 3,
                               preTrajectory: Trajectory? = nil) -> ManeuverPrediction? {
        let (nb, ns): (BodyID, StateVector)
        if node.time <= time {
            (nb, ns) = (body, state)
        } else {
            let pre = preTrajectory ?? predict(body: body, state: state, time: time, maxPatches: maxPatches)
            guard let s = pre.state(at: node.time) else { return nil }
            (nb, ns) = (s.body, s.state)
        }
        let dv = deltaVVector(node: node, position: ns.position, velocity: ns.velocity)
        let after = StateVector(position: ns.position, velocity: ns.velocity + dv)
        let traj = predict(body: nb, state: after, time: max(time, node.time), maxPatches: maxPatches)
        return ManeuverPrediction(node: node, body: nb, deltaVVector: dv,
                                  burnTime: burnTime(deltaV: node.deltaV, mass: mass, thrust: thrust, isp: isp),
                                  trajectory: traj)
    }

    /// Фаза Луны относительно корабля на орбите Терры: угол от корабля до Луны по направлению движения, рад (−π…π).
    public static func lunaPhase(position r: Vec3, velocity v: Vec3, time: Double) -> Double {
        let l = World.lunaPosition(at: time)
        let n = r.cross(v).normalized
        let rp = r.normalized, lp = (l - n * l.dot(n)).normalized
        return atan2(rp.cross(lp).dot(n), rp.dot(lp))
    }

    /// Фаза для гомановского перелёта к Луне с круговой орбиты радиуса `radius`, рад.
    public static func hohmannLunaPhase(radius: Double) -> Double {
        let a = 0.5 * (radius + Bodies.luna.orbitRadius)
        let tTransfer = Double.pi * (a * a * a / Bodies.terra.mu).squareRoot()
        return Double.pi - World.lunaAngularRate * tTransfer
    }

    /// Узел `node` с прогрейд-импульсом, подобранным так, чтобы Пе у Луны по прогнозу (как у карты) был ≈ `target`.
    /// Секущие от `node.prograde`, шаг не больше 5 м/с, не больше `maxIterations` прогнозов.
    /// nil — встречи с Луной нет или подбор не попал в `target ± tolerance`.
    public static func tuneLunaPeriapsis(node: ManeuverNode, body: BodyID, state: StateVector, time: Double,
                                         target: Double = 30_000, tolerance: Double = 5_000,
                                         maxIterations: Int = 12,
                                         maxPatches: Int = defaultMapPatches) -> ManeuverNode? {
        let pre = predict(body: body, state: state, time: time, maxPatches: maxPatches)
        func periapsis(_ dv: Double) -> Double? {
            var n = node
            n.prograde = dv
            guard let p = predict(node: n, body: body, state: state, time: time, mass: 1, thrust: 0, isp: 1,
                                  maxPatches: maxPatches, preTrajectory: pre),
                  let enc = p.trajectory.encounter, enc.body == .luna else { return nil }
            return enc.periapsisAltitude - target
        }
        guard var f0 = periapsis(node.prograde) else { return nil }
        var x0 = node.prograde
        var best = (dv: x0, error: abs(f0))
        // Второе приближение: Пе у Луны меняется на десятки км на 1 м/с.
        var x1 = x0 + 0.5
        var calls = 1
        while calls < maxIterations, best.error > 200 {
            calls += 1
            guard let f1 = periapsis(x1) else {
                // Встреча пропала — шаг вдвое короче.
                x1 = 0.5 * (x0 + x1)
                continue
            }
            if abs(f1) < best.error { best = (x1, abs(f1)) }
            guard f1 != f0 else { break }
            let step = max(-5, min(5, -f1 * (x1 - x0) / (f1 - f0)))
            (x0, f0) = (x1, f1)
            x1 += step
        }
        guard best.error <= tolerance else { return nil }
        var out = node
        out.prograde = best.dv
        return out
    }

    /// Гомановский импульс с круговой орбиты радиуса `radius` до орбиты Луны, м/с.
    public static func hohmannLunaDeltaV(radius: Double) -> Double {
        let mu = Bodies.terra.mu, r2 = Bodies.luna.orbitRadius
        return (mu / radius).squareRoot() * ((2 * r2 / (radius + r2)).squareRoot() - 1)
    }
}
