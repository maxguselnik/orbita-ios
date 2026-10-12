import Foundation

/// Состояние в инерциальной системе тела: положение и скорость.
public struct StateVector: Sendable, Hashable {
    public var position: Vec3
    public var velocity: Vec3
    public init(position: Vec3, velocity: Vec3) {
        self.position = position
        self.velocity = velocity
    }
}

/// Задача двух тел: пропагатор Кеплера в универсальных переменных и RK4 для проверки.
public enum Kepler {
    // MARK: Функции Штумпфа

    /// C(z) = (1 − cos√z)/z, с рядом вблизи нуля.
    static func stumpffC(_ z: Double) -> Double {
        if abs(z) < 1 {
            // Σ (−z)^k / (2k+2)!
            var term = 0.5, sum = 0.5
            for k in 1..<14 {
                term *= -z / Double((2 * k + 1) * (2 * k + 2))
                sum += term
            }
            return sum
        }
        if z > 0 {
            let s = z.squareRoot()
            let h = sin(s / 2)
            return 2 * h * h / z
        }
        let s = (-z).squareRoot()
        return (cosh(s) - 1) / (-z)
    }

    /// S(z) = (√z − sin√z)/√z³, с рядом вблизи нуля.
    static func stumpffS(_ z: Double) -> Double {
        if abs(z) < 1 {
            // Σ (−z)^k / (2k+3)!
            var term = 1.0 / 6, sum = 1.0 / 6
            for k in 1..<14 {
                term *= -z / Double((2 * k + 2) * (2 * k + 3))
                sum += term
            }
            return sum
        }
        if z > 0 {
            let s = z.squareRoot()
            return (s - sin(s)) / (s * s * s)
        }
        let s = (-z).squareRoot()
        return (sinh(s) - s) / (s * s * s)
    }

    // MARK: Пропагатор

    /// Положение и скорость через `dt` секунд (dt может быть отрицательным).
    /// Работает для эллипса, параболы и гиперболы.
    public static func propagate(position r0: Vec3, velocity v0: Vec3, mu: Double, dt: Double) -> StateVector {
        if dt == 0 { return StateVector(position: r0, velocity: v0) }
        let r0m = r0.length
        let v02 = v0.lengthSquared
        let sqmu = mu.squareRoot()
        let rv = r0.dot(v0)
        let alpha = 2 / r0m - v02 / mu
        var t = dt
        var xPeriod = Double.infinity
        if alpha * r0m > 1e-12 {
            let period = 2 * Double.pi / (sqmu * pow(alpha, 1.5))
            t = t.truncatingRemainder(dividingBy: period)
            if t < 0 { t += period }
            xPeriod = 2 * Double.pi / alpha.squareRoot()
        }
        let a1 = rv / sqmu
        let a2 = 1 - alpha * r0m
        func F(_ x: Double) -> (f: Double, df: Double, c: Double, s: Double) {
            let x2 = x * x, z = alpha * x2
            let c = stumpffC(z), s = stumpffS(z)
            let f = a1 * x2 * c + a2 * x2 * x * s + r0m * x - sqmu * t
            let df = a1 * x * (1 - z * s) + a2 * x2 * c + r0m
            return (f, df, c, s)
        }
        // F монотонно возрастает (dF/dx = r > 0): Ньютон внутри брекета.
        var lo: Double, hi: Double
        if xPeriod.isFinite {
            lo = 0
            hi = xPeriod
        } else if t > 0 {
            lo = 0
            hi = max(sqmu * t / r0m, 1)
            var guard_ = 0
            while F(hi).f < 0 && guard_ < 200 { lo = hi; hi *= 2; guard_ += 1 }
        } else {
            hi = 0
            lo = min(sqmu * t / r0m, -1)
            var guard_ = 0
            while F(lo).f > 0 && guard_ < 200 { hi = lo; lo *= 2; guard_ += 1 }
        }
        var x: Double
        if xPeriod.isFinite {
            x = sqmu * alpha * t
        } else {
            x = sqmu * t / r0m
        }
        if !(x > lo && x < hi) { x = 0.5 * (lo + hi) }
        var ok = false
        for _ in 0..<200 {
            let e = F(x)
            if e.f.isNaN { break }
            if e.f < 0 { lo = x } else { hi = x }
            var nx = x - e.f / e.df
            if !(nx > lo && nx < hi) || !nx.isFinite { nx = 0.5 * (lo + hi) }
            let dx = abs(nx - x)
            x = nx
            if dx <= 1e-13 * max(1, abs(x)) || hi - lo <= 1e-13 * max(1, abs(x)) { ok = true; break }
        }
        if ok {
            let x2 = x * x, z = alpha * x2
            let c = stumpffC(z), s = stumpffS(z)
            let f = 1 - x2 / r0m * c
            let g = t - x2 * x / sqmu * s
            let r = f * r0 + g * v0
            let rm = r.length
            let fd = sqmu / (rm * r0m) * (z * x * s - x)
            let gd = 1 - x2 / rm * c
            let v = fd * r0 + gd * v0
            if r.x.isFinite && v.x.isFinite && r.y.isFinite && v.y.isFinite && r.z.isFinite && v.z.isFinite {
                return StateVector(position: r, velocity: v)
            }
        }
        return rk4(position: r0, velocity: v0, mu: mu, dt: dt, step: max(1, abs(dt) / 20_000))
    }

    // MARK: Время до радиуса

    /// Ближайшее время t ≥ 0, когда расстояние до центра станет равным `radius`
    /// на участке роста (`outbound`) или убывания радиуса; nil — не достигается
    /// (или орбита почти круговая/параболическая — тогда вызывающий проверяет численно).
    /// Аналитически через эксцентрическую (гиперболическую) аномалию, без вызовов пропагатора.
    static func timeToRadius(_ radius: Double, position r0: Vec3, velocity v0: Vec3, mu: Double,
                             outbound: Bool) -> Double? {
        let r0m: Double = r0.length
        let v2: Double = v0.lengthSquared
        let rv: Double = r0.dot(v0)
        let alpha: Double = 2 / r0m - v2 / mu
        let eVec: Vec3 = ((v2 - mu / r0m) * r0 - rv * v0) / mu
        let e: Double = eVec.length
        if abs(alpha) * r0m < 1e-9 || e < 1e-9 { return nil }
        if alpha > 0 {
            let a: Double = 1 / alpha
            let cosT: Double = (1 - radius / a) / e
            guard cosT >= -1 && cosT <= 1 else { return nil }
            let et0: Double = acos(cosT)
            let et: Double = outbound ? et0 : 2 * Double.pi - et0
            let c0: Double = (1 - r0m / a) / e
            let s0: Double = rv / (e * (mu * a).squareRoot())
            let e0: Double = atan2(s0, c0)
            let n: Double = (mu / (a * a * a)).squareRoot()
            let m0: Double = e0 - e * sin(e0)
            let mt: Double = et - e * sin(et)
            var dm: Double = wrap2Pi(mt - m0)
            // Уже на радиусе (погрешность округления дала почти полный оборот).
            if dm > 2 * Double.pi - 1e-10 { dm = 0 }
            return dm / n
        }
        let a: Double = -1 / alpha
        let coshT: Double = (1 + radius / a) / e
        guard coshT >= 1 else { return nil }
        let ft0: Double = acosh(coshT)
        let ft: Double = outbound ? ft0 : -ft0
        let f0: Double = asinh(rv / (e * (mu * a).squareRoot()))
        let n: Double = (mu / (a * a * a)).squareRoot()
        let mt: Double = e * sinh(ft) - ft
        let m0: Double = e * sinh(f0) - f0
        let dt: Double = (mt - m0) / n
        return dt >= -1e-9 ? max(0, dt) : nil
    }

    // MARK: RK4

    /// Численное интегрирование задачи двух тел методом RK4 с шагом ≤ `step`.
    public static func rk4(position: Vec3, velocity: Vec3, mu: Double, dt: Double, step: Double) -> StateVector {
        let n = max(1, Int((abs(dt) / step).rounded(.up)))
        let h = dt / Double(n)
        var r = position, v = velocity
        @inline(__always) func acc(_ p: Vec3) -> Vec3 {
            let m2 = p.lengthSquared
            return p * (-mu / (m2 * m2.squareRoot()))
        }
        for _ in 0..<n {
            let k1r = v, k1v = acc(r)
            let k2r = v + k1v * (h / 2), k2v = acc(r + k1r * (h / 2))
            let k3r = v + k2v * (h / 2), k3v = acc(r + k2r * (h / 2))
            let k4r = v + k3v * h, k4v = acc(r + k3r * h)
            r += (k1r + 2 * k2r + 2 * k3r + k4r) * (h / 6)
            v += (k1v + 2 * k2v + 2 * k3v + k4v) * (h / 6)
        }
        return StateVector(position: r, velocity: v)
    }
}

/// Кеплеровы элементы орбиты относительно тела.
public struct OrbitElements: Sendable, Hashable {
    public var mu: Double
    /// Большая полуось, м (отрицательная для гиперболы, ∞ для параболы).
    public var semiMajorAxis: Double
    public var eccentricity: Double
    public var eccentricityVector: Vec3
    /// Удельный момент импульса r × v.
    public var angularMomentum: Vec3
    public var periapsisRadius: Double
    /// ∞ для незамкнутой орбиты.
    public var apoapsisRadius: Double
    /// Наклонение к плоскости XY (экватору), рад.
    public var inclination: Double
    /// Истинная аномалия, рад (0…2π для эллипса, −π…π для гиперболы).
    public var trueAnomaly: Double
    /// Период, с (∞ для незамкнутой).
    public var period: Double
    /// Время до перицентра, с (nil — перицентр пройден на незамкнутой орбите).
    public var timeToPeriapsis: Double?
    /// Время до апоцентра, с (nil — нет апоцентра).
    public var timeToApoapsis: Double?
    public var specificEnergy: Double

    public var isClosed: Bool { eccentricity < 1 }

    public init(position r: Vec3, velocity v: Vec3, mu: Double) {
        self.mu = mu
        let rm = r.length
        let v2 = v.lengthSquared
        let h = r.cross(v)
        let rv = r.dot(v)
        let eVec = ((v2 - mu / rm) * r - rv * v) / mu
        let e = eVec.length
        let energy = v2 / 2 - mu / rm
        let p = h.lengthSquared / mu
        angularMomentum = h
        eccentricityVector = eVec
        eccentricity = e
        specificEnergy = energy
        semiMajorAxis = energy == 0 ? .infinity : -mu / (2 * energy)
        periapsisRadius = p / (1 + e)
        // a(1+e) устойчивее p/(1−e) при e → 1 (почти радиальное движение).
        apoapsisRadius = e < 1 ? semiMajorAxis * (1 + e) : .infinity
        let hm = h.length
        inclination = hm > 0 ? acos(clamp(h.z / hm, -1, 1)) : 0
        // Истинная аномалия.
        var nu: Double
        if e > 1e-10 {
            let cosNu = clamp(eVec.dot(r) / (e * rm), -1, 1)
            nu = acos(cosNu)
            if rv < 0 { nu = 2 * .pi - nu }
        } else {
            nu = 0
        }
        let a = semiMajorAxis
        if e < 1 {
            period = 2 * .pi * (a * a * a / mu).squareRoot()
            let n = 2 * .pi / period
            let ea = 2 * atan(((1 - e) / (1 + e)).squareRoot() * tan(nu / 2))
            let m = wrap2Pi(ea - e * sin(ea))
            timeToPeriapsis = m < 1e-12 ? 0 : (2 * .pi - m) / n
            timeToApoapsis = wrap2Pi(.pi - m) / n
            trueAnomaly = wrap2Pi(nu)
        } else {
            period = .infinity
            timeToApoapsis = nil
            let nuS = wrapPi(nu)
            trueAnomaly = nuS
            if rv < 0 {
                if e > 1 + 1e-9 {
                    let ff = 2 * atanh(((e - 1) / (e + 1)).squareRoot() * tan(nuS / 2))
                    let mh = e * sinh(ff) - ff
                    timeToPeriapsis = -mh / (mu / pow(-a, 3)).squareRoot()
                } else {
                    // Парабола: уравнение Баркера.
                    let d = tan(nuS / 2)
                    timeToPeriapsis = -0.5 * (p * p * p / mu).squareRoot() * (d + d * d * d / 3)
                }
            } else {
                timeToPeriapsis = nil
            }
        }
    }

    /// Сводка для HUD: высоты над уровнем моря тела `body`.
    public func summary(body: CelestialBody) -> OrbitSummary {
        OrbitSummary(body: body.id,
                     apoapsisAltitude: apoapsisRadius.isFinite ? apoapsisRadius - body.radius : .infinity,
                     periapsisAltitude: periapsisRadius - body.radius,
                     timeToApoapsis: timeToApoapsis, timeToPeriapsis: timeToPeriapsis,
                     eccentricity: eccentricity, inclination: inclination, period: period)
    }
}
