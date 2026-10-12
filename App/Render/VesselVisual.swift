import OrbitPhysics
import RealityKit
import simd

/// 3D-модель корабля: стек деталей сверху вниз, факелы двигателей, купол парашюта.
/// Корень — нижняя точка стека (`VesselState.position`), ось +Y — нос.
@MainActor
final class VesselVisual {
    let root = Entity()
    private(set) var parts: [PartID] = []
    /// Высота стека и низ каждой детали над низом стека, м.
    private(set) var stackHeight: Double = 0
    private var bottoms: [Double] = []
    /// Низ каждой детали над низом стека, м (для эффектов: сопла двигателей).
    var partBottoms: [Double] { bottoms }
    /// Полупрозрачный внешний ореол факела поверх непрозрачных слоёв (отключается, если роняет рендер).
    static var transparentPlumeGlow = false
    private var plumes: [Int: (entity: Entity, outer: ModelEntity, core: ModelEntity, glow: ModelEntity?)] = [:]
    private var canopy: Entity?
    private var maxDiameter: Double = 1

    /// Радиус ограничивающей сферы вокруг середины стека, м (с куполом — больше).
    private(set) var boundingRadius: Double = 1

    init(parts: [PartID]) {
        rebuild(parts)
    }

    func rebuild(_ newParts: [PartID]) {
        parts = newParts
        for c in Array(root.children) { c.removeFromParent() }
        plumes.removeAll()
        canopy = nil
        stackHeight = newParts.reduce(0) { $0 + $1.spec.height }
        maxDiameter = newParts.reduce(0.5) { max($0, $1.spec.diameter) }
        bottoms = []
        var top = stackHeight
        for id in newParts {
            top -= id.spec.height
            bottoms.append(top)
        }
        for (i, id) in newParts.enumerated() {
            let spec = id.spec
            let holder = Entity()
            holder.position = F3(0, Float(bottoms[i]), 0)
            root.addChild(holder)
            let pieces = spec.kind == .legs
                ? PartModels.pieces(id) + PartModels.legs(diameter: spec.diameter, height: spec.height, drop: bottoms[i])
                : PartModels.pieces(id)
            for p in pieces {
                holder.addChild(ModelEntity(mesh: p.mesh, materials: [p.material]))
            }
            if spec.kind == .engine {
                makePlume(index: i, spec: spec)
            }
            if spec.kind == .chute {
                makeCanopy(top: bottoms[i] + spec.height)
            }
        }
        boundingRadius = stackHeight / 2 + maxDiameter
    }

    private static var plumeMesh: MeshResource?
    private static var canopyPieces: [PartModels.Piece] = []

    private static func sharedPlumeMesh() -> MeshResource? {
        if let m = plumeMesh { return m }
        var b = MeshBuilder()
        // Единичный факел: y от 0 (срез сопла) до −1, радиус среза 1.
        b.lathe([SIMD2(0, -1), SIMD2(0.10, -0.9), SIMD2(0.22, -0.65), SIMD2(0.4, -0.3),
                 SIMD2(0.65, -0.08), SIMD2(0.48, 0)], segments: 24)
        plumeMesh = b.makeMesh(name: "plume")
        return plumeMesh
    }

    private func makePlume(index: Int, spec: PartSpec) {
        guard let mesh = Self.sharedPlumeMesh() else { return }
        let mats = RenderMaterials.shared
        let e = Entity()
        e.position = F3(0, Float(bottoms[index]), 0)
        let outer = ModelEntity(mesh: mesh, materials: [spec.isSolid ? mats.plumeSolid : mats.plumeOuter])
        let core = ModelEntity(mesh: mesh, materials: [mats.plumeCore])
        e.addChild(outer)
        e.addChild(core)
        var glow: ModelEntity?
        if Self.transparentPlumeGlow {
            let g = ModelEntity(mesh: mesh, materials: [mats.plumeGlow])
            e.addChild(g)
            glow = g
        }
        e.isEnabled = false
        root.addChild(e)
        plumes[index] = (e, outer, core, glow)
    }

    private func makeCanopy(top: Double) {
        if Self.canopyPieces.isEmpty {
            let mats = RenderMaterials.shared
            var prof: [SIMD2<Float>] = []
            for i in 0...10 {
                let a = Float(i) / 10 * .pi / 2
                prof.append(SIMD2(8 * cos(a), 14 + 4.5 * sin(a)))
            }
            var a = MeshBuilder(), b = MeshBuilder()
            a.lathe(prof, segments: 16, twoSided: true, segmentFilter: { $0 % 2 == 0 })
            b.lathe(prof, segments: 16, twoSided: true, segmentFilter: { $0 % 2 == 1 })
            var lines = MeshBuilder()
            for k in 0..<8 {
                let ang = Float(k) / 8 * 2 * .pi
                lines.beam(.zero, F3(8 * cos(ang), 14, 8 * sin(ang)), thickness: 0.04)
            }
            let list: [(MeshBuilder, any Material)] = [(a, mats.canopyA), (b, mats.canopyB), (lines, mats.lightGray)]
            for (m, mat) in list {
                if let mesh = m.makeMesh(name: "canopy") { Self.canopyPieces.append((mesh, mat)) }
            }
        }
        let e = Entity()
        e.position = F3(0, Float(top), 0)
        for p in Self.canopyPieces { e.addChild(ModelEntity(mesh: p.mesh, materials: [p.material])) }
        e.isEnabled = false
        root.addChild(e)
        canopy = e
    }

    /// Обновление за кадр: положение (относительно точки отсчёта), ориентация, факелы, купол.
    func update(_ v: VesselState, relativePosition: D3, pressure: Double, time: Double) {
        root.transform = Transform(scale: .one, rotation: quatf(v.attitude.quatd), translation: f3(relativePosition))

        let vac = 1 - clampd(pressure, 0, 1)
        for (i, p) in plumes {
            let on = v.firingEngines.contains(i)
            if p.entity.isEnabled != on { p.entity.isEnabled = on }
            guard on else { continue }
            let spec = parts[i].spec
            let re = spec.diameter / 2 * (spec.isSolid ? 0.62 : 0.92)
            let thr = spec.isSolid ? 1 : clampd(v.throttle, 0, 1)
            let flick = 1 + 0.06 * sin(time * 53 + Double(i)) + 0.04 * sin(time * 97 + 2 * Double(i))
            // Отдельное мерцание ядра: оно «дышит» быстрее оболочки.
            let coreFlick = 1 + 0.09 * sin(time * 71 + 3 * Double(i)) + 0.05 * sin(time * 131 + Double(i))
            let length = spec.diameter * (spec.isSolid ? 5.0 : 1.2 + 4.0 * thr) * (1 + 0.7 * vac) * flick
            let width = re * (1 + 0.9 * vac) * (0.4 + 0.6 * sqrt(thr))
            // Непрозрачные слои: широкая оранжевая оболочка короче, узкое светлое ядро длиннее.
            p.outer.scale = F3(Float(width), Float(length * 0.7), Float(width))
            let coreW = Float(width * 0.55)
            p.core.scale = F3(coreW, Float(length * 0.9 * coreFlick), coreW)
            // Ореол шире и длиннее оболочки; в вакууме расширяется сильнее.
            if let g = p.glow {
                let gw = Float(width * (1.35 + 0.5 * vac))
                g.scale = F3(gw, Float(length * 0.95), gw)
            }
        }

        if let canopy {
            let open = v.chute == .open || v.chute == .deploying
            if canopy.isEnabled != open { canopy.isEnabled = open }
            if open {
                let s = Float(max(0.05, min(1, v.chuteDeploy)))
                canopy.scale = F3(repeating: s)
            }
        }
        boundingRadius = (canopy?.isEnabled ?? false) ? stackHeight + 20 : stackHeight / 2 + maxDiameter
    }
}
