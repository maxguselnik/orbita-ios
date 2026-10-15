import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Кабина за спиной персонажа (`buildCabin` макета): кресло, пульты с экранчиками и тумблерами, кабели,
/// в восторге — иллюминатор с планетой. Туман макета запечён в материалы (цвет к туману по глубине),
/// перспектива фона — сжатием кабины к центру кадра (камера общая и почти ортографическая).
@MainActor
struct CrewCabin {
    let root = Entity()
    /// Лампочки пультов (мигают).
    private(set) var lamps: [Entity] = []

    /// Сжатие фона к центру: глубина кабины ~3 в макете при камере на 9 → ×0.76.
    static let depthScale: Float = 0.76
    /// Центр кадра по высоте (камера макета смотрит в y = −0.05).
    static let centerY: Float = -0.05

    private static let lampColors: [UInt32] = [0x7ce38b, 0xf2a03d, 0x3ec6f0, 0xff5b5b]
    private static let bokehColors: [UInt32] = [0x7ce38b, 0xf2a03d, 0x3ec6f0, 0xfff0d0]
    /// Пульты: x, y, экран (x сдвинуты внутрь ячейки — соседние кабины стоят вплотную).
    private static let panels: [(Float, Float, Int)] = [(-2.3, 1.4, 0), (2.3, 1.4, 1), (-2.35, -0.2, 2),
                                                         (2.35, -0.2, 0), (-2.25, -1.8, 1), (2.25, -1.8, 2)]
    private static let panelScale: Float = 0.8

    init(mood: CrewMood, cellWidth: Float) {
        let a = CrewAssets.shared
        let fogColor = mood.portraitFog
        // Задняя стенка почти целиком в тумане — плоский фон цвета тумана во всю ячейку.
        let back = ModelEntity(mesh: CrewMeshCache.mesh("cabinBack") { CrewGeo.plane } ?? .generatePlane(width: 1, height: 1),
                               materials: [a.material(CrewMat(color: fogColor.mixed(CrewColor(0x222a38), 0.08).hex, unlit: true))])
        back.position = F3(0, 0, -3.7)
        back.scale = F3(cellWidth, 8, 1)
        root.addChild(back)

        let scene = Entity()
        let s = Self.depthScale
        scene.scale = F3(s, s, 1)
        scene.position = F3(0, Self.centerY * (1 - s), 0)
        root.addChild(scene)

        if let mesh = CrewMeshCache.batch("cabin", { Self.staticBatch() }) {
            scene.addChild(ModelEntity(mesh: mesh, materials: Self.materials(mood)))
        }
        if mood == .awe, let mesh = CrewMeshCache.batch("cabinPort", { Self.portBatch() }) {
            scene.addChild(ModelEntity(mesh: mesh, materials: Self.materials(mood)))
        }
        // Лампочки пультов — отдельные сущности (мигают по одной).
        let lampMesh = CrewMeshCache.mesh("sphereLo") { CrewGeo.sphereLo }
        for (i, pnl) in Self.panels.enumerated() {
            for j in 0..<3 {
                guard let lampMesh else { continue }
                let c = CrewColor(Self.lampColors[(i + j) % 4])
                let lamp = ModelEntity(mesh: lampMesh, materials: [a.material(CrewMat(color: Self.fogged(c, 0.77, fogColor).hex, unlit: true))])
                let m = Self.panelMatrix(pnl) * crewMatrix(F3(0.5 + 0.2, 0.3 - Float(j) * 0.3, 0.1 + 0.02))
                lamp.transform = Transform(matrix: m)
                lamp.scale = F3(repeating: 0.035 * Self.panelScale)
                scene.addChild(lamp)
                lamps.append(lamp)
            }
        }
    }

    /// Цвет, ушедший в туман на долю `f` (смесь в линейном пространстве).
    static func fogged(_ c: CrewColor, _ f: Float, _ fog: CrewColor) -> CrewColor {
        CrewColor.from(CrewColor.toSRGB(c.linear * (1 - f) + fog.linear * f))
    }

    /// Освещаемый материал в тумане: цвет × (1 − f) + свечение цветом тумана × f.
    private static func foggedLit(_ c: UInt32, rough: Float, metal: Float = 0, f: Float, fog: CrewColor) -> CrewMat {
        CrewMat(color: CrewColor.from(CrewColor.toSRGB(CrewColor(c).linear * (1 - f))).hex, rough: rough, metal: metal,
                emissive: CrewColor.from(CrewColor.toSRGB(fog.linear * f)).hex, glow: 1)
    }

    private static func materials(_ mood: CrewMood) -> [any Material] {
        let a = CrewAssets.shared
        let fog = mood.portraitFog
        let dim = CrewColor.from(F3(repeating: 1 - 0.79 * 0.85)).hex
        var list: [any Material] = [
            a.material(foggedLit(0x1f2a3e, rough: 0.95, f: 0.7, fog: fog)),
            a.material(foggedLit(0xc4ccd8, rough: 0.28, metal: 0.7, f: 0.72, fog: fog)),
            a.material(CrewMat(color: fogged(CrewColor(0xfff0d0), 0.77, fog).hex, unlit: true)),
            a.material(foggedLit(0x343f53, rough: 0.6, metal: 0.2, f: 0.79, fog: fog)),
            a.material(foggedLit(0x4a5262, rough: 0.4, metal: 0.6, f: 0.79, fog: fog)),
            a.material(foggedLit(0x161a22, rough: 0.7, f: 0.73, fog: fog)),
        ]
        let gray = CrewColor.from(F3(repeating: 1 - 0.6)).hex
        for k in 0..<3 { list.append(a.material(CrewMat(color: gray, tex: "screen\(k)", unlit: true))) }
        for k in 0..<CrewAssets.panelLabels.count { list.append(a.material(CrewMat(color: dim, tex: "panel\(k)", unlit: true))) }
        list.append(a.material(CrewMat(color: fogged(CrewColor(0x02030a), 0.88, fog).hex, unlit: true)))
        list.append(a.material(CrewMat(color: fogged(CrewColor(0x2f6fc8), 0.88, fog).hex, unlit: true)))
        list.append(a.material(CrewMat(color: fogged(CrewColor(0xffffff), 0.88, fog).hex, unlit: true)))
        for c in bokehColors { list.append(a.material(CrewMat(color: c, opacity: 0.35, tex: "spot", unlit: true, alphaTex: true))) }
        return list
    }

    // Номера материалов в `materials`.
    private enum M {
        static let seat = 0, metal = 1, lampBar = 2, panel = 3, darkMetal = 4, cable = 5, screen = 6, label = 9
        static let portDisk = 15, earth = 16, portStars = 17, bokeh = 18
    }

    private static func panelMatrix(_ p: (Float, Float, Int)) -> float4x4 {
        crewMatrix(F3(p.0, p.1, -2.9), simd_quatf(angle: -(p.0 > 0 ? 1 : -1) * 0.38, axis: F3(0, 1, 0)), F3(repeating: panelScale))
    }

    private static func staticBatch() -> MeshBatch {
        var b = MeshBatch()
        let id = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        // Кресло: мягкие подушки, подголовник, валики, поручень, светильник.
        for i in -1...1 {
            b.add(CrewGeo.roundedBox(1.0, 2.6, 0.55, 0.22), crewMatrix(F3(Float(i) * 1.05, -1.0, -2.45)), mat: M.seat)
        }
        b.add(CrewGeo.roundedBox(2.7, 1.0, 0.6, 0.28), crewMatrix(F3(0, 1.0, -2.45)), mat: M.seat)
        for sd: Float in [-1, 1] {
            b.add(CrewGeo.sphereHi, crewMatrix(F3(sd * 1.95, -1.1, -2.1), id, F3(0.38, 1.5, 0.38)), mat: M.seat)
        }
        b.add(CrewGeo.strand([F3(-2.8, 3.0, -2.4), F3(-1.2, 3.25, -2.3), F3(1.2, 3.25, -2.3), F3(2.8, 3.0, -2.4)], 0.07), mat: M.metal)
        b.add(CrewGeo.roundedBox(3.2, 0.16, 0.32, 0.07), crewMatrix(F3(0, 3.6, -2.8)), mat: M.lampBar)
        // Боковые пульты: экранчик, подпись, тумблеры.
        for (i, p) in panels.enumerated() {
            let pm = panelMatrix(p)
            b.add(CrewGeo.roundedBox(1.5, 1.1, 0.18, 0.08), pm, mat: M.panel)
            b.add(CrewGeo.plane, pm * crewMatrix(F3(-0.2, 0.1, 0.095), id, F3(0.72, 0.54, 1)), mat: M.screen + p.2)
            b.add(CrewGeo.plane, pm * crewMatrix(F3(-0.2, -0.36, 0.095), id, F3(0.5, 0.16, 1)), mat: M.label + i)
            for j in 0..<3 {
                let tg = pm * crewMatrix(F3(0.5, 0.3 - Float(j) * 0.3, 0.1))
                b.add(CrewGeo.sphereLo, tg * crewMatrix(.zero, id, F3(0.06, 0.06, 0.03)), mat: M.darkMetal)
                let lever = tg * crewMatrix(.zero, simd_quatf(angle: (i + j) % 2 == 1 ? 0 : .pi, axis: F3(1, 0, 0)))
                b.add(CrewGeo.strand([F3(0, 0, 0), F3(0, 0.07, 0.06), F3(0, 0.1, 0.1)], 0.016, seg: 8, rad: 6), lever, mat: M.metal)
                b.add(CrewGeo.sphereLo, lever * crewMatrix(F3(0, 0.1, 0.1), id, F3(repeating: 0.028)), mat: M.metal)
            }
        }
        for (i, xy) in [(Float(-2.5), Float(-2.8)), (Float(2.4), Float(-2.6))].enumerated() {
            let (x, y) = xy
            let k: Float = i == 1 ? 1 : -1
            b.add(CrewGeo.strand([F3(x, 1.2, -2.8), F3(x - 0.3 * k, 0, -2.4), F3(x + 0.1 * k, -1.4, -2.6), F3(x, y, -2.7)], 0.05),
                  mat: M.cable)
        }
        // Боке: размытые огоньки пультов за спиной.
        for i in 0..<9 {
            let fi = Float(i)
            let sz = 0.35 + Float(i % 3) * 0.2
            b.add(CrewGeo.plane, crewMatrix(F3(sin(fi * 2.3) * 2.4, cos(fi * 1.7) * 1.8 + 0.2, -3.0), id, F3(sz, sz, 1)),
                  mat: M.bokeh + i % 4)
        }
        return b
    }

    private static func portBatch() -> MeshBatch {
        var b = MeshBatch()
        let id = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let port = crewMatrix(F3(0, 2.85, -3.4))
        b.add(CrewGeo.cylinder(1, 1, 1, radial: 24), port * crewMatrix(.zero, simd_quatf(angle: .pi / 2, axis: F3(1, 0, 0)), F3(1.2, 0.05, 1.2)),
              mat: M.portDisk)
        b.add(CrewGeo.rim, port * crewMatrix(F3(0, 0, 0.06), id, F3(1.2, 1.2, 1.4)), mat: M.metal)
        b.add(CrewGeo.circle(1.15, segments: 48, start: .pi * 1.18, length: .pi * 0.64), port * crewMatrix(F3(0, 0, 0.04)), mat: M.earth)
        for i in 0..<16 {
            let fi = Float(i)
            b.add(CrewGeo.sphereLo, port * crewMatrix(F3(sin(fi * 2.4) * 0.95, cos(fi * 1.7) * 0.45 + 0.38, 0.06), id,
                                                      F3(repeating: 0.018 + Float(i % 3) * 0.008)), mat: M.portStars)
        }
        return b
    }
}
