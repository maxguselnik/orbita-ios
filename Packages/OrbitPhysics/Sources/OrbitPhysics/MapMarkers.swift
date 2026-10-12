import Foundation

/// Отметки карты для траектории (поток A).
///
/// Правила:
/// - Пе — если момент перицентра попадает в участок [startTime, endTime]; у замкнутой орбиты
///   без конца участка — ближайший в будущем (в пределах одного оборота).
/// - Ап — только у замкнутых орбит, по тому же правилу.
/// - Почти круговая орбита (e < `circularEccentricity`): Ап и Пе не ставятся — их положение
///   не определено и прыгало бы по орбите от кадра к кадру.
/// - AN/DN — пересечение плоскости XY системы тела (z = 0) вверх/вниз, в пределах участка
///   (у замкнутой орбиты без конца — ближайшие в одном обороте). Почти экваториальная орбита
///   (наклонение < `equatorialInclination` или > π − его) — без узлов.
/// - Вход/выход SOI и падение — в конце участка по `PatchEnd`. `soiEnter(b)` — вход в SOI тела `b`,
///   `soiExit(b)` — выход из SOI тела `b` (тела участка, т. е. того, которое покидаем).
/// - Почти параболические участки (|e − 1| < 1e-6): Ап/Пе/AN/DN не ставятся.
/// Позиции — в инерциальной системе тела участка в момент `time`; высота — над уровнем моря этого тела.
public enum MapMarkers {
    /// Порог почти круговой орбиты.
    public static let circularEccentricity = 1e-4
    /// Порог почти экваториальной орбиты, рад (0.1°).
    public static let equatorialInclination = 0.1 * Double.pi / 180

    /// Ап/Пе (в пределах участка; у незамкнутых — только Пе), AN/DN относительно плоскости XY Терры,
    /// вход/выход SOI, падение — по каждому участку `trajectory`. Отметку `.maneuver` ставит вызывающий.
    public static func compute(_ trajectory: Trajectory, afterManeuver: Bool) -> [MapMarker] {
        var out: [MapMarker] = []
        for (i, patch) in trajectory.patches.enumerated() {
            out += markers(patch, index: i, afterManeuver: afterManeuver)
        }
        return out
    }

    static func markers(_ patch: TrajectoryPatch, index: Int, afterManeuver: Bool) -> [MapMarker] {
        let body = Bodies.body(patch.body)
        let el = patch.elements
        let r0 = patch.start.position, v0 = patch.start.velocity
        guard r0.lengthSquared > 0, r0.x.isFinite, v0.x.isFinite, el.eccentricity.isFinite else { return [] }
        let e = el.eccentricity
        // Окно участка: до конца, у замкнутой орбиты без конца — один оборот.
        var span = patch.endTime - patch.startTime
        if !span.isFinite { span = el.isClosed ? el.period : .infinity }
        guard span >= 0 else { return [] }

        var out: [MapMarker] = []
        func add(_ kind: MapMarker.Kind, dt: Double) {
            guard dt.isFinite, dt >= 0, dt <= span + 1e-6 else { return }
            let t = patch.startTime + min(dt, span)
            let p = patch.state(at: t).position
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return }
            out.append(MapMarker(kind: kind, body: patch.body, position: p, time: t,
                                 altitude: p.length - body.radius, patchIndex: index, afterManeuver: afterManeuver))
        }

        let parabolic = abs(e - 1) < 1e-6
        // Время от начала участка до истинной аномалии `nu` (ближайшее в будущем), nil — недостижимо.
        let timing = AnomalyTiming(elements: el, position: r0, velocity: v0)

        if !parabolic && e >= circularEccentricity {
            if let dt = timing?.time(toTrueAnomaly: 0) { add(.periapsis, dt: dt) }
            if el.isClosed, let dt = timing?.time(toTrueAnomaly: .pi) { add(.apoapsis, dt: dt) }
        }

        let inc = el.inclination
        if !parabolic && inc > equatorialInclination && inc < .pi - equatorialInclination {
            // Аргумент широты u: угол от восходящего узла до точки по направлению движения.
            let h = el.angularMomentum
            let nodeLine = Vec3.unitZ.cross(h)
            if nodeLine.lengthSquared > 0, h.lengthSquared > 0 {
                let nHat = nodeLine.normalized
                let hHat = h.normalized
                let u0 = atan2(nHat.cross(r0).dot(hHat), nHat.dot(r0))
                for (kind, u) in [(MapMarker.Kind.ascendingNode, 0.0), (.descendingNode, Double.pi)] {
                    let du = wrap2Pi(u - u0)
                    let dt: Double?
                    if e < circularEccentricity {
                        // Почти круговая: равномерное движение.
                        dt = el.isClosed ? du / (2 * .pi) * el.period : nil
                    } else {
                        dt = timing?.time(toTrueAnomaly: el.trueAnomaly + du)
                    }
                    if let dt { add(kind, dt: dt) }
                }
            }
        }

        let endT = patch.endTime
        if endT.isFinite {
            let kind: MapMarker.Kind?
            switch patch.end {
            case .none: kind = nil
            case .impact: kind = .impact
            case .enterSOI(let b): kind = .soiEnter(b)
            case .exitSOI: kind = .soiExit(patch.body)
            }
            if let kind { add(kind, dt: endT - patch.startTime) }
        }
        out.sort { $0.time < $1.time }
        return out
    }
}

/// Перевод истинной аномалии во время для эллипса и гиперболы.
struct AnomalyTiming {
    let e: Double
    let closed: Bool
    /// Среднее движение, рад/с.
    let n: Double
    /// Средняя аномалия в начале.
    let m0: Double

    init?(elements el: OrbitElements, position r0: Vec3, velocity v0: Vec3) {
        e = el.eccentricity
        closed = el.isClosed
        let a = el.semiMajorAxis
        guard a.isFinite, a != 0, e > 1e-12 else { return nil }
        n = (el.mu / abs(a * a * a)).squareRoot()
        guard let m = Self.meanAnomaly(el.trueAnomaly, e: e, closed: closed) else { return nil }
        m0 = m
        guard n.isFinite, n > 0, m0.isFinite else { return nil }
    }

    static func meanAnomaly(_ nu: Double, e: Double, closed: Bool) -> Double? {
        if closed {
            let ea = 2 * atan(((1 - e) / (1 + e)).squareRoot() * tan(wrapPi(nu) / 2))
            return ea - e * sin(ea)
        }
        let nuS = wrapPi(nu)
        // За асимптотой точка недостижима.
        guard abs(nuS) < acos(-1 / e) - 1e-9 else { return nil }
        let ff = 2 * atanh(((e - 1) / (e + 1)).squareRoot() * tan(nuS / 2))
        let m = e * sinh(ff) - ff
        return m.isFinite ? m : nil
    }

    /// Ближайшее время ≥ 0 до истинной аномалии `nu`, nil — недостижимо.
    func time(toTrueAnomaly nu: Double) -> Double? {
        guard let m = Self.meanAnomaly(nu, e: e, closed: closed) else { return nil }
        if closed {
            var dm = wrap2Pi(m - m0)
            // Точка только что пройдена (погрешность округления) — считается текущей.
            if dm > 2 * .pi - 1e-7 { dm = 0 }
            return dm / n
        }
        let dt = (m - m0) / n
        return dt >= -1e-9 ? max(0, dt) : nil
    }
}
