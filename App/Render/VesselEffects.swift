import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Общие материалы и меши эффектов корабля: создаются один раз.
@MainActor
enum VesselEffectKit {
    static func ghost(_ c: UIColor, _ opacity: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: c)
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return m
    }

    /// Дым: 3 набора (серый, светлый РДТТ, пыль) по 4 уровня непрозрачности (плотный → бледный).
    static let smoke: [[UnlitMaterial]] = [
        [Float(0.50), 0.34, 0.20, 0.09].map { ghost(UIColor(white: 0.66, alpha: 1), $0) },
        [Float(0.60), 0.42, 0.25, 0.11].map { ghost(UIColor(white: 0.90, alpha: 1), $0) },
        [Float(0.50), 0.36, 0.22, 0.10].map { ghost(UIColor(red: 0.62, green: 0.52, blue: 0.40, alpha: 1), $0) },
    ]
    /// Полосы воздуха: 3 уровня яркости.
    static let streak: [UnlitMaterial] = [Float(0.14), 0.28, 0.48].map { ghost(UIColor(white: 0.95, alpha: 1), $0) }
    static let cone: [UnlitMaterial] = [Float(0.14), 0.26, 0.40].map { ghost(UIColor(white: 1.0, alpha: 1), $0) }
    static let plasmaOuter: [UnlitMaterial] = [Float(0.10), 0.22, 0.36, 0.52].map {
        ghost(UIColor(red: 1.0, green: 0.42, blue: 0.40, alpha: 1), $0)
    }
    static let plasmaInner: [UnlitMaterial] = [Float(0.18), 0.34, 0.55].map {
        ghost(UIColor(red: 1.0, green: 0.80, blue: 0.55, alpha: 1), $0)
    }
    static let fire: [UnlitMaterial] = [Float(0.25), 0.45, 0.70].map {
        ghost(UIColor(red: 1.0, green: 0.55, blue: 0.18, alpha: 1), $0)
    }

    /// Низкополигональная сфера единичного радиуса.
    static let puffMesh: MeshResource? = {
        var b = MeshBuilder()
        b.lathe([SIMD2(0, -1), SIMD2(0.87, -0.5), SIMD2(1, 0), SIMD2(0.87, 0.5), SIMD2(0, 1)], segments: 8)
        return b.makeMesh(name: "puff")
    }()

    /// Единичный брус вдоль Y (длина 1, сечение 1).
    static let barMesh: MeshResource? = {
        var b = MeshBuilder()
        b.beam(F3(0, -0.5, 0), F3(0, 0.5, 0), thickness: 1)
        return b.makeMesh(name: "bar")
    }()

    /// Юбка конденсационного конуса: вершина y = 0, раскрывается к y = 1 (радиус 1).
    static let coneMesh: MeshResource? = {
        var b = MeshBuilder()
        b.lathe([SIMD2(0.0, 0.0), SIMD2(0.18, 0.06), SIMD2(0.45, 0.22), SIMD2(0.78, 0.5),
                 SIMD2(0.95, 0.8), SIMD2(1.0, 1.0)], segments: 20, twoSided: true)
        return b.makeMesh(name: "cone")
    }()

    /// Колпак плазмы: нос y = 0, длина 3 по +Y, максимум радиуса 1 у y ≈ 0.6.
    static let capMesh: MeshResource? = {
        var b = MeshBuilder()
        b.lathe([SIMD2(0.0, 0.0), SIMD2(0.35, 0.04), SIMD2(0.7, 0.15), SIMD2(0.92, 0.35), SIMD2(1.0, 0.6),
                 SIMD2(0.9, 1.0), SIMD2(0.65, 1.6), SIMD2(0.35, 2.3), SIMD2(0.0, 3.0)], segments: 20, twoSided: true)
        return b.makeMesh(name: "cap")
    }()
}

/// Эффекты скорости и входа: дым двигателей, потоки воздуха, конденсационный конус, плазма.
/// Корень добавляется в корень сцены (камера в нуле); обновляется каждый кадр.
@MainActor
final class VesselEffects {
    static var smokeEnabled = true
    static var streaksEnabled = true
    static var coneEnabled = true
    static var plasmaEnabled = true

    let root = Entity()

    private struct Puff {
        var p = D3.zero          // положение в системе тела, м
        var v = D3.zero          // скорость относительно воздуха, м/с
        var age = 0.0
        var life = 1.0
        var s0 = 1.0
        var s1 = 2.0
        var kind = 0             // 0 дым, 1 РДТТ, 2 пыль
        var level = -1
        var alive = false
    }
    private struct Streak {
        var axial = 0.0
        var ang = 0.0
        var rad = 1.0
        var seed = 0.5
        var level = -1
        var ready = false
    }

    private static let smokeLimits = [60, 120, 200]
    private static let streakLimits = [16, 28, 40]
    private static let trailLimits = [8, 14, 24]
    private static let streakHalfLen = 30.0

    private var puffs: [Puff]
    private var puffEntities: [ModelEntity] = []
    private var cursor = 0
    private var emitAcc = 0.0
    private var dustAcc = 0.0
    private var prevPos: D3?

    private var streaks: [Streak]
    private var streakEntities: [ModelEntity] = []
    private var trails: [Streak]
    private var trailEntities: [ModelEntity] = []

    private let cone: ModelEntity
    private var coneLevel = -1
    private let capOuter: ModelEntity
    private let capInner: ModelEntity
    private var capOuterLevel = -1
    private var capInnerLevel = -1
    private var rng = RNG()

    private struct RNG {
        var s: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            s ^= s << 13
            s ^= s >> 7
            s ^= s << 17
            return Double(s >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    }

    init() {
        let pm = VesselEffectKit.puffMesh ?? MeshResource.generateBox(size: 1)
        let bm = VesselEffectKit.barMesh ?? MeshResource.generateBox(size: 1)
        let cm = VesselEffectKit.coneMesh ?? MeshResource.generateBox(size: 1)
        let km = VesselEffectKit.capMesh ?? MeshResource.generateBox(size: 1)
        let smokeMax = Self.smokeLimits[2], streakMax = Self.streakLimits[2], trailMax = Self.trailLimits[2]
        puffs = Array(repeating: Puff(), count: smokeMax)
        streaks = Array(repeating: Streak(), count: streakMax)
        trails = Array(repeating: Streak(), count: trailMax)
        cone = ModelEntity(mesh: cm, materials: [VesselEffectKit.cone[0]])
        capOuter = ModelEntity(mesh: km, materials: [VesselEffectKit.plasmaOuter[0]])
        capInner = ModelEntity(mesh: km, materials: [VesselEffectKit.plasmaInner[0]])
        for _ in 0..<smokeMax {
            let e = ModelEntity(mesh: pm, materials: [VesselEffectKit.smoke[0][0]])
            e.isEnabled = false
            root.addChild(e)
            puffEntities.append(e)
        }
        for _ in 0..<streakMax {
            let e = ModelEntity(mesh: bm, materials: [VesselEffectKit.streak[0]])
            e.isEnabled = false
            root.addChild(e)
            streakEntities.append(e)
        }
        for _ in 0..<trailMax {
            let e = ModelEntity(mesh: bm, materials: [VesselEffectKit.fire[0]])
            e.isEnabled = false
            root.addChild(e)
            trailEntities.append(e)
        }
        for e in [cone, capOuter, capInner] {
            e.isEnabled = false
            root.addChild(e)
        }
    }

    /// Сброс при перезапуске/смене корабля: всё гасится.
    func reset() {
        for i in puffs.indices { killPuff(i) }
        for e in streakEntities { e.isEnabled = false }
        for e in trailEntities { e.isEnabled = false }
        for i in streaks.indices { streaks[i].ready = false }
        for i in trails.indices { trails[i].ready = false }
        cone.isEnabled = false
        capOuter.isEnabled = false
        capInner.isEnabled = false
        cursor = 0
        emitAcc = 0
        dustAcc = 0
        prevPos = nil
        coneLevel = -1
        capOuterLevel = -1
        capInnerLevel = -1
    }

    func update(_ f: VesselEffectFrame) {
        let dt = clampd(f.dt, 0, 0.1)
        let vp = f.vessel.position.d3
        let cam = vp - f.vesselRel
        let q = min(2, max(0, f.quality))
        let rot = f.vessel.attitude.quatd
        let axis = rot.act(D3(0, 1, 0))
        var maxD = 0.5
        for id in f.vessel.parts { maxD = max(maxD, id.spec.diameter) }
        let center = f.vesselRel + axis * (f.stackHeight * 0.5)

        updateSmoke(f, dt: dt, vp: vp, cam: cam, rot: rot, maxD: maxD, quality: q)
        updateStreaks(f, dt: dt, center: center, maxD: maxD, quality: q)
        updateCone(f, center: center, maxD: maxD)
        updatePlasma(f, center: center, axis: axis, maxD: maxD, quality: q)
        prevPos = vp
    }

    // MARK: - Дым и пыль

    private func killPuff(_ i: Int) {
        puffs[i].alive = false
        if puffEntities[i].isEnabled { puffEntities[i].isEnabled = false }
    }

    private func spawn(kind: Int, pos: D3, vel: D3, life: Double, s0: Double, s1: Double, limit: Int) {
        let i = cursor % limit
        cursor = (i + 1) % limit
        puffs[i] = Puff(p: pos, v: vel, age: 0, life: life, s0: s0, s1: s1, kind: kind, level: -1, alive: true)
    }

    private func updateSmoke(_ f: VesselEffectFrame, dt: Double, vp: D3, cam: D3, rot: simd_quatd,
                             maxD: Double, quality q: Int) {
        let limit = Self.smokeLimits[q]
        guard Self.smokeEnabled else {
            for i in puffs.indices where puffs[i].alive { killPuff(i) }
            return
        }
        let tel = f.telemetry
        let rho = clampd(tel.atmosphereDensity / 1.225, 0, 1.5)
        let wind = f.windVelocity
        let engines = f.vessel.firingEngines
        let burning = tel.thrust > 0 || tel.solidBurning
        let thr = clampd(f.vessel.throttle, 0, 1)
        let back = rot.act(D3(0, -1, 0))
        let nParts = min(f.partBottoms.count, f.vessel.parts.count)

        if dt > 0, burning, rho > 0.01, !engines.isEmpty {
            // Скорость выпуска: растёт с плотностью воздуха и тягой, РДТТ гуще.
            var total = 0.0
            for i in engines where i >= 0 && i < nParts {
                let solid = f.vessel.parts[i].spec.isSolid
                total += (solid ? 30 : 16 * (0.3 + 0.7 * thr)) * min(1, rho * 1.4)
            }
            // Время жизни ограничено ёмкостью пула, чтобы кольцо не затирало свежие клубы.
            let life = max(0.8, min(2.5 + 3.5 * min(1, rho), 0.9 * Double(limit) / max(total, 1)))
            emitAcc += total * dt
            let n = min(Int(emitAcc), 10)
            emitAcc -= Double(n)
            var shift = D3.zero
            if let pp = prevPos, simd_length(pp - vp) < 500 { shift = pp - vp }
            for k in 0..<max(n, 0) {
                let i = engines[k % engines.count]
                guard i >= 0, i < nParts else { continue }
                let spec = f.vessel.parts[i].spec
                let t = Double(k + 1) / Double(n)
                let nozzle = vp + rot.act(D3(0, f.partBottoms[i], 0)) + shift * (1 - t)
                let r = spec.diameter * 0.5
                let spread = D3(rng.range(-1, 1), rng.range(-1, 1), rng.range(-1, 1)) * (4 + 6 * thr)
                let vel = back * rng.range(25, 60) * (spec.isSolid ? 1 : max(0.4, thr)) + spread
                let s0 = r * rng.range(0.7, 1.2)
                let s1 = s0 * rng.range(3.5, 5.5) * (0.6 + 0.4 * min(1, rho))
                spawn(kind: spec.isSolid ? 1 : 0, pos: nozzle + spread * 0.05, vel: vel,
                      life: life * rng.range(0.8, 1.2), s0: s0, s1: s1, limit: limit)
            }

            // Облако пыли у площадки при старте.
            let h = f.heightAboveGround
            if h < 60, rho > 0.3 {
                let tf = tel.maxThrust > 0 ? clampd(tel.thrust / tel.maxThrust, 0, 1) : thr
                dustAcc += 200 * tf * (1 - clampd(h / 60, 0, 1)) * Double(q + 1) / 3 * dt
                let m = min(Int(dustAcc), 8)
                dustAcc -= Double(m)
                let g = vp - f.vesselRel + f.groundRel
                let t1 = perpendicular(D3(0, 0, 1), to: f.up)
                let t2 = simd_cross(f.up, t1)
                for _ in 0..<max(m, 0) {
                    let a = rng.range(0, 2 * .pi)
                    let dir = t1 * cos(a) + t2 * sin(a)
                    let rr = maxD * rng.range(0.6, 2.5)
                    let pos = g + dir * rr + f.up * rng.range(0.5, 2)
                    let vel = dir * rng.range(10, 28) + f.up * rng.range(1, 5)
                    spawn(kind: 2, pos: pos, vel: vel, life: rng.range(3, 5.5), s0: rng.range(1.5, 3),
                          s1: rng.range(9, 16), limit: limit)
                }
            }
        }

        for i in puffs.indices where puffs[i].alive {
            if i >= limit {
                killPuff(i)
                continue
            }
            puffs[i].age += dt
            let fr = puffs[i].age / puffs[i].life
            if fr >= 1 || simd_length_squared(puffs[i].p - cam) > 3000 * 3000 {
                killPuff(i)
                continue
            }
            // Снос ветром и торможение выброса.
            let drag = puffs[i].kind == 2 ? 1.2 : 2.4
            puffs[i].v *= exp(-drag * dt)
            puffs[i].p += (puffs[i].v + wind) * dt
            let lvl = min(3, Int(fr * 4))
            let e = puffEntities[i]
            if puffs[i].level != lvl {
                puffs[i].level = lvl
                e.model?.materials = [VesselEffectKit.smoke[puffs[i].kind][lvl]]
            }
            if !e.isEnabled { e.isEnabled = true }
            let ease = 1 - (1 - fr) * (1 - fr)
            let s = puffs[i].s0 + (puffs[i].s1 - puffs[i].s0) * ease
            e.position = f3(puffs[i].p - cam)
            e.scale = F3(repeating: Float(s))
        }
    }

    // MARK: - Потоки воздуха

    private func updateStreaks(_ f: VesselEffectFrame, dt: Double, center: D3, maxD: Double, quality q: Int) {
        let n = Self.streakLimits[q]
        let speed = simd_length(f.airVelocity)
        let k = Self.sstep(1500, 25000, f.telemetry.dynamicPressure)
        guard Self.streaksEnabled, k > 0.001, speed > 20 else {
            for e in streakEntities where e.isEnabled { e.isEnabled = false }
            return
        }
        let half = Self.streakHalfLen
        let flow = -f.airVelocity / speed
        let e1 = perpendicular(D3(0, 1, 0), to: flow)
        let e2 = simd_cross(flow, e1)
        let orient = simd_quatf(from: F3(0, 1, 0), to: f3(flow))
        let visSpeed = clampd(speed * 0.6, 40, 300)
        let length = Float(clampd(speed * 0.012, 1, 8))
        let width = Float(0.06 + 0.03 * maxD)
        let active = Int(Double(n) * (0.15 + 0.35 * k))
        for i in 0..<streakEntities.count {
            let e = streakEntities[i]
            guard i < active else {
                if e.isEnabled { e.isEnabled = false }
                continue
            }
            if !streaks[i].ready {
                streaks[i] = Streak(axial: rng.range(-half, half), ang: rng.range(0, 2 * .pi),
                                    rad: rng.range(0.7, 3.2), seed: rng.next(), level: -1, ready: true)
            }
            streaks[i].axial += visSpeed * dt
            if streaks[i].axial > half {
                streaks[i].axial -= 2 * half
                streaks[i].ang = rng.range(0, 2 * .pi)
                streaks[i].rad = rng.range(0.7, 3.2)
                streaks[i].seed = rng.next()
            }
            let s = streaks[i]
            let edge = min(1, (half - abs(s.axial)) / (half * 0.3))
            let b = k * edge * (0.6 + 0.6 * s.seed)
            let lvl = b < 0.12 ? -1 : (b < 0.35 ? 0 : (b < 0.65 ? 1 : 2))
            if lvl < 0 {
                if e.isEnabled { e.isEnabled = false }
                continue
            }
            if s.level != lvl {
                streaks[i].level = lvl
                e.model?.materials = [VesselEffectKit.streak[lvl]]
            }
            let lat = (e1 * cos(s.ang) + e2 * sin(s.ang)) * (maxD * s.rad)
            let pos = center + flow * s.axial + lat
            e.transform = Transform(scale: F3(width, length * Float(0.6 + 0.8 * s.seed), width),
                                    rotation: orient, translation: f3(pos))
            if !e.isEnabled { e.isEnabled = true }
        }
    }

    // MARK: - Конденсационный конус

    private func updateCone(_ f: VesselEffectFrame, center: D3, maxD: Double) {
        let speed = simd_length(f.airVelocity)
        let bell = exp(-pow((f.telemetry.mach - 1.0) / 0.18, 2))
        // Нужен плотный и влажный воздух: растёт от 0.02 до 0.3 кг/м³.
        let dens = Self.sstep(0.02, 0.3, f.telemetry.atmosphereDensity)
        let inten = bell * dens
        guard Self.coneEnabled, inten > 0.06, speed > 50 else {
            if cone.isEnabled { cone.isEnabled = false }
            return
        }
        let u = f.airVelocity / speed
        let flick = 0.8 + 0.2 * sin(f.time * 23) + 0.05 * sin(f.time * 61)
        let v = inten * flick
        let lvl = v < 0.25 ? 0 : (v < 0.55 ? 1 : 2)
        if lvl != coneLevel {
            coneLevel = lvl
            cone.model?.materials = [VesselEffectKit.cone[lvl]]
        }
        let h = f.stackHeight
        let radius = Float(maxD * 1.6 * (1 + 0.04 * sin(f.time * 37)))
        let len = Float(max(h * 0.6, maxD * 2))
        // Ось меша +Y направлена назад по потоку, вершина — у носа.
        let apex = center + u * (h * 0.15)
        cone.transform = Transform(scale: F3(radius, len, radius),
                                   rotation: simd_quatf(from: F3(0, 1, 0), to: f3(-u)), translation: f3(apex))
        if !cone.isEnabled { cone.isEnabled = true }
    }

    // MARK: - Плазма

    private func updatePlasma(_ f: VesselEffectFrame, center: D3, axis: D3, maxD: Double, quality q: Int) {
        let hh = clampd(f.telemetry.heating, 0, 1)
        let speed = simd_length(f.airVelocity)
        guard Self.plasmaEnabled, hh > 0.04, speed > 100 else {
            if capOuter.isEnabled { capOuter.isEnabled = false }
            if capInner.isEnabled { capInner.isEnabled = false }
            for e in trailEntities where e.isEnabled { e.isEnabled = false }
            return
        }
        let u = f.airVelocity / speed
        let flow = -u
        let orient = simd_quatf(from: F3(0, 1, 0), to: f3(flow))
        let h = f.stackHeight
        let cosA = abs(simd_dot(u, axis))
        let halfExt = cosA * h / 2 + sqrt(max(0, 1 - cosA * cosA)) * maxD / 2
        let flick = 1 + 0.05 * sin(f.time * 31) + 0.03 * sin(f.time * 73)
        let radius = maxD * (0.9 + 0.6 * hh)
        let length = (h * 0.5 + maxD * 2.2) * (0.6 + hh)
        let apex = center + u * (halfExt + 0.3 * maxD)

        let lo = min(3, Int(hh * 4.5 * (0.9 + 0.1 * flick)))
        if lo != capOuterLevel {
            capOuterLevel = lo
            capOuter.model?.materials = [VesselEffectKit.plasmaOuter[lo]]
        }
        let li = min(2, Int(hh * 3.2))
        if li != capInnerLevel {
            capInnerLevel = li
            capInner.model?.materials = [VesselEffectKit.plasmaInner[li]]
        }
        let ro = Float(radius * flick), lenO = Float(length / 3 * flick)
        capOuter.transform = Transform(scale: F3(ro, lenO, ro), rotation: orient, translation: f3(apex))
        let ri = ro * 0.62
        capInner.transform = Transform(scale: F3(ri, lenO * 0.75, ri), rotation: orient,
                                       translation: f3(apex + flow * (0.1 * maxD)))
        if !capOuter.isEnabled { capOuter.isEnabled = true }
        if !capInner.isEnabled { capInner.isEnabled = true }

        // Огненные полосы позади корабля.
        let e1 = perpendicular(D3(0, 1, 0), to: flow)
        let e2 = simd_cross(flow, e1)
        let active = Int(Double(Self.trailLimits[q]) * clampd(hh * 1.5, 0, 1))
        let trailLen = (h + maxD * 6) * (0.5 + 2 * hh)
        for i in 0..<trailEntities.count {
            let e = trailEntities[i]
            guard i < active else {
                if e.isEnabled { e.isEnabled = false }
                continue
            }
            if !trails[i].ready {
                trails[i] = Streak(axial: 0, ang: rng.range(0, 2 * .pi), rad: rng.range(0.3, 0.9),
                                   seed: rng.range(0.01, 0.99), level: -1, ready: true)
            }
            let s = trails[i]
            let phase = (s.seed + f.time * (0.8 + 1.2 * s.seed)).truncatingRemainder(dividingBy: 1)
            let axial = halfExt * 0.6 + phase * trailLen
            let rr = radius * s.rad * (1 - 0.5 * phase)
            let a = s.ang + s.seed * 6
            let pos = center + flow * axial + (e1 * cos(a) + e2 * sin(a)) * rr
            let b = (1 - phase) * hh
            let lvl = b < 0.15 ? 0 : (b < 0.4 ? 1 : 2)
            if s.level != lvl {
                trails[i].level = lvl
                e.model?.materials = [VesselEffectKit.fire[lvl]]
            }
            let w = Float(maxD * 0.09 * (1 - phase * 0.5))
            e.transform = Transform(scale: F3(w, Float(trailLen * 0.12 * (0.5 + s.seed)), w),
                                    rotation: orient, translation: f3(pos))
            if !e.isEnabled { e.isEnabled = true }
        }
    }

    private static func sstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clampd((x - a) / (b - a), 0, 1)
        return t * t * (3 - 2 * t)
    }
}
