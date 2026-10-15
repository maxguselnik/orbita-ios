import Foundation

/// Перелёт с орбиты Терры к планете системы Сол (Велла, Арда, Тарос) для простой карты.
///
/// Модель: гомановский перелёт по круговым эфемеридам. Отлёт — в ближайшее окно, из точки орбиты, откуда
/// асимптота гиперболы смотрит по движению Терры (к внешним планетам) или против (к Велле); прогрейд
/// уточняется по сближению с планетой. Наклон орбиты планеты и неточность прожига снимают коррекции:
/// на середине перелёта (3D-подбор импульса Ньютоном до точки прицела у планеты) и после входа в её SOI
/// (подбор по прогнозу карты до Пе ≈ `targetPeriapsis`).
public enum PlanetTransfer {
    public static let planets: [BodyID] = [.vella, .arda, .taros]

    /// Целевая высота Пе у планеты, м: над атмосферой (нижней границей рельсов) с запасом.
    public static func targetPeriapsis(_ id: BodyID) -> Double { World.railsMinimumAltitude(id) + 30_000 }

    /// Годный Пе у планеты, м.
    public static func goodPeriapsis(_ id: BodyID) -> ClosedRange<Double> {
        let rails = World.railsMinimumAltitude(id)
        return (rails + 5_000)...(rails + 200_000)
    }

    /// Оценка коррекции в пути, при которой план отлёта считается годным, м/с.
    public static let goodCorrection = 300.0
    /// Предел Δv коррекции в пути, м/с.
    static let correctionLimit = 1_500.0

    // MARK: Окно

    static func angle(_ id: BodyID, at t: Double) -> Double {
        Bodies.body(id).orbitPhase + World.orbitalRate(id) * t
    }

    /// Время гомановского перелёта от орбиты Терры до орбиты планеты, с.
    public static func hohmannTime(_ id: BodyID) -> Double {
        let a = 0.5 * (Bodies.terra.orbitRadius + Bodies.body(id).orbitRadius)
        return Double.pi * (a * a * a / Bodies.sol.mu).squareRoot()
    }

    /// Скорость на бесконечности при отлёте от Терры: «+» — по ходу Терры (внешние планеты), «−» — против, м/с.
    public static func departureExcess(_ id: BodyID) -> Double {
        let mu = Bodies.sol.mu, r1 = Bodies.terra.orbitRadius, r2 = Bodies.body(id).orbitRadius
        return (mu / r1).squareRoot() * ((2 * r2 / (r1 + r2)).squareRoot() - 1)
    }

    /// Угол планеты впереди Терры в момент отлёта для гомановского перелёта, рад.
    static func requiredPhase(_ id: BodyID) -> Double {
        Double.pi - World.orbitalRate(id) * hohmannTime(id)
    }

    /// Синодический период Терра — планета, с.
    public static func synodicPeriod(_ id: BodyID) -> Double {
        2 * Double.pi / abs(World.orbitalRate(id) - World.orbitalRate(.terra))
    }

    /// Секунд от `time` до прожига отлёта с орбиты радиуса `radius` и периода `period` (как в `departure`): окно
    /// минус время ухода из SOI, окно прошло ≤ 2 оборотов назад — ещё годно. Для подписи меню.
    public static func timeToDeparture(_ id: BodyID, radius: Double, period: Double, time: Double) -> Double {
        let escape = escapeTime(radius: radius, excess: abs(departureExcess(id)))
        let earliest = time + ManeuverPlanner.minimumLead
        let window = earliest + escape + timeToWindow(id, time: earliest + escape, grace: 2 * period)
        return max(earliest, window - escape) - time
    }

    /// Секунд от `time` до ближайшего окна (момента выхода из SOI Терры), 0…синодический период.
    /// Окно прошло не больше `grace` секунд назад — отрицательное значение (ещё можно успеть).
    public static func timeToWindow(_ id: BodyID, time: Double, grace: Double = 0) -> Double {
        let omega = World.orbitalRate(id) - World.orbitalRate(.terra)
        let delta = requiredPhase(id) - (angle(id, at: time) - angle(.terra, at: time))
        var dt = wrap2Pi(omega > 0 ? delta : -delta) / abs(omega)
        let s = synodicPeriod(id)
        if dt > s - grace { dt -= s }
        return dt
    }

    /// Время от перицентра гиперболы отлёта радиуса `r` до границы SOI Терры, с.
    static func escapeTime(radius r: Double, excess vinf: Double) -> Double {
        let mu = Bodies.terra.mu
        let vp = (vinf * vinf + 2 * mu / r).squareRoot()
        return Kepler.timeToRadius(Bodies.terra.soiRadius, position: Vec3(r, 0, 0), velocity: Vec3(0, vp, 0),
                                   mu: mu, outbound: true) ?? 0
    }

    // MARK: Отлёт

    /// Узел отлёта с замкнутой орбиты Терры над атмосферой. nil — орбита не годится.
    public static func departure(to id: BodyID, state: StateVector, time: Double) -> ManeuverNode? {
        let terra = Bodies.terra
        let el = OrbitElements(position: state.position, velocity: state.velocity, mu: terra.mu)
        guard planets.contains(id), el.isClosed, el.period.isFinite, el.apoapsisRadius < terra.soiRadius,
              el.periapsisRadius > terra.radius + terra.atmosphereHeight else { return nil }
        let excess = departureExcess(id)
        let vinf = abs(excess)
        let r = state.position.length
        let escape = escapeTime(radius: r, excess: vinf)
        let lead = ManeuverPlanner.minimumLead
        // Окно — момент выхода из SOI; прожиг раньше на время ухода. Окно прошло на пару оборотов — ещё успеваем.
        let earliest = time + lead
        let window = earliest + escape + timeToWindow(id, time: earliest + escape, grace: 2 * el.period)
        let center = max(earliest, window - escape)

        // Точка прожига: перицентр гиперболы, повёрнутый от нужной асимптоты назад на её истинную аномалию.
        let n = state.position.cross(state.velocity).normalized
        let vt = World.velocity(of: .terra, relativeTo: .sol, at: center + escape).normalized * (excess >= 0 ? 1 : -1)
        var asymptote = vt - n * vt.dot(n)
        // Движение Терры почти по нормали орбиты корабля (полярная орбита): берём направление вдоль орбиты.
        if asymptote.lengthSquared < 0.01 { asymptote = state.velocity }
        asymptote = asymptote.normalized
        let e = 1 + r * vinf * vinf / terra.mu
        let burnDirection = rotate(asymptote, about: n, by: -acos(-1 / e))
        func orbit(at t: Double) -> StateVector {
            Kepler.propagate(position: state.position, velocity: state.velocity, mu: terra.mu, dt: t - time)
        }
        let start = max(earliest, center - 0.5 * el.period)
        var bestTime = start, bestCos = -2.0
        let steps = 360
        for k in 0...steps {
            let t = start + el.period * Double(k) / Double(steps)
            let c = orbit(at: t).position.normalized.dot(burnDirection)
            if c > bestCos { (bestTime, bestCos) = (t, c) }
        }

        // Прогрейд до нужной v∞, затем подбор прогрейда (и оборота) по сближению с планетой.
        var best: (node: ManeuverNode, distance: Double)?
        for k in [0.0, -1, 1] {
            let t = bestTime + k * el.period
            guard t >= earliest else { continue }
            let s = orbit(at: t)
            let dv0 = (vinf * vinf + 2 * terra.mu / s.position.length).squareRoot() - s.velocity.length
            func distance(_ dv: Double) -> Double {
                departureMiss(to: id, state: state, time: time, node: ManeuverNode(time: t, prograde: dv))?.distance
                    ?? .infinity
            }
            let dv = goldenMinimum(lo: max(0, dv0 - 120), hi: dv0 + 120, iterations: 40, distance)
            let d = distance(dv)
            if d < (best?.distance ?? .infinity) { best = (ManeuverNode(time: t, prograde: dv), d) }
        }
        guard let best else { return nil }
        // Встреча уже есть — доводим Пе прогрейдом (как «К Луне»), иначе снимет коррекция в пути.
        return tunePeriapsis(node: best.node, target: id, body: .terra, state: state, time: time) ?? best.node
    }

    /// Сближение с планетой после узла отлёта (без поиска SOI — для подбора): расстояние, м, и время.
    static func departureMiss(to id: BodyID, state: StateVector, time: Double,
                              node: ManeuverNode) -> (distance: Double, time: Double)? {
        let mu = Bodies.terra.mu
        let s = Kepler.propagate(position: state.position, velocity: state.velocity, mu: mu, dt: node.time - time)
        let v = s.velocity + TrajectoryPredictor.deltaVVector(node: node, position: s.position, velocity: s.velocity)
        let after = OrbitElements(position: s.position, velocity: v, mu: mu)
        guard !after.isClosed || after.apoapsisRadius > Bodies.terra.soiRadius,
              let exit = Kepler.timeToRadius(Bodies.terra.soiRadius, position: s.position, velocity: v, mu: mu,
                                             outbound: true) else { return nil }
        let e = Kepler.propagate(position: s.position, velocity: v, mu: mu, dt: exit)
        let helio = World.convert(e, from: .terra, to: .sol, time: node.time + exit)
        return closestApproach(to: id, state: helio, time: node.time + exit)
    }

    /// Ближайшее сближение с планетой на гелиоцентрической дуге из `state` в момент `time`
    /// (двухтельная задача, без SOI) в пределах 1.5 гомановских перелётов.
    static func closestApproach(to id: BodyID, state: StateVector, time: Double,
                                samples: Int = 240) -> (distance: Double, time: Double) {
        let mu = Bodies.sol.mu
        let horizon = 1.5 * hohmannTime(id)
        func distance(_ dt: Double) -> Double {
            let s = Kepler.propagate(position: state.position, velocity: state.velocity, mu: mu, dt: dt)
            return (s.position - World.position(of: id, relativeTo: .sol, at: time + dt)).length
        }
        let h = horizon / Double(samples)
        var bestK = 0, bestD = Double.infinity
        for k in 0...samples {
            let d = distance(Double(k) * h)
            if d < bestD { (bestK, bestD) = (k, d) }
        }
        let dt = goldenMinimum(lo: max(0, Double(bestK - 1) * h), hi: Double(bestK + 1) * h, iterations: 40, distance)
        return (min(bestD, distance(dt)), time + dt)
    }

    // MARK: Коррекция в пути

    /// Гелиоцентрический участок прогноза и сближение на нём. nil — участка нет (ещё не уходим от Терры).
    static func helioApproach(to id: BodyID, trajectory: Trajectory) -> (patch: TrajectoryPatch, distance: Double, time: Double)? {
        guard let patch = trajectory.patches.first(where: { $0.body == .sol }) else { return nil }
        let a = closestApproach(to: id, state: patch.start, time: patch.startTime)
        return (patch, a.distance, a.time)
    }

    /// Оценка коррекции на середине оставшейся дуги, м/с: промах / половина времени до сближения.
    static func correctionEstimate(distance: Double, from start: Double, to arrival: Double) -> Double {
        distance / max(1, 0.5 * (arrival - start))
    }

    /// Коррекция в пути: узел на середине оставшейся гелиоцентрической дуги (не раньше `time + 30`), импульс —
    /// Ньютоном, чтобы к моменту сближения корабль прошёл у планеты с прицельным параметром для Пе ≈ цели.
    /// nil — гелиоцентрического участка нет, сближение слишком близко или коррекция больше `correctionLimit`.
    static func courseCorrection(to id: BodyID, trajectory pre: Trajectory, time: Double) -> ManeuverNode? {
        guard let a = helioApproach(to: id, trajectory: pre) else { return nil }
        let earliest = max(time + ManeuverPlanner.minimumLead, a.patch.startTime + 60)
        guard a.time > earliest + 3_600 else { return nil }
        let tc = max(earliest, 0.5 * (earliest + a.time))
        // Узел должен лежать на этом участке: иначе Δv посчитают от другого состояния.
        guard tc < a.patch.endTime else { return nil }
        let mu = Bodies.sol.mu
        let sc = a.patch.state(at: tc)
        let planet = Bodies.body(id)
        // Прицел: смещение от центра планеты поперёк относительной скорости, чтобы облёт шёл по ходу (h_z > 0).
        let arrival = Kepler.propagate(position: sc.position, velocity: sc.velocity, mu: mu, dt: a.time - tc)
        let vRel = arrival.velocity - World.velocity(of: id, relativeTo: .sol, at: a.time)
        let vinf = max(vRel.length, 1)
        let rp = planet.radius + targetPeriapsis(id)
        let b = rp * (1 + 2 * planet.mu / (rp * vinf * vinf)).squareRoot()
        var side = vRel.normalized.cross(.unitZ)
        if side.lengthSquared < 1e-12 { side = .unitX }
        let aim = World.position(of: id, relativeTo: .sol, at: a.time) + side.normalized * b
        func miss(_ dv: Vec3) -> Vec3 {
            Kepler.propagate(position: sc.position, velocity: sc.velocity + dv, mu: mu, dt: a.time - tc).position - aim
        }
        var dv = Vec3.zero
        for _ in 0..<12 {
            let f = miss(dv)
            if f.length < 500 { break }
            let h = 0.5
            let jx = (miss(dv + Vec3(h, 0, 0)) - f) / h
            let jy = (miss(dv + Vec3(0, h, 0)) - f) / h
            let jz = (miss(dv + Vec3(0, 0, h)) - f) / h
            guard let step = solve3(jx, jy, jz, -f) else { return nil }
            dv += step
            guard dv.length.isFinite, dv.length < 2 * correctionLimit else { return nil }
        }
        // Пустая коррекция (< 0.5 м/с) автопрожиг закроет сразу — не ставим.
        guard dv.length >= 0.5, dv.length <= correctionLimit,
              miss(dv).length < 0.05 * planet.soiRadius else { return nil }
        let basis = TrajectoryPredictor.maneuverBasis(position: sc.position, velocity: sc.velocity)
        return ManeuverNode(time: tc, prograde: dv.dot(basis.prograde), normal: dv.dot(basis.normal),
                            radial: dv.dot(basis.radial))
    }

    // MARK: Подбор Пе

    /// Пе со знаком у тела `target` по прогнозу: «+» — облёт по ходу (h_z ≥ 0), «−» — против.
    static func signedPeriapsis(_ traj: Trajectory, target: BodyID) -> Double? {
        for p in traj.patches where p.body == target {
            let sign: Double = p.elements.angularMomentum.z >= 0 ? 1 : -1
            return sign * p.elements.periapsisRadius
        }
        return nil
    }

    /// Прогрейд узла подобран секущими так, чтобы Пе у планеты по прогнозу карты был ≈ цели. nil — встречи нет
    /// или подбор не попал в годный диапазон.
    static func tunePeriapsis(node: ManeuverNode, target id: BodyID, body: BodyID, state: StateVector,
                              time: Double, maxIterations: Int = 14) -> ManeuverNode? {
        let patches = TrajectoryPredictor.defaultMapPatches
        let pre = TrajectoryPredictor.predict(body: body, state: state, time: time, maxPatches: patches)
        let goal = Bodies.body(id).radius + targetPeriapsis(id)
        func value(_ dv: Double) -> Double? {
            var n = node
            n.prograde = dv
            guard let p = TrajectoryPredictor.predict(node: n, body: body, state: state, time: time, mass: 1,
                                                      thrust: 0, isp: 1, maxPatches: patches, preTrajectory: pre),
                  let pe = signedPeriapsis(p.trajectory, target: id) else { return nil }
            return pe
        }
        guard let v0 = value(node.prograde) else { return nil }
        let goalValue = v0 >= 0 ? goal : -goal
        var x0 = node.prograde, f0 = v0 - goalValue
        var best = (dv: x0, error: abs(f0))
        var x1 = x0 + 0.05
        var calls = 1
        while calls < maxIterations, best.error > 2_000 {
            calls += 1
            guard let v = value(x1) else { x1 = 0.5 * (x0 + x1); continue }
            let f1 = v - goalValue
            if abs(f1) < best.error { best = (x1, abs(f1)) }
            guard f1 != f0 else { break }
            let step = max(-2, min(2, -f1 * (x1 - x0) / (f1 - f0)))
            (x0, f0) = (x1, f1)
            x1 += step
        }
        let range = goodPeriapsis(id)
        guard best.error <= targetPeriapsis(id) - range.lowerBound else { return nil }
        var out = node
        out.prograde = best.dv
        return out
    }

    // MARK: Числа

    /// Минимум унимодальной функции на [lo, hi] золотым сечением.
    static func goldenMinimum(lo: Double, hi: Double, iterations: Int, _ f: (Double) -> Double) -> Double {
        var a = lo, b = hi
        let g = 0.5 * (5.0.squareRoot() - 1)
        var c = b - g * (b - a), d = a + g * (b - a)
        var fc = f(c), fd = f(d)
        for _ in 0..<iterations {
            if fc < fd {
                b = d; d = c; fd = fc; c = b - g * (b - a); fc = f(c)
            } else {
                a = c; c = d; fc = fd; d = a + g * (b - a); fd = f(d)
            }
        }
        return 0.5 * (a + b)
    }

    /// Решение 3×3 `[cx cy cz]·x = rhs` (Крамер). nil — вырождена.
    static func solve3(_ cx: Vec3, _ cy: Vec3, _ cz: Vec3, _ rhs: Vec3) -> Vec3? {
        let det = cx.dot(cy.cross(cz))
        guard abs(det) > 1e-30, det.isFinite else { return nil }
        return Vec3(rhs.dot(cy.cross(cz)) / det, cx.dot(rhs.cross(cz)) / det, cx.dot(cy.cross(rhs)) / det)
    }

    /// Поворот вектора вокруг единичной оси (формула Родрига).
    static func rotate(_ v: Vec3, about k: Vec3, by angle: Double) -> Vec3 {
        let c = cos(angle), s = sin(angle)
        return v * c + k.cross(v) * s + k * (k.dot(v) * (1 - c))
    }
}
