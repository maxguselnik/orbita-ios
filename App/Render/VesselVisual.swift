import OrbitPhysics
import RealityKit
import simd
import UIKit

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
    /// Мягкий факел: конус с градиентной прозрачностью по длине и светлым ядром. При `false` (или пока
    /// текстуры не готовы) рисуются прежние непрозрачные слои — запасной путь на случай сбоев рендера.
    static var softPlume = true
    private var plumesSoft = false
    private var plumes: [Int: (entity: Entity, outer: ModelEntity, core: ModelEntity, glow: ModelEntity?)] = [:]
    private var canopy: Entity?
    /// Струйки РСУ: по 20 конусов на блок (4 выступа × 5 слотов, индекс `k * 5 + slot`).
    static var rcsPuffsEnabled = true
    private var rcsPuffs: [(partIndex: Int, jets: [ModelEntity])] = []
    private var rcsLit = false
    private var maxDiameter: Double = 1

    /// Радиус ограничивающей сферы вокруг середины стека, м (с куполом — больше).
    private(set) var boundingRadius: Double = 1

    init(parts: [PartID]) {
        SoftTextures.shared.start()
        rebuild(parts)
    }

    func rebuild(_ newParts: [PartID]) {
        parts = newParts
        for c in Array(root.children) { c.removeFromParent() }
        plumes.removeAll()
        rcsPuffs.removeAll()
        rcsLit = false
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
            if spec.kind == .rcs, Self.rcsPuffsEnabled {
                makeRCSPuffs(index: i)
            }
            if spec.kind == .chute {
                makeCanopy(top: bottoms[i] + spec.height)
            }
        }
        boundingRadius = stackHeight / 2 + maxDiameter
    }

    private static var plumeMesh: MeshResource?
    private static var canopyPieces: [PartModels.Piece] = []
    private static var softOuterMesh: MeshResource?
    private static var softCoreMesh: MeshResource?
    private static var softMaterials: (outer: UnlitMaterial, solid: UnlitMaterial, core: UnlitMaterial)?

    private static func sharedPlumeMesh() -> MeshResource? {
        if let m = plumeMesh { return m }
        var b = MeshBuilder()
        // Единичный факел: y от 0 (срез сопла) до −1, радиус среза 1.
        b.lathe([SIMD2(0, -1), SIMD2(0.10, -0.9), SIMD2(0.22, -0.65), SIMD2(0.4, -0.3),
                 SIMD2(0.65, -0.08), SIMD2(0.48, 0)], segments: 24)
        plumeMesh = b.makeMesh(name: "plume")
        return plumeMesh
    }

    /// Мягкие меши и материалы факела; `nil`, пока текстуры не готовы или режим выключен.
    private static func softPlumeKit() -> (outer: MeshResource, core: MeshResource,
                                           mats: (outer: UnlitMaterial, solid: UnlitMaterial, core: UnlitMaterial))? {
        let t = SoftTextures.shared
        guard softPlume, t.isReady, let tex = t.plumeOuter, let coreTex = t.plumeCore else { return nil }
        if softOuterMesh == nil {
            // Профиль от сопла (UV.x = 0) к концу (1): расширяющийся конус, закруглённый кончик.
            softOuterMesh = SoftMeshes.axialLathe(
                [SIMD2(0.55, 0), SIMD2(0.80, -0.10), SIMD2(0.78, -0.32), SIMD2(0.58, -0.58),
                 SIMD2(0.32, -0.82), SIMD2(0.0, -1.0)], segments: 20, name: "plumeSoft")
            softCoreMesh = SoftMeshes.axialLathe(
                [SIMD2(0.45, 0), SIMD2(0.62, -0.12), SIMD2(0.55, -0.4), SIMD2(0.32, -0.7),
                 SIMD2(0.0, -1.0)], segments: 16, name: "plumeCoreSoft")
        }
        if softMaterials == nil {
            softMaterials = (
                SoftTextures.material(tex, tint: .white, opacity: 0.9),
                SoftTextures.material(tex, tint: UIColor(red: 1.0, green: 0.95, blue: 0.78, alpha: 1), opacity: 0.95),
                SoftTextures.material(coreTex, tint: .white, opacity: 1.0))
        }
        guard let o = softOuterMesh, let c = softCoreMesh, let m = softMaterials else { return nil }
        return (o, c, m)
    }

    private func makePlume(index: Int, spec: PartSpec) {
        let kit = Self.softPlumeKit()
        guard let mesh = kit?.outer ?? Self.sharedPlumeMesh() else { return }
        let mats = RenderMaterials.shared
        let e = Entity()
        e.position = F3(0, Float(bottoms[index]), 0)
        let outer: ModelEntity
        let core: ModelEntity
        if let kit {
            outer = ModelEntity(mesh: kit.outer, materials: [spec.isSolid ? kit.mats.solid : kit.mats.outer])
            core = ModelEntity(mesh: kit.core, materials: [kit.mats.core])
        } else {
            outer = ModelEntity(mesh: mesh, materials: [spec.isSolid ? mats.plumeSolid : mats.plumeOuter])
            core = ModelEntity(mesh: mesh, materials: [mats.plumeCore])
        }
        e.addChild(outer)
        e.addChild(core)
        var glow: ModelEntity?
        if kit == nil, Self.transparentPlumeGlow {
            let g = ModelEntity(mesh: mesh, materials: [mats.plumeGlow])
            e.addChild(g)
            glow = g
        }
        plumesSoft = kit != nil
        e.isEnabled = false
        root.addChild(e)
        plumes[index] = (e, outer, core, glow)
    }

    private static var rcsPuffMesh: MeshResource?
    private static var rcsPuffMaterial: UnlitMaterial?

    private func makeRCSPuffs(index: Int) {
        if Self.rcsPuffMesh == nil {
            var b = MeshBuilder()
            // Единичная струйка: от сопла (y = 0) расширяется к y = 1, радиус до 1.
            b.lathe([SIMD2(0.35, 0), SIMD2(0.7, 0.3), SIMD2(1.0, 0.65), SIMD2(0, 1)], segments: 10)
            Self.rcsPuffMesh = b.makeMesh(name: "rcsPuff")
        }
        if Self.rcsPuffMaterial == nil {
            var m = UnlitMaterial(color: UIColor(white: 0.96, alpha: 1))
            m.blending = .transparent(opacity: .init(floatLiteral: 0.55))
            Self.rcsPuffMaterial = m
        }
        guard let mesh = Self.rcsPuffMesh, let mat = Self.rcsPuffMaterial else { return }
        let holder = Entity()
        holder.position = F3(0, Float(bottoms[index]), 0)
        var jets: [ModelEntity] = []
        for k in 0..<4 {
            for slot in 0..<5 {
                let jet = ModelEntity(mesh: mesh, materials: [mat])
                jet.position = PartModels.rcsExhaustOrigin(block: k, slot: slot)
                jet.orientation = PartModels.rcsAlign(PartModels.rcsExhaustDir(block: k, slot: slot))
                jet.isEnabled = false
                holder.addChild(jet)
                jets.append(jet)
            }
        }
        root.addChild(holder)
        rcsPuffs.append((index, jets))
    }

    /// Струйки РСУ по команде корабля: поступательная (a) и поворотная (rot: x — тангаж, y — крен, z — рыскание).
    private func updateRCS(_ v: VesselState, time: Double) {
        let tr = v.rcsTranslation, rot = v.rcsRotation
        let peak = max(abs(tr.x), abs(tr.y), abs(tr.z), abs(rot.x), abs(rot.y), abs(rot.z))
        guard peak > 0.02 else {
            if rcsLit {
                for set in rcsPuffs { for j in set.jets where j.isEnabled { j.isEnabled = false } }
                rcsLit = false
            }
            return
        }
        rcsLit = true
        for set in rcsPuffs {
            for k in 0..<4 {
                let rx = Double(PartModels.rcsRadial[k].x), rz = Double(PartModels.rcsRadial[k].z)
                // Знак s > 0 — выхлоп вниз: тяга вперёд (+Y), тангаж и рыскание дают разные стороны блоков.
                let s = tr.y - rz * rot.x + rx * rot.z
                let values: [Double] = [
                    max(-s, 0),
                    max(s, 0),
                    max(-rx * tr.x, 0) + max(-rz * tr.z, 0),
                    max(-rot.y, 0),
                    max(rot.y, 0),
                ]
                for slot in 0..<5 {
                    let jet = set.jets[k * 5 + slot]
                    let val = clampd(values[slot], 0, 1)
                    let on = val > 0.03
                    if jet.isEnabled != on { jet.isEnabled = on }
                    guard on else { continue }
                    let flick = 1 + 0.22 * sin(time * 91 + Double(k * 5 + slot) * 1.7 + Double(set.partIndex))
                    let length = (0.25 + 0.95 * val) * flick
                    let width = 0.05 * (0.6 + 0.4 * val)
                    jet.scale = F3(Float(width), Float(length), Float(width))
                }
            }
        }
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

        // Текстуры факела дозагрузились (или режим переключили): пересобрать на мягкий вариант.
        if Self.softPlume != plumesSoft, !plumes.isEmpty, Self.softPlumeKit() != nil || plumesSoft {
            rebuild(parts)
        }
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
            // Мягкий факел: конус длиннее (конец прозрачный), ядро узкое и яркое.
            let outerLen = length * (plumesSoft ? 1.15 : 0.7)
            let coreLen = length * (plumesSoft ? 0.7 : 0.9) * coreFlick
            p.outer.scale = F3(Float(width), Float(outerLen), Float(width))
            let coreW = Float(width * (plumesSoft ? 0.5 : 0.55))
            p.core.scale = F3(coreW, Float(coreLen), coreW)
            // Ореол шире и длиннее оболочки; в вакууме расширяется сильнее.
            if let g = p.glow {
                let gw = Float(width * (1.35 + 0.5 * vac))
                g.scale = F3(gw, Float(length * 0.95), gw)
            }
        }

        if Self.rcsPuffsEnabled, !rcsPuffs.isEmpty {
            updateRCS(v, time: time)
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
