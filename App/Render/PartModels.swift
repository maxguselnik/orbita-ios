import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Общие материалы корабля и площадки (создаются один раз).
@MainActor
final class RenderMaterials {
    static let shared = RenderMaterials()

    let white = SimpleMaterial(color: UIColor(white: 0.9, alpha: 1), roughness: 0.55, isMetallic: false)
    let lightGray = SimpleMaterial(color: UIColor(white: 0.68, alpha: 1), roughness: 0.6, isMetallic: false)
    let darkGray = SimpleMaterial(color: UIColor(white: 0.16, alpha: 1), roughness: 0.6, isMetallic: false)
    let black = SimpleMaterial(color: UIColor(white: 0.05, alpha: 1), roughness: 0.4, isMetallic: false)
    let orange = SimpleMaterial(color: UIColor(red: 0.86, green: 0.40, blue: 0.10, alpha: 1), roughness: 0.6, isMetallic: false)
    let shield = SimpleMaterial(color: UIColor(red: 0.24, green: 0.16, blue: 0.11, alpha: 1), roughness: 0.9, isMetallic: false)
    let metal = SimpleMaterial(color: UIColor(white: 0.45, alpha: 1), roughness: 0.35, isMetallic: true)
    let darkMetal = SimpleMaterial(color: UIColor(white: 0.22, alpha: 1), roughness: 0.45, isMetallic: true)
    let gold = SimpleMaterial(color: UIColor(red: 0.82, green: 0.62, blue: 0.24, alpha: 1), roughness: 0.35, isMetallic: true)
    let red = SimpleMaterial(color: UIColor(red: 0.74, green: 0.16, blue: 0.11, alpha: 1), roughness: 0.6, isMetallic: false)
    let canopyA = SimpleMaterial(color: UIColor(red: 0.95, green: 0.45, blue: 0.12, alpha: 1), roughness: 0.8, isMetallic: false)
    let canopyB = SimpleMaterial(color: UIColor(white: 0.93, alpha: 1), roughness: 0.8, isMetallic: false)
    let window = SimpleMaterial(color: UIColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1), roughness: 0.15, isMetallic: true)
    let concrete = SimpleMaterial(color: UIColor(white: 0.52, alpha: 1), roughness: 0.95, isMetallic: false)
    let concreteDark = SimpleMaterial(color: UIColor(white: 0.30, alpha: 1), roughness: 0.95, isMetallic: false)
    let monoBody = SimpleMaterial(color: UIColor(red: 0.74, green: 0.82, blue: 0.78, alpha: 1), roughness: 0.5, isMetallic: false)
    let yellow = SimpleMaterial(color: UIColor(red: 0.95, green: 0.76, blue: 0.14, alpha: 1), roughness: 0.55, isMetallic: false)
    let towerSteel = SimpleMaterial(color: UIColor(red: 0.60, green: 0.17, blue: 0.10, alpha: 1), roughness: 0.7, isMetallic: false)

    let plumeOuter: UnlitMaterial
    let plumeCore: UnlitMaterial
    let plumeSolid: UnlitMaterial
    /// Полупрозрачный ореол факела (см. `VesselVisual.transparentPlumeGlow`).
    let plumeGlow: UnlitMaterial

    private init() {
        // Факел непрозрачный: прозрачный факел на подъёме ронял рендер в симуляторе (см. отчёт).
        plumeOuter = UnlitMaterial(color: UIColor(red: 1.0, green: 0.52, blue: 0.16, alpha: 1))
        plumeCore = UnlitMaterial(color: UIColor(red: 1.0, green: 0.93, blue: 0.74, alpha: 1))
        plumeSolid = UnlitMaterial(color: UIColor(red: 1.0, green: 0.70, blue: 0.30, alpha: 1))
        var glow = UnlitMaterial(color: UIColor(red: 1.0, green: 0.55, blue: 0.20, alpha: 1))
        glow.blending = .transparent(opacity: .init(floatLiteral: 0.28))
        plumeGlow = glow
    }
}

/// Процедурные модели деталей: части (меш + материал) в осях детали, низ детали — y = 0.
@MainActor
enum PartModels {
    typealias Piece = (mesh: MeshResource, material: any Material)

    private static var cache: [PartID: [Piece]] = [:]

    static func pieces(_ id: PartID) -> [Piece] {
        if let p = cache[id] { return p }
        let built = build(id).compactMap { item -> Piece? in
            guard let mesh = item.0.makeMesh(name: id.rawValue) else { return nil }
            return (mesh, item.1)
        }
        cache[id] = built
        return built
    }

    private static let seg = 32

    private static func cyl(_ r: Float, _ y0: Float, _ y1: Float, caps: Bool = true) -> [SIMD2<Float>] {
        caps ? [SIMD2(0, y0), SIMD2(r, y0), SIMD2(r, y1), SIMD2(0, y1)] : [SIMD2(r, y0), SIMD2(r, y1)]
    }

    private static func lathe(_ profile: [SIMD2<Float>], twoSided: Bool = false) -> MeshBuilder {
        var b = MeshBuilder()
        b.lathe(profile, segments: seg, twoSided: twoSided)
        return b
    }

    /// Раструб сопла: от среза (y0, радиус re) до горловины (y1, радиус rt).
    static func bell(re: Float, rt: Float, y0: Float, y1: Float) -> MeshBuilder {
        var prof: [SIMD2<Float>] = []
        for i in 0...10 {
            let t = Float(i) / 10
            prof.append(SIMD2(rt + (re - rt) * (1 - t) * (1 - t), y0 + (y1 - y0) * t))
        }
        return lathe(prof, twoSided: true)
    }

    private static func build(_ id: PartID) -> [(MeshBuilder, any Material)] {
        let mats = RenderMaterials.shared
        let spec = id.spec
        let h = Float(spec.height), d = Float(spec.diameter), r = d / 2
        switch spec.kind {
        case .pod:
            let top = Float(0.3) * min(d, 1.25)
            let shield = lathe([SIMD2(0, 0), SIMD2(r * 0.93, 0), SIMD2(r, 0.05 * h), SIMD2(r, 0.08 * h)])
            let body = lathe([SIMD2(r, 0.08 * h), SIMD2(r * 0.98, 0.12 * h), SIMD2(top, 0.9 * h),
                              SIMD2(top, h), SIMD2(0, h)])
            let band = lathe(cyl(r * 0.995 - (r - top) * 0.22, 0.24 * h, 0.3 * h, caps: false))
            var win = MeshBuilder()
            // Иллюминатор на спине (+Z) и люк.
            let wy = 0.5 * h
            let wr = r - (r - top) * (wy - 0.08 * h) / (0.82 * h)
            win.box(center: F3(0, wy, wr * 0.98), x: F3(0.16 * d, 0, 0), y: F3(0, 0.1 * h, 0), z: F3(0, 0, 0.04))
            win.box(center: F3(wr * 0.98, wy - 0.05 * h, 0), x: F3(0.03, 0, 0), y: F3(0, 0.16 * h, 0), z: F3(0, 0, 0.14 * d))
            return [(shield, mats.shield), (body, mats.lightGray), (band, mats.darkGray), (win, mats.window)]
        case .probe:
            let body = lathe([SIMD2(0, 0), SIMD2(r, 0), SIMD2(r, 0.55 * h), SIMD2(r * 0.6, h), SIMD2(0, h)])
            let ring = lathe(cyl(r * 1.01, 0.1 * h, 0.2 * h, caps: false))
            return [(body, mats.gold), (ring, mats.darkGray)]
        case .chute:
            let base = lathe(cyl(r, 0, 0.3 * h))
            let cap = lathe([SIMD2(r, 0.3 * h), SIMD2(r, 0.55 * h), SIMD2(r * 0.75, h), SIMD2(0, h)])
            return [(base, mats.darkGray), (cap, mats.red)]
        case .decoupler:
            let ring = lathe(cyl(r, 0, h))
            let band = lathe(cyl(r * 1.01, 0.35 * h, 0.65 * h, caps: false))
            return [(ring, mats.darkGray), (band, mats.orange)]
        case .tank:
            let isBig = id == .j64
            let body = lathe(cyl(r, 0, h))
            var rings = MeshBuilder()
            let rr = r * 1.008
            let bandH = min(Float(0.12), 0.06 * h)
            rings.lathe(cyl(rr, 0, bandH, caps: false), segments: seg)
            rings.lathe(cyl(rr, h - bandH, h, caps: false), segments: seg)
            if h > 1.5 {
                rings.lathe(cyl(rr, 0.48 * h, 0.52 * h, caps: false), segments: seg)
            }
            // Продольная полоса.
            rings.box(center: F3(0, h / 2, rr), x: F3(0.06 * d, 0, 0), y: F3(0, h * 0.4, 0), z: F3(0, 0, 0.01))
            return [(body, isBig ? mats.orange : mats.white), (rings, isBig ? mats.black : mats.darkGray)]
        case .legs:
            return [(lathe(cyl(r * 0.92, 0, h)), mats.darkGray)]
        case .engine:
            if spec.isSolid {
                let nozzleH = Float(0.14) * h
                let body = lathe(cyl(r, nozzleH, h))
                var bands = MeshBuilder()
                let rr = r * 1.008
                for (a, b) in [(Float(0.16), Float(0.2)), (0.5, 0.56), (0.93, 1.0)] {
                    bands.lathe(cyl(rr, a * h, b * h, caps: false), segments: seg)
                }
                let nozzle = bell(re: r * 0.62, rt: r * 0.35, y0: 0, y1: nozzleH)
                return [(body, mats.white), (bands, mats.black), (nozzle, mats.darkMetal)]
            }
            let bellTop = Float(0.68) * h
            let mount = lathe([SIMD2(0, bellTop * 0.98), SIMD2(r * 0.42, bellTop * 0.98),
                               SIMD2(r, h * 0.94), SIMD2(r, h), SIMD2(0, h)])
            let chamber = lathe(cyl(r * 0.3, bellTop * 0.92, bellTop * 1.05))
            let nozzle = bell(re: r * 0.92, rt: r * 0.28, y0: 0, y1: bellTop * 0.94)
            return [(mount, mats.darkGray), (chamber, mats.metal), (nozzle, mats.darkMetal)]
        case .rcs:
            let ring = lathe(cyl(rcsRingRadius, 0, h))
            let band = lathe(cyl(rcsRingRadius * 1.01, 0.4 * h, 0.6 * h, caps: false))
            var pods = MeshBuilder()
            var nozzles = MeshBuilder()
            for k in 0..<4 {
                let rad = rcsRadial[k], tng = rcsTangent(k)
                pods.box(center: rcsPos(k, 0.685, 0, 0.15), x: rad * 0.11, y: F3(0, 0.12, 0), z: tng * 0.16)
                for slot in 0..<5 {
                    for base in rcsNozzleBases(block: k, slot: slot) {
                        let dir = rcsExhaustDir(block: k, slot: slot)
                        nozzles.append(placed(rcsNozzle, q: rcsAlign(dir), at: base))
                    }
                }
            }
            return [(ring, mats.darkGray), (band, mats.yellow), (pods, mats.white), (nozzles, mats.darkMetal)]
        case .monoTank:
            let body = lathe([SIMD2(0, 0), SIMD2(r * 0.88, 0), SIMD2(r, 0.13 * h), SIMD2(r, 0.87 * h),
                              SIMD2(r * 0.88, h), SIMD2(0, h)])
            let stripe = lathe(cyl(r * 1.012, 0.36 * h, 0.64 * h, caps: false))
            var fittings = MeshBuilder()
            // Бугорки-клапаны на торцах и вертикальная метка на спине.
            fittings.lathe(cyl(r * 0.22, h, h + 0.03), segments: 16)
            fittings.lathe(cyl(r * 0.22, -0.03, 0), segments: 16)
            fittings.box(center: F3(0, h / 2, r * 1.014), x: F3(0.05 * d, 0, 0), y: F3(0, 0.3 * h, 0), z: F3(0, 0, 0.008))
            return [(body, mats.monoBody), (stripe, mats.yellow), (fittings, mats.darkGray)]
        }
    }

    // MARK: - Блок РСУ: геометрия сопел (общая для модели и струек)

    /// Радиальные направления четырёх выступов блока: +X, +Z, −X, −Z.
    static let rcsRadial: [F3] = [F3(1, 0, 0), F3(0, 0, 1), F3(-1, 0, 0), F3(0, 0, -1)]
    static let rcsRingRadius: Float = 0.625
    static let rcsNozzleLength: Float = 0.06
    /// Касательная выступа k: Y × радиаль.
    static func rcsTangent(_ k: Int) -> F3 { simd_cross(F3(0, 1, 0), rcsRadial[k]) }

    /// Точка выступа k: `a` — вдоль радиали, `t` — вдоль касательной, `y` — высота над низом детали.
    static func rcsPos(_ k: Int, _ a: Float, _ t: Float, _ y: Float) -> F3 {
        rcsRadial[k] * a + rcsTangent(k) * t + F3(0, y, 0)
    }

    /// Слоты сопел: 0 — выхлоп вверх (+Y), 1 — вниз, 2 — наружу, 3 — по +касательной, 4 — по −касательной.
    static func rcsExhaustDir(block k: Int, slot: Int) -> F3 {
        switch slot {
        case 0: return F3(0, 1, 0)
        case 1: return F3(0, -1, 0)
        case 2: return rcsRadial[k]
        case 3: return rcsTangent(k)
        default: return -rcsTangent(k)
        }
    }

    /// Основания сопел слота на грани выступа.
    static func rcsNozzleBases(block k: Int, slot: Int) -> [F3] {
        switch slot {
        case 0: return [rcsPos(k, 0.685, -0.07, 0.27), rcsPos(k, 0.685, 0.07, 0.27)]
        case 1: return [rcsPos(k, 0.685, -0.07, 0.03), rcsPos(k, 0.685, 0.07, 0.03)]
        case 2: return [rcsPos(k, 0.795, 0, 0.09), rcsPos(k, 0.795, 0, 0.21)]
        case 3: return [rcsPos(k, 0.685, 0.16, 0.09), rcsPos(k, 0.685, 0.16, 0.21)]
        default: return [rcsPos(k, 0.685, -0.16, 0.09), rcsPos(k, 0.685, -0.16, 0.21)]
        }
    }

    /// Точка выхода струи слота (центр кластера сопел, на срезе).
    static func rcsExhaustOrigin(block k: Int, slot: Int) -> F3 {
        let bases = rcsNozzleBases(block: k, slot: slot)
        let c = (bases[0] + bases[1]) * 0.5
        return c + rcsExhaustDir(block: k, slot: slot) * rcsNozzleLength
    }

    /// Поворот, переводящий +Y в `d` (единичный).
    static func rcsAlign(_ d: F3) -> simd_quatf {
        if d.y < -0.99 { return simd_quatf(angle: .pi, axis: F3(0, 0, 1)) }
        return simd_quatf(from: F3(0, 1, 0), to: d)
    }

    /// Сопло вдоль +Y: горловина в y = 0, срез в y = длина.
    private static let rcsNozzle: MeshBuilder = {
        var b = MeshBuilder()
        b.lathe([SIMD2(0.015, 0), SIMD2(0.038, rcsNozzleLength)], segments: 10, twoSided: true)
        return b
    }()

    private static func placed(_ src: MeshBuilder, q: simd_quatf, at p: F3) -> MeshBuilder {
        var out = src
        out.positions = src.positions.map { q.act($0) + p }
        out.normals = src.normals.map { q.act($0) }
        return out
    }

    /// Посадочные опоры: 4 ноги до уровня `drop` ниже низа детали.
    static func legs(diameter d: Double, height h: Double, drop: Double) -> [Piece] {
        var b = MeshBuilder()
        let r = Float(d / 2), hf = Float(h)
        let foot = -Float(drop) + 0.04
        for k in 0..<4 {
            let a = Float(k) * .pi / 2 + .pi / 4
            let dir = F3(cos(a), 0, sin(a))
            let top = dir * (r * 0.9) + F3(0, hf * 0.85, 0)
            let ft = dir * (r + 0.9) + F3(0, foot, 0)
            b.beam(top, ft, thickness: 0.11)
            let mid = top + (ft - top) * 0.55
            b.beam(dir * (r * 0.9) + F3(0, 0.02, 0), mid, thickness: 0.07)
            b.box(center: ft + F3(0, -0.02, 0), x: F3(0.22, 0, 0), y: F3(0, 0.03, 0), z: F3(0, 0, 0.22))
        }
        guard let mesh = b.makeMesh(name: "legs") else { return [] }
        return [(mesh, RenderMaterials.shared.metal)]
    }
}
