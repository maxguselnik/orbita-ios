import Foundation

/// Цель простой карты: игрок выбирает «куда летим», планировщик ставит узел.
public enum ManeuverGoal: String, CaseIterable, Sendable, Hashable, Codable {
    case toLuna
    case circularize
    case changeOrbit
    case returnHome
}

/// Итог манёвра по прогнозу после узла.
public struct ManeuverOutcome: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Встреча с Луной, высота Пе над уровнем моря, м.
        case lunaPeriapsis(Double)
        /// Возврат к Терре, высота Пе над уровнем моря, м.
        case terraPeriapsis(Double)
        /// Орбита после узла: высоты Ап (∞ — незамкнутая или за SOI) и Пе, м.
        case orbit(body: BodyID, apoapsis: Double, periapsis: Double)
        /// Нужной встречи нет.
        case noEncounter(BodyID)
        /// Падение на тело.
        case impact(BodyID)
    }

    public var kind: Kind
    public var isGood: Bool

    public init(kind: Kind, isGood: Bool) {
        self.kind = kind
        self.isGood = isGood
    }
}

/// Планировщик манёвров по цели (простая карта).
public enum ManeuverPlanner {
    /// Узел не раньше чем через столько секунд — игроку нужно время развернуться.
    static let minimumLead = 30.0
    /// Целевая высота Пе у Терры при возврате с Луны, м.
    static let returnPeriapsis = 35_000.0

    // MARK: Доступные цели

    /// Цели, доступные сейчас, в порядке кнопок. Без прогнозов — только элементы орбиты.
    public static func availableGoals(body: BodyID, state: StateVector, time: Double) -> [ManeuverGoal] {
        let b = Bodies.body(body)
        let el = OrbitElements(position: state.position, velocity: state.velocity, mu: b.mu)
        guard el.eccentricity.isFinite, el.periapsisRadius.isFinite else { return [] }
        let peAlt = el.periapsisRadius - b.radius
        let rails = World.railsMinimumAltitude(body)
        let outbound = state.position.dot(state.velocity) > 0
        switch body {
        case .terra:
            // Апоцентр за SOI — уже уход к Сол (`classify` → `.escaping`), узлы там не строим.
            guard el.isClosed, el.apoapsisRadius < b.soiRadius else { return [] }
            let apAlt = el.apoapsisRadius - b.radius
            if peAlt > b.atmosphereHeight {
                var goals: [ManeuverGoal] = []
                if el.apoapsisRadius < 0.5 * Bodies.luna.orbitRadius { goals.append(.toLuna) }
                if el.eccentricity > 0.01 { goals.append(.circularize) }
                goals.append(.changeOrbit)
                return goals
            }
            // Суборбита: Ап над атмосферой и ещё впереди.
            return apAlt > b.atmosphereHeight && outbound ? [.circularize] : []
        case .luna:
            if !el.isClosed || el.apoapsisRadius > b.soiRadius {
                // Пролёт: захват у Пе, если Пе впереди и над грунтом.
                return peAlt > rails && !outbound ? [.circularize] : []
            }
            guard peAlt > rails else { return [] }
            var goals: [ManeuverGoal] = [.returnHome]
            if el.eccentricity > 0.01 { goals.append(.circularize) }
            goals.append(.changeOrbit)
            return goals
        default:
            if !el.isClosed || el.apoapsisRadius > b.soiRadius {
                return peAlt > rails && !outbound ? [.circularize] : []
            }
            guard peAlt > rails else { return [] }
            return el.eccentricity > 0.01 ? [.circularize, .changeOrbit] : [.changeOrbit]
        }
    }

    // MARK: План

    /// Узел для цели. nil — цель сейчас невыполнима. Время узла ≥ `time + 30`.
    public static func plan(_ goal: ManeuverGoal, body: BodyID, state: StateVector, time: Double) -> ManeuverNode? {
        switch goal {
        case .toLuna: lunaTransfer(body: body, state: state, time: time)
        case .circularize: circularize(body: body, state: state, time: time)
        case .changeOrbit: changeOrbit(body: body, state: state, time: time)
        case .returnHome: returnHome(body: body, state: state, time: time)?.node
        }
    }

    /// Шаг кнопок «−/+», м/с: перелёты чувствительны — 0.1, прочее — 1.
    public static func fineStep(_ goal: ManeuverGoal?) -> Double {
        switch goal {
        case .toLuna, .returnHome: 0.1
        case .circularize, .changeOrbit, nil: 1
        }
    }

    // MARK: Итог

    /// Итог по прогнозу после узла (первый участок начинается в момент узла).
    public static func outcome(_ goal: ManeuverGoal?, trajectory: Trajectory) -> ManeuverOutcome {
        guard let first = trajectory.patches.first else {
            return ManeuverOutcome(kind: .noEncounter(goal == .toLuna ? .luna : .terra), isGood: false)
        }
        switch goal {
        case .toLuna:
            if let enc = trajectory.encounter, enc.body == .luna {
                if let hit = trajectory.impact, hit.body == .luna {
                    return ManeuverOutcome(kind: .impact(.luna), isGood: false)
                }
                return ManeuverOutcome(kind: .lunaPeriapsis(enc.periapsisAltitude),
                                       isGood: (15_000...60_000).contains(enc.periapsisAltitude))
            }
            if let hit = trajectory.impact { return ManeuverOutcome(kind: .impact(hit.body), isGood: false) }
            return ManeuverOutcome(kind: .noEncounter(.luna), isGood: false)
        case .returnHome:
            // Уже у Терры (после выхода из SOI Луны): Пе текущего участка.
            if first.body == .terra {
                let pe = first.elements.periapsisRadius - Bodies.terra.radius
                return ManeuverOutcome(kind: .terraPeriapsis(pe), isGood: (20_000...50_000).contains(pe))
            }
            if let ret = trajectory.returnToTerra, ret.body == .terra {
                return ManeuverOutcome(kind: .terraPeriapsis(ret.periapsisAltitude),
                                       isGood: (20_000...50_000).contains(ret.periapsisAltitude))
            }
            if let hit = trajectory.impact { return ManeuverOutcome(kind: .impact(hit.body), isGood: false) }
            return ManeuverOutcome(kind: .noEncounter(.terra), isGood: false)
        case .circularize, .changeOrbit, nil:
            if let hit = trajectory.impact { return ManeuverOutcome(kind: .impact(hit.body), isGood: false) }
            let b = Bodies.body(first.body)
            let el = first.elements
            let ap = el.isClosed && el.apoapsisRadius <= b.soiRadius ? el.apoapsisRadius - b.radius : .infinity
            let pe = el.periapsisRadius - b.radius
            let good: Bool
            if goal == .circularize {
                good = el.eccentricity < 0.02
            } else {
                good = pe > World.railsMinimumAltitude(first.body)
            }
            return ManeuverOutcome(kind: .orbit(body: first.body, apoapsis: ap, periapsis: pe), isGood: good)
        }
    }

    // MARK: Коррекция

    /// Коррекция после неточного прожига перелёта: узел в `time + 60`, импульс (прогрейд, при необходимости
    /// радиальный) — до середины годного диапазона (Пе у Луны 30 км / у Терры 35 км).
    /// nil — итог уже годен, цель не перелётная или подобрать нельзя (|Δv| ≤ 100 м/с).
    public static func correction(_ goal: ManeuverGoal, body: BodyID, state: StateVector, time: Double) -> ManeuverNode? {
        correctionSearch(goal, body: body, state: state, time: time)?.node
    }

    /// Предел Δv коррекции, м/с.
    static let correctionLimit = 100.0

    /// Коррекция и число вызовов `predict`.
    static func correctionSearch(_ goal: ManeuverGoal, body: BodyID, state: StateVector,
                                 time: Double) -> (node: ManeuverNode, predictions: Int)? {
        // Тело, у которого меряем Пе, и цель (радиус Пе), м.
        let target: CelestialBody
        let targetAltitude: Double
        switch (goal, body) {
        case (.toLuna, .terra): (target, targetAltitude) = (Bodies.luna, 30_000)
        case (.returnHome, .luna), (.returnHome, .terra): (target, targetAltitude) = (Bodies.terra, returnPeriapsis)
        default: return nil
        }
        let patches = TrajectoryPredictor.defaultMapPatches
        let pre = TrajectoryPredictor.predict(body: body, state: state, time: time, maxPatches: patches)
        var predictions = 1
        if outcome(goal, trajectory: pre).isGood { return nil }

        /// Пе со знаком: «+» — облёт по ходу движения Луны (h_z ≥ 0), «−» — против.
        /// Через нулевой прицельный параметр меняется плавно — секущие не застревают у дна «V».
        func signedPeriapsis(_ traj: Trajectory) -> Double? {
            for p in traj.patches where p.body == target.id {
                let sign: Double = p.elements.angularMomentum.z >= 0 ? 1 : -1
                return sign * p.elements.periapsisRadius
            }
            return nil
        }
        let nodeTime = time + 60
        func evaluate(_ node: ManeuverNode) -> Double? {
            predictions += 1
            guard let p = TrajectoryPredictor.predict(node: node, body: body, state: state, time: time,
                                                      mass: 1, thrust: 0, isp: 1, maxPatches: patches,
                                                      preTrajectory: pre) else { return nil }
            return signedPeriapsis(p.trajectory)
        }
        let targetRadius = target.radius + targetAltitude
        /// Секущие по одной оси (прогрейд или радиальный).
        func solve(_ make: (Double) -> ManeuverNode) -> ManeuverNode? {
            // Начало: без импульса; встречи нет — пробуем импульсы по нарастающей.
            var start: (x: Double, value: Double)?
            for x in [0.0, 1, -1, 3, -3, 10, -10, 30, -30, 100, -100] {
                if let v = evaluate(make(x)) { start = (x, v); break }
            }
            guard let start else { return nil }
            // Цель — тот облёт (по ходу или против), что ближе.
            let goalValue = start.value >= 0 ? targetRadius : -targetRadius
            var x0 = start.x, f0 = start.value - goalValue
            var best = (x: x0, error: abs(f0))
            var x1 = x0 + 0.5
            var calls = 0
            while calls < 16, best.error > 1_000 {
                calls += 1
                guard let v = evaluate(make(x1)) else { x1 = 0.5 * (x0 + x1); continue }
                let f1 = v - goalValue
                if abs(f1) < best.error { best = (x1, abs(f1)) }
                guard f1 != f0 else { break }
                let step = max(-10, min(10, -f1 * (x1 - x0) / (f1 - f0)))
                (x0, f0) = (x1, f1)
                x1 = max(-correctionLimit, min(correctionLimit, x1 + step))
            }
            let node = make(best.x)
            predictions += 1
            guard best.error < 10_000, node.deltaV > 0,
                  let p = TrajectoryPredictor.predict(node: node, body: body, state: state, time: time,
                                                      mass: 1, thrust: 0, isp: 1, maxPatches: patches,
                                                      preTrajectory: pre),
                  outcome(goal, trajectory: p.trajectory).isGood else { return nil }
            return node
        }
        if let n = solve({ ManeuverNode(time: nodeTime, prograde: $0) }) { return (n, predictions) }
        if let n = solve({ ManeuverNode(time: nodeTime, radial: $0) }) { return (n, predictions) }
        return nil
    }

    // MARK: К Луне

    /// Гомановская фаза в пределах двух оборотов, затем прогрейд до Пе у Луны ≈ 30 км.
    /// Подбор не попал — гомановский узел как есть (итог покажет «нет встречи»).
    static func lunaTransfer(body: BodyID, state: StateVector, time: Double) -> ManeuverNode? {
        guard body == .terra else { return nil }
        let mu = Bodies.terra.mu
        let el = OrbitElements(position: state.position, velocity: state.velocity, mu: mu)
        guard el.isClosed, el.periapsisRadius > Bodies.terra.radius else { return nil }
        let target = TrajectoryPredictor.hohmannLunaPhase(radius: state.position.length)
        // Фаза за оборот корабля меняется на ~2π; ищем первое приближение к нужной в пределах двух оборотов.
        let horizon = el.period.isFinite ? 2 * el.period : 20_000
        var best = (dt: 60.0, error: Double.infinity)
        var dt = 60.0
        while dt < horizon {
            let s = Kepler.propagate(position: state.position, velocity: state.velocity, mu: mu, dt: dt)
            let phase = TrajectoryPredictor.lunaPhase(position: s.position, velocity: s.velocity, time: time + dt)
            let error = abs(remainder(phase - target, 2 * Double.pi))
            if error < best.error { best = (dt, error) }
            if error < 0.01 { break }
            dt += 5
        }
        let hohmann = ManeuverNode(time: time + best.dt,
                                   prograde: TrajectoryPredictor.hohmannLunaDeltaV(radius: state.position.length))
        // Гоман целит почти в центр Луны: доводим прогрейд до Пе у Луны ≈ 30 км.
        return TrajectoryPredictor.tuneLunaPeriapsis(node: hohmann, body: body, state: state, time: time) ?? hohmann
    }

    // MARK: Круговая

    /// Ближайший апсис (суборбита — Ап, пролёт/незамкнутая — Пе) и импульс до круговой скорости.
    /// Если апсис ближе 30 с, узел через 30 с, и импульс — точный вектор до круговой (с радиальной частью).
    static func circularize(body: BodyID, state: StateVector, time: Double) -> ManeuverNode? {
        let b = Bodies.body(body)
        let el = OrbitElements(position: state.position, velocity: state.velocity, mu: b.mu)
        let rails = World.railsMinimumAltitude(body)
        let outbound = state.position.dot(state.velocity) > 0
        let dt: Double
        if el.isClosed && el.apoapsisRadius <= b.soiRadius {
            if el.periapsisRadius - b.radius > rails {
                // Орбита: ближайший апсис не раньше чем через 30 с.
                let candidates = [el.timeToApoapsis, el.timeToPeriapsis].compactMap { $0 }
                    .map { $0 >= minimumLead ? $0 : $0 + el.period }
                guard let m = candidates.min() else { return nil }
                dt = m
            } else {
                // Суборбита: у Ап, пока он впереди.
                guard outbound, let ta = el.timeToApoapsis else { return nil }
                dt = max(ta, minimumLead)
            }
        } else {
            // Незамкнутая (или Ап за SOI): захват у Пе, пока он впереди.
            guard !outbound, let tp = el.timeToPeriapsis else { return nil }
            dt = max(tp, minimumLead)
        }
        let s = Kepler.propagate(position: state.position, velocity: state.velocity, mu: b.mu, dt: dt)
        let r = s.position.length
        guard r - b.radius > rails, r < b.soiRadius else { return nil }
        // Круговая скорость — по горизонтали в плоскости орбиты.
        let h = s.position.cross(s.velocity)
        guard h.lengthSquared > 0 else { return nil }
        let horizontal = h.cross(s.position).normalized
        let dv = horizontal * (b.mu / r).squareRoot() - s.velocity
        let basis = TrajectoryPredictor.maneuverBasis(position: s.position, velocity: s.velocity)
        var radial = dv.dot(basis.radial)
        // В апсисе радиальная часть — шум округления.
        if abs(radial) < 1e-3 { radial = 0 }
        return ManeuverNode(time: time + dt, prograde: dv.dot(basis.prograde), radial: radial)
    }

    // MARK: Сменить орбиту

    /// Ближайший Пе (не раньше чем через 30 с), прогрейд +20 м/с — отправная точка для «−/+».
    static func changeOrbit(body: BodyID, state: StateVector, time: Double) -> ManeuverNode? {
        let b = Bodies.body(body)
        let el = OrbitElements(position: state.position, velocity: state.velocity, mu: b.mu)
        guard el.isClosed, let tp = el.timeToPeriapsis else { return nil }
        let dt = tp >= minimumLead ? tp : tp + el.period
        return ManeuverNode(time: time + dt, prograde: 20)
    }

    // MARK: Домой

    /// Высота Пе у Терры после выхода из SOI Луны для прогрейд-импульса `dv` в момент `t` — аналитически,
    /// той же моделью патченных коник, что и прогноз (без пошагового поиска). nil — не уходит из SOI.
    static func terraPeriapsisAfterEscape(state: StateVector, time: Double, nodeTime t: Double, dv: Double) -> Double? {
        let luna = Bodies.luna
        let s = Kepler.propagate(position: state.position, velocity: state.velocity, mu: luna.mu, dt: t - time)
        let v = s.velocity + s.velocity.normalized * dv
        let post = OrbitElements(position: s.position, velocity: v, mu: luna.mu)
        guard !post.isClosed || post.apoapsisRadius > luna.soiRadius else { return nil }
        if s.position.dot(v) < 0 && post.periapsisRadius < luna.radius { return nil }
        guard let exitDt = Kepler.timeToRadius(luna.soiRadius, position: s.position, velocity: v,
                                               mu: luna.mu, outbound: true) else { return nil }
        let exit = Kepler.propagate(position: s.position, velocity: v, mu: luna.mu, dt: exitDt)
        let terra = World.convert(exit, from: .luna, to: .terra, time: t + exitDt)
        let el = OrbitElements(position: terra.position, velocity: terra.velocity, mu: Bodies.terra.mu)
        return el.periapsisRadius - Bodies.terra.radius
    }

    /// Возврат с орбиты Луны: момент (в пределах оборота) и прогрейд, при которых Пе у Терры ≈ 35 км.
    /// Сначала аналитически (перебор моментов, золотое сечение, секущие по Δv), затем уточнение
    /// прогнозом карты (секущие). `predictions` — сколько раз вызван `predict`.
    static func returnHome(body: BodyID, state: StateVector, time: Double) -> (node: ManeuverNode, predictions: Int)? {
        guard body == .luna else { return nil }
        let luna = Bodies.luna, terraMu = Bodies.terra.mu
        let el = OrbitElements(position: state.position, velocity: state.velocity, mu: luna.mu)
        guard el.isClosed, el.apoapsisRadius < luna.soiRadius,
              el.periapsisRadius - luna.radius > World.railsMinimumAltitude(.luna) else { return nil }
        let target = returnPeriapsis
        // Гомановский возврат: скорость ухода от Луны против её движения.
        let rl = luna.orbitRadius, rp = Bodies.terra.radius + target
        let vinf = (terraMu / rl).squareRoot() - (terraMu * (2 / rl - 2 / (rl + rp))).squareRoot()
        func pe(_ t: Double, _ dv: Double) -> Double? {
            terraPeriapsisAfterEscape(state: state, time: time, nodeTime: t, dv: dv)
        }
        func escapeDeltaV(_ t: Double) -> Double {
            let s = Kepler.propagate(position: state.position, velocity: state.velocity, mu: luna.mu, dt: t - time)
            return (vinf * vinf + 2 * luna.mu / s.position.length).squareRoot() - s.velocity.length
        }
        let t0 = time + minimumLead
        let period = el.period
        // 1. Грубый перебор моментов: самый низкий Пе у Терры при гомановском импульсе.
        let samples = 96
        var bestT = t0, bestPe = Double.infinity
        for k in 0..<samples {
            let t = t0 + period * Double(k) / Double(samples)
            if let p = pe(t, escapeDeltaV(t)), p < bestPe { (bestT, bestPe) = (t, p) }
        }
        guard bestPe.isFinite else { return nil }
        // 2. Минимум по времени (золотое сечение) при заданном Δv.
        func refineTime(around t: Double, dv: Double) -> Double {
            var a = t - period / Double(samples), b = t + period / Double(samples)
            let g = 0.5 * (5.0.squareRoot() - 1)
            func f(_ x: Double) -> Double { pe(x, dv) ?? .infinity }
            var c = b - g * (b - a), d = a + g * (b - a)
            var fc = f(c), fd = f(d)
            for _ in 0..<40 {
                if fc < fd { b = d; d = c; fd = fc; c = b - g * (b - a); fc = f(c) } else { a = c; c = d; fc = fd; d = a + g * (b - a); fd = f(d) }
            }
            var out = 0.5 * (a + b)
            // Окно могло уйти раньше t0: оборот позже — то же место орбиты.
            if out < t0 { out += period }
            return out
        }
        // 3. Секущие по Δv до Пе = цель при заданном моменте.
        func solveDeltaV(from start: Double, tolerance: Double, maxCalls: Int,
                         evaluate: (Double) -> Double?) -> (dv: Double, error: Double)? {
            guard var f0 = evaluate(start).map({ $0 - target }) else { return nil }
            var x0 = start
            var best = (dv: x0, error: abs(f0))
            var x1 = x0 + (f0 > 0 ? 1 : -1)
            var calls = 1
            while calls < maxCalls, best.error > tolerance {
                calls += 1
                guard let v = evaluate(x1) else { x1 = 0.5 * (x0 + x1); continue }
                let f1 = v - target
                if abs(f1) < best.error { best = (x1, abs(f1)) }
                guard f1 != f0 else { break }
                let step = max(-50, min(50, -f1 * (x1 - x0) / (f1 - f0)))
                (x0, f0) = (x1, f1)
                x1 += step
            }
            return best
        }
        var t = refineTime(around: bestT, dv: escapeDeltaV(bestT))
        var dv = escapeDeltaV(t)
        for _ in 0..<2 {
            guard let s = solveDeltaV(from: dv, tolerance: 50, maxCalls: 30, evaluate: { pe(t, $0) }) else { return nil }
            dv = s.dv
            t = refineTime(around: t, dv: dv)
        }
        guard let analytic = solveDeltaV(from: dv, tolerance: 50, maxCalls: 30, evaluate: { pe(t, $0) }) else { return nil }
        dv = analytic.dv
        // 4. Уточнение прогнозом карты (как увидит игрок).
        let pre = TrajectoryPredictor.predict(body: body, state: state, time: time,
                                              maxPatches: TrajectoryPredictor.defaultMapPatches)
        var predictions = 1
        let nodeTime = t
        func predicted(_ x: Double) -> Double? {
            predictions += 1
            let node = ManeuverNode(time: nodeTime, prograde: x)
            guard let p = TrajectoryPredictor.predict(node: node, body: body, state: state, time: time,
                                                      mass: 1, thrust: 0, isp: 1,
                                                      maxPatches: TrajectoryPredictor.defaultMapPatches,
                                                      preTrajectory: pre),
                  let ret = p.trajectory.returnToTerra, ret.body == .terra else { return nil }
            return ret.periapsisAltitude
        }
        guard let tuned = solveDeltaV(from: dv, tolerance: 1_000, maxCalls: 12, evaluate: predicted),
              tuned.error <= 15_000 else { return nil }
        return (ManeuverNode(time: nodeTime, prograde: tuned.dv), predictions)
    }
}
