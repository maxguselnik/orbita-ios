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
    /// Поручни и лестницы EVA: оранжевые трубки #F2A03D.
    let handrail = SimpleMaterial(color: UIColor(red: 0.949, green: 0.627, blue: 0.239, alpha: 1), roughness: 0.45, isMetallic: true)
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

    private static var shroudCache: [String: [Piece]] = [:]

    /// Переходный кожух разделителя: полый усечённый конус от `base` (верх разделителя) вверх на `height`;
    /// диаметр снизу/сверху — `bottomDiameter`/`topDiameter`. Двусторонний (сопло внутри не просвечивает),
    /// торцы открыты, по низу тёмная полоса. Оси — детали, низ детали — y = 0.
    static func shroud(base: Double, height: Double, bottomDiameter: Double, topDiameter: Double) -> [Piece] {
        let key = "\(base)|\(height)|\(bottomDiameter)|\(topDiameter)"
        if let c = shroudCache[key] { return c }
        let mats = RenderMaterials.shared
        let y0 = Float(base), y1 = Float(base + height)
        let r0 = Float(bottomDiameter / 2), r1 = Float(topDiameter / 2)
        var cone = MeshBuilder()
        cone.lathe([SIMD2(r0, y0), SIMD2(r1, y1)], segments: seg, twoSided: true)
        let bandH = min(Float(height) * 0.12, 0.15)
        let rb = r0 + (r1 - r0) * (bandH / max(Float(height), 1e-3))
        var band = MeshBuilder()
        band.lathe([SIMD2(r0 * 1.01, y0), SIMD2(rb * 1.01, y0 + bandH)], segments: seg, twoSided: true)
        var out: [Piece] = []
        if let m = cone.makeMesh(name: "shroud") { out.append((m, mats.darkGray)) }
        if let m = band.makeMesh(name: "shroudBand") { out.append((m, mats.black)) }
        shroudCache[key] = out
        return out
    }

    /// Ширина (по касательной) плиты бокового разделителя, м.
    static let radialPlateWidth: Float = 0.45

    /// Модель строится в осях «наружу — +X» и поворачивается вокруг Y: только у деталей с направлением.
    static func rotatesWithOutward(_ id: PartID) -> Bool { id == .fin || id == .decouplerRadial }

    /// Поворот детали: оси детали → оси корабля. Единственное место, где читается ориентация детали.
    /// Поворот модели детали: `orientation` из физики (оси детали → оси корабля) и, у боковых, азимут вокруг
    /// собственной оси, чтобы локальный +X модели смотрел по `outward`.
    static func placementRotation(_ p: PartPlacement) -> simd_quatf {
        quatf(p.geometryOrientation.quatd)
    }

    /// Угол поворота вокруг +Y, переводящий +X в `outward` (в RealityKit поворот на θ уводит +X в (cosθ, 0, −sinθ)).
    static func yaw(outward o: Vec3) -> Float {
        guard o.x * o.x + o.z * o.z > 1e-9 else { return 0 }
        return Float(-atan2(o.z, o.x))
    }

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

    // MARK: Кабины и люки (EVA 6.2)

    /// Высота люка кабины в долях высоты детали (совпадает с физикой: середина, у ЛК-2 — 35 %).
    static func hatchFraction(_ id: PartID) -> Float { id == .lk2 ? 0.35 : 0.5 }

    /// Радиус корпуса кабины на высоте `y` (линия от (r, 0.08h) к (top, 0.9h), как в `Ship.hatchRadius`).
    private static func podHull(r: Float, top: Float, h: Float, y: Float) -> Float {
        r - (r - top) * (y - 0.08 * h) / (0.82 * h)
    }

    /// Нормаль люка кабины в осях детали: +Z, наклонённая вверх по конусу корпуса (повторяет наклон корпуса).
    static func hatchNormal(_ id: PartID) -> SIMD3<Double> {
        let spec = id.spec
        let h = Float(spec.height), r = Float(spec.diameter / 2)
        let top = Float(0.3) * min(Float(spec.diameter), 1.25)
        let s = Double(-(r - top) / (0.82 * h))
        let n = SIMD3<Double>(0, -s, 1)
        return n / (n * n).sum().squareRoot()
    }

    private static func podModel(_ id: PartID, h: Float, d: Float, r: Float) -> [(MeshBuilder, any Material)] {
        let mats = RenderMaterials.shared
        let top = Float(0.3) * min(d, 1.25)
        let hull = { (y: Float) in podHull(r: r, top: top, h: h, y: y) }
        var out: [(MeshBuilder, any Material)] = []
        if id == .lk2 {
            // ЛК-2: низкая широкая кабина, юбка-расширение книзу, золотая «фольга» снизу, стыковочный воротник сверху.
            let split = 0.5 * h
            out.append((lathe([SIMD2(0, 0), SIMD2(r * 0.9, 0), SIMD2(r * 1.06, 0.035 * h), SIMD2(r * 1.02, 0.08 * h),
                               SIMD2(r, 0.08 * h)]), mats.darkMetal))
            out.append((lathe([SIMD2(r, 0.08 * h), SIMD2(hull(split), split)]), mats.gold))
            out.append((lathe([SIMD2(hull(split), split), SIMD2(top, 0.9 * h), SIMD2(top * 0.8, 0.94 * h),
                               SIMD2(top * 0.8, h * 0.99), SIMD2(0, h * 0.99)]), mats.white))
            out.append((lathe(cyl(hull(split) * 1.012, split - 0.02 * h, split + 0.02 * h, caps: false)), mats.darkGray))
            out.append((lathe(cyl(top * 0.55, h * 0.99, h, caps: true)), mats.darkMetal))
        } else {
            let shield = lathe([SIMD2(0, 0), SIMD2(r * 0.93, 0), SIMD2(r, 0.05 * h), SIMD2(r, 0.08 * h)])
            let body = lathe([SIMD2(r, 0.08 * h), SIMD2(r * 0.98, 0.12 * h), SIMD2(top, 0.9 * h),
                              SIMD2(top, h), SIMD2(0, h)])
            let band = lathe(cyl(r * 0.995 - (r - top) * 0.22, 0.24 * h, 0.3 * h, caps: false))
            out += [(shield, mats.shield), (body, mats.lightGray), (band, mats.darkGray)]
        }
        // Иллюминаторы по бокам (±X); на спине (+Z) — люк.
        var win = MeshBuilder()
        let wy = (id == .lk2 ? 0.66 : 0.5) * h
        let wr = hull(wy)
        let ws = min(d, 1.25)
        for sx: Float in [-1, 1] {
            win.box(center: F3(sx * wr * 0.985, wy, 0.12 * ws), x: F3(0.025, 0, 0), y: F3(0, 0.08 * h, 0), z: F3(0, 0, 0.09 * ws))
        }
        out.append((win, mats.window))

        // Люк: рамка, дверца, ручка; поручни-рамка вокруг (оранжевые трубки на стойках).
        let y = hatchFraction(id) * h
        let R = hull(y)
        let s = -(r - top) / (0.82 * h)
        let u = simd_normalize(F3(0, 1, s)), n = simd_normalize(F3(0, -s, 1)), sd = F3(1, 0, 0)
        let c = F3(0, y, R)
        let hw = 0.16 * ws, hh = min(0.28, 0.2 * h)
        var frame = MeshBuilder(), door = MeshBuilder(), rail = MeshBuilder()
        let fm: Float = 0.03
        frame.box(center: c + n * 0.004, x: sd * (hw + fm), y: u * (hh + fm), z: n * 0.012)
        door.box(center: c + n * 0.014, x: sd * hw, y: u * hh, z: n * 0.008)
        rail.box(center: c + n * 0.03 + sd * (hw * 0.55), x: sd * 0.012, y: u * 0.05, z: n * 0.012)
        let m: Float = 0.09, lift: Float = 0.07, t: Float = 0.028
        let ex = hw + fm + m, ey = hh + fm + m
        func pt(_ a: Float, _ b: Float, _ k: Float = lift) -> F3 { c + sd * a + u * b + n * k }
        let corners = [(-ex, -ey), (ex, -ey), (ex, ey), (-ex, ey)]
        for i in 0..<4 {
            let p = corners[i], q = corners[(i + 1) % 4]
            rail.beam(pt(p.0, p.1), pt(q.0, q.1), thickness: t)
            rail.beam(pt(p.0, p.1, 0), pt(p.0, p.1), thickness: 0.02)
        }
        out.append((frame, mats.darkMetal))
        out.append((door, mats.black))
        out.append((rail, mats.handrail))
        return out
    }

    private static func build(_ id: PartID) -> [(MeshBuilder, any Material)] {
        let mats = RenderMaterials.shared
        let spec = id.spec
        let h = Float(spec.height), d = Float(spec.diameter), r = d / 2
        switch spec.kind {
        case .pod:
            return podModel(id, h: h, d: d, r: r)
        case .probe:
            let body = lathe([SIMD2(0, 0), SIMD2(r, 0), SIMD2(r, 0.55 * h), SIMD2(r * 0.6, h), SIMD2(0, h)])
            let ring = lathe(cyl(r * 1.01, 0.1 * h, 0.2 * h, caps: false))
            return [(body, mats.gold), (ring, mats.darkGray)]
        case .chute:
            let base = lathe(cyl(r, 0, 0.3 * h))
            let cap = lathe([SIMD2(r, 0.3 * h), SIMD2(r, 0.55 * h), SIMD2(r * 0.75, h), SIMD2(0, h)])
            return [(base, mats.darkGray), (cap, mats.red)]
        case .decoupler where id == .decouplerRadial:
            // Плита-кронштейн: модель в осях «наружу — +X», центр по X в середине плиты, низ по Y — 0.
            let w = radialPlateWidth
            var plate = MeshBuilder()
            plate.box(center: F3(0, h / 2, 0), x: F3(d / 2, 0, 0), y: F3(0, h / 2, 0), z: F3(0, 0, w / 2))
            var band = MeshBuilder()
            band.box(center: F3(0, h / 2, 0), x: F3(d / 2 * 1.04, 0, 0), y: F3(0, 0.14 * h, 0), z: F3(0, 0, w / 2 * 1.04))
            var bolts = MeshBuilder()
            for sy: Float in [0.18, 0.82] {
                bolts.box(center: F3(0, sy * h, 0), x: F3(d / 2 * 1.06, 0, 0), y: F3(0, 0.05 * h, 0), z: F3(0, 0, 0.05 * w))
            }
            return [(plate, mats.darkGray), (band, mats.orange), (bolts, mats.metal)]
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
        case .heatShield:
            // Низкая выпуклая чаша днищем вниз: абляционное покрытие, кромка-кольцо по краю.
            var prof: [SIMD2<Float>] = []
            for i in 0...8 {
                let rho = Float(i) / 8 * 0.97
                prof.append(SIMD2(r * rho, 0.55 * h * pow(rho, 2.2)))
            }
            prof += [SIMD2(r, 0.55 * h), SIMD2(r, h), SIMD2(0, h)]
            let dish = lathe(prof)
            let rim = lathe(cyl(r * 1.012, 0.58 * h, 0.9 * h, caps: false))
            let edge = lathe(cyl(r * 1.006, 0.9 * h, h, caps: false))
            return [(dish, mats.shield), (rim, mats.orange), (edge, mats.darkGray)]
        case .fairing:
            // Оживальный нос: цилиндрический поясок у основания и выпуклый контур к острой вершине.
            var prof: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(r, 0), SIMD2(r, 0.18 * h)]
            for i in 1...10 {
                let t = Float(i) / 10
                prof.append(SIMD2(r * (1 - t) * (1 + 0.9 * t), 0.18 * h + 0.82 * h * t))
            }
            let shell = lathe(prof)
            let band = lathe(cyl(r * 1.012, 0.02 * h, 0.09 * h, caps: false))
            let seam = lathe(cyl(r * 1.006, 0.17 * h, 0.2 * h, caps: false))
            return [(shell, mats.white), (band, mats.orange), (seam, mats.darkGray)]
        case .fin:
            // Трапециевидное перо: корень (x = −d/2) на всю хорду h, кромка (x = +d/2) короче и сдвинута вниз.
            let poly: [SIMD2<Float>] = [SIMD2(-r, 0), SIMD2(-r, h), SIMD2(r, 0.42 * h), SIMD2(r, 0)]
            var fin = MeshBuilder()
            fin.prism(poly, halfThickness: 0.025)
            return [(fin, mats.orange)]
        case .instrument:
            // Прибор сбоку: корпус у борта (x = −d/2…0), снаружи — датчик своего вида; низ по Y — 0.
            var housing = MeshBuilder()
            housing.box(center: F3(-r / 2, h / 2, 0), x: F3(r / 2, 0, 0), y: F3(0, h / 2, 0), z: F3(0, 0, 0.5 * r + 0.03))
            var sensor = MeshBuilder()
            switch id {
            case .thermometer:
                // Тонкий щуп с красной колбой на конце.
                sensor.box(center: F3(r * 0.45, h * 0.5, 0), x: F3(r * 0.45, 0, 0), y: F3(0, 0.012, 0), z: F3(0, 0, 0.012))
                var bulb = MeshBuilder()
                bulb.box(center: F3(r * 0.92, h * 0.5, 0), x: F3(0.025, 0, 0), y: F3(0, 0.025, 0), z: F3(0, 0, 0.025))
                return [(housing, mats.white), (sensor, mats.metal), (bulb, mats.red)]
            case .barometer:
                // Круглая шкала наружу.
                sensor.box(center: F3(r * 0.08, h * 0.5, 0), x: F3(r * 0.08, 0, 0), y: F3(0, h * 0.32, 0), z: F3(0, 0, h * 0.32))
                return [(housing, mats.lightGray), (sensor, mats.gold)]
            default:
                // Гравиметр: цилиндрический датчик на кронштейне.
                sensor.box(center: F3(r * 0.4, h * 0.55, 0), x: F3(r * 0.4, 0, 0), y: F3(0, h * 0.3, 0), z: F3(0, 0, r * 0.4))
                return [(housing, mats.darkGray), (sensor, mats.gold)]
            }
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
        for foot in LandingLegGeometry.feet(diameter: d, drop: drop) {
            let dir = simd_normalize(F3(Float(foot.x), 0, Float(foot.z)))
            let top = dir * (r * 0.9) + F3(0, hf * 0.85, 0)
            let ft = f3(foot.d3)
            b.beam(top, ft, thickness: 0.11)
            let mid = top + (ft - top) * 0.55
            b.beam(dir * (r * 0.9) + F3(0, 0.02, 0), mid, thickness: 0.07)
            b.box(center: ft + F3(0, Float(LandingLegGeometry.padCenterOffset), 0),
                  x: F3(Float(LandingLegGeometry.padHalfWidth), 0, 0),
                  y: F3(0, Float(LandingLegGeometry.padHalfHeight), 0),
                  z: F3(0, 0, Float(LandingLegGeometry.padHalfWidth)))
        }
        guard let mesh = b.makeMesh(name: "legs") else { return [] }
        return [(mesh, RenderMaterials.shared.metal)]
    }
}
