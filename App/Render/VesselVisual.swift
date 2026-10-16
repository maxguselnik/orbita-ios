import OrbitPhysics
import RealityKit
import simd
import UIKit

/// 3D-модель корабля: детали по раскладке (`VesselState.layout`), факелы двигателей, купол парашюта.
/// Корень — нижняя точка корабля на оси корня (`VesselState.position`), ось +Y — нос.
@MainActor
final class VesselVisual {
    let root = Entity()
    private(set) var parts: [PartID] = []
    /// Раскладка деталей, по которой построена модель (для старого стека — собранная из `parts`).
    private(set) var layout: [PartPlacement] = []
    /// Размер раскладки, пришедшей снаружи (0 — не было; по нему SceneRenderer узнаёт о пересборке).
    private(set) var sourceLayoutCount = 0
    /// Высота корабля (верх самой высокой детали над самой нижней точкой), м.
    private(set) var stackHeight: Double = 0
    /// Середина габарита по высоте над самой нижней точкой, м.
    private(set) var centerY: Double = 0
    /// Наибольший вынос деталей от оси корня с учётом их размера, м (ширина корабля = 2 ×).
    private(set) var halfWidth: Double = 0.5
    /// Центр габарита в плоскости XZ (оси корабля), м.
    private(set) var centerXZ = SIMD2<Double>(0, 0)
    /// Срез сопел двигателей в осях корабля, м: индекс детали → точка (для дыма и пыли у сопел).
    private(set) var nozzlePositions: [Int: D3] = [:]
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
    // Лестницы EVA: общий корень (переживает пересборку), пересобираются при смене набора лестниц.
    private let ladderRoot = Entity()
    private var ladderBuilt: [EVALadder] = []

    // Нагрев деталей: ступенчатый уровень свечения (0 — холодная) и кэш материалов по уровням.
    private static let heatSteps = 8
    private static let heatStart = 0.4
    private var heatLevels: [Int] = []
    private static var heatMaterials: [UnlitMaterial] = []
    /// Последний известный нагрев деталей (по нему при разрушении ищется самая горячая из одноимённых).
    private var lastHeat: [Double] = []
    // Вспышки разрушения деталей: общий корень (переживает пересборку), ожидающие и идущие.
    private let flashRoot = Entity()
    private var pendingFlashes: [(position: F3, size: Float)] = []
    private var flashes: [(entity: ModelEntity, start: Double, size: Float)] = []
    private static var flashMesh: MeshResource?
    private static var flashMaterial: UnlitMaterial?
    private static let flashLife = 0.6
    /// Меши каждой детали (для призрака) и применённый к детали призрак: nil — обычный вид.
    private var holders: [[ModelEntity]] = []
    private var ghostApplied: [Int: Bool] = [:]
    private var originalMaterials: [ObjectIdentifier: [any Material]] = [:]
    private static var ghostMaterials: (valid: UnlitMaterial, invalid: UnlitMaterial)?

    /// Полупрозрачный материал призрака: зелёный (можно) или красный (нельзя).
    static func ghostMaterial(valid: Bool) -> UnlitMaterial {
        if ghostMaterials == nil {
            func make(_ c: UIColor) -> UnlitMaterial {
                var m = UnlitMaterial(color: c)
                m.blending = .transparent(opacity: .init(floatLiteral: 0.5))
                return m
            }
            ghostMaterials = (make(UIColor(red: 0.25, green: 0.9, blue: 0.4, alpha: 1)),
                              make(UIColor(red: 0.95, green: 0.25, blue: 0.2, alpha: 1)))
        }
        guard let g = ghostMaterials else { return UnlitMaterial() }
        return valid ? g.valid : g.invalid
    }

    /// Цвет свечения для уровня 1…8: тёмно-красный → оранжевый → бело-жёлтый.
    private static func heatMaterial(level: Int) -> UnlitMaterial {
        if heatMaterials.isEmpty {
            for l in 1...heatSteps {
                let t = Float(l - 1) / Float(heatSteps - 1)
                let c: (Float, Float, Float)
                if t < 0.5 {
                    let k = t / 0.5
                    c = (0.35 + 0.65 * k, 0.04 + 0.41 * k, 0.02 + 0.06 * k)
                } else {
                    let k = (t - 0.5) / 0.5
                    c = (1.0, 0.45 + 0.5 * k, 0.08 + 0.62 * k)
                }
                heatMaterials.append(UnlitMaterial(color: UIColor(red: CGFloat(c.0), green: CGFloat(c.1),
                                                                  blue: CGFloat(c.2), alpha: 1)))
            }
        }
        return heatMaterials[min(max(level, 1), heatSteps) - 1]
    }

    /// Свечение деталей по `partHeat`: материал меняется только при смене уровня-ступеньки.
    private func updateHeat(_ heat: [Double]) {
        lastHeat = heat
        let usable = heat.count == holders.count
        if heatLevels.count != holders.count { heatLevels = Array(repeating: 0, count: holders.count) }
        for i in holders.indices {
            var level = 0
            if usable, heat[i] > Self.heatStart {
                let t = min(1, (heat[i] - Self.heatStart) / (1 - Self.heatStart))
                level = max(1, Int((t * Double(Self.heatSteps)).rounded(.up)))
            }
            guard heatLevels[i] != level, ghostApplied[i] == nil else { continue }
            heatLevels[i] = level
            for m in holders[i] {
                let key = ObjectIdentifier(m)
                if level > 0 {
                    if originalMaterials[key] == nil { originalMaterials[key] = m.model?.materials ?? [] }
                    m.model?.materials = [Self.heatMaterial(level: level)]
                } else if let orig = originalMaterials[key] {
                    m.model?.materials = orig
                }
            }
        }
    }

    private func clearLadders() {
        for c in Array(ladderRoot.children) { c.removeFromParent() }
        ladderBuilt = []
    }

    /// Лестницы: две рейки, ступени через ~0.3 м, площадка-ступенька у низа. Вызывается только при смене набора.
    private func buildLadders(_ ladders: [EVALadder]) {
        clearLadders()
        ladderBuilt = ladders
        var b = MeshBuilder()
        for l in ladders {
            let bot = F3(Float(l.bottom.x), Float(l.bottom.y), Float(l.bottom.z))
            let top = F3(Float(l.top.x), Float(l.top.y), Float(l.top.z))
            let axis = top - bot
            let len = simd_length(axis)
            guard len > 0.2 else { continue }
            let up = axis / len
            // Наружу — горизонтальное направление от оси корабля к лестнице (запасной — +Z).
            var n = F3(top.x, 0, top.z)
            if simd_length(n) < 0.05 { n = F3(0, 0, 1) }
            n = simd_normalize(n - up * simd_dot(n, up))
            let side = simd_normalize(simd_cross(up, n))
            let half: Float = 0.22
            b.beam(bot + side * half, top + side * half, thickness: 0.045)
            b.beam(bot - side * half, top - side * half, thickness: 0.045)
            var y: Float = 0.3
            while y < len - 0.05 {
                b.beam(bot + up * y + side * half, bot + up * y - side * half, thickness: 0.035)
                y += 0.3
            }
            // Верхние кронштейны к корпусу и площадка у низа.
            for sg: Float in [-1, 1] {
                b.beam(top + side * (sg * half), top + side * (sg * half) - n * 0.12, thickness: 0.035)
            }
            b.box(center: bot + up * 0.16 + n * 0.14, x: side * (half + 0.06), y: n * 0.15, z: up * 0.015)
        }
        guard let mesh = b.makeMesh(name: "ladders") else { return }
        ladderRoot.addChild(ModelEntity(mesh: mesh, materials: [RenderMaterials.shared.handrail]))
    }

    /// Деталь `id` разрушена: вспышка на месте самой горячей из одноимённых (вызывать до пересборки).
    func flash(part id: PartID) {
        func heat(_ i: Int) -> Double { i < lastHeat.count ? lastHeat[i] : 0 }
        let best = parts.indices.filter { parts[$0] == id }.max { heat($0) < heat($1) }
        guard let i = best, layout.indices.contains(i) else { return }
        let p = layout[i]
        pendingFlashes.append((F3(Float(p.center.x), Float(p.center.y), Float(p.center.z)),
                               Float(max(p.diameter, p.height) * 0.9)))
    }

    private func updateFlashes(time: Double) {
        if !pendingFlashes.isEmpty {
            if Self.flashMesh == nil { Self.flashMesh = MeshResource.generateSphere(radius: 1) }
            if Self.flashMaterial == nil { Self.flashMaterial = UnlitMaterial(color: UIColor(red: 1, green: 0.8, blue: 0.4, alpha: 1)) }
            if let mesh = Self.flashMesh, let mat = Self.flashMaterial {
                for f in pendingFlashes {
                    let e = ModelEntity(mesh: mesh, materials: [mat])
                    e.position = f.position
                    e.scale = .zero
                    flashRoot.addChild(e)
                    flashes.append((e, time, f.size))
                }
            }
            pendingFlashes.removeAll()
        }
        guard !flashes.isEmpty else { return }
        var alive: [(entity: ModelEntity, start: Double, size: Float)] = []
        for f in flashes {
            let t = (time - f.start) / Self.flashLife
            if t >= 1 || t < 0 {
                f.entity.removeFromParent()
                continue
            }
            // Быстро вспыхивает и сжимается до нуля.
            let k = Float(t < 0.25 ? t / 0.25 : 1 - (t - 0.25) / 0.75)
            f.entity.scale = F3(repeating: f.size * (0.4 + 0.9 * Float(t)) * max(k, 0))
            alive.append(f)
        }
        flashes = alive
    }

    /// Детали с индексами `indices` рисуются призраком (`valid` — цвет); остальные — обычно. Меняются только отличия.
    func setGhost(_ indices: Set<Int>, valid: Bool) {
        for i in holders.indices {
            let want: Bool? = indices.contains(i) ? valid : nil
            guard ghostApplied[i] != want else { continue }
            ghostApplied[i] = want
            for m in holders[i] {
                let key = ObjectIdentifier(m)
                if let want {
                    if originalMaterials[key] == nil { originalMaterials[key] = m.model?.materials ?? [] }
                    m.model?.materials = [Self.ghostMaterial(valid: want)]
                } else if let orig = originalMaterials[key] {
                    m.model?.materials = orig
                }
            }
        }
    }

    /// Радиус ограничивающей сферы вокруг середины габарита, м (с куполом — больше).
    private(set) var boundingRadius: Double = 1

    init(parts: [PartID], layout: [PartPlacement] = []) {
        SoftTextures.shared.start()
        root.addChild(flashRoot)
        root.addChild(ladderRoot)
        rebuild(parts: parts, layout: layout)
    }

    /// Раскладка старого стека: детали сверху вниз на оси, вплотную.
    static func stackLayout(_ parts: [PartID]) -> [PartPlacement] {
        var top = parts.reduce(0) { $0 + $1.spec.height }
        return parts.map { id in
            let spec = id.spec
            top -= spec.height
            return PartPlacement(center: Vec3(0, top + spec.height / 2, 0), height: spec.height, diameter: spec.diameter)
        }
    }

    /// Пересборка по `parts` и раскладке `newLayout`; если размеры не совпали — прежний стек сверху вниз.
    func rebuild(parts newParts: [PartID], layout newLayout: [PartPlacement]) {
        parts = newParts
        sourceLayoutCount = newLayout.count
        let lay = newLayout.count == newParts.count ? newLayout : Self.stackLayout(newParts)
        layout = lay
        for c in Array(root.children) where c !== flashRoot && c !== ladderRoot { c.removeFromParent() }
        clearLadders()
        heatLevels.removeAll()
        plumes.removeAll()
        rcsPuffs.removeAll()
        nozzlePositions.removeAll()
        originalMaterials.removeAll()
        rcsLit = false
        canopy = nil

        let low = lay.map(\.lowest).min() ?? 0
        let high = lay.map { $0.top + ($0.shroud?.height ?? 0) }.max() ?? 0
        stackHeight = max(0, high)
        centerY = (high + low) / 2
        var minX = Double.infinity, maxX = -Double.infinity, minZ = Double.infinity, maxZ = -Double.infinity
        var reach = 0.25
        for p in lay {
            let r = max(p.diameter, p.shroud.map { max($0.bottomDiameter, $0.topDiameter) } ?? 0) / 2
            minX = min(minX, p.center.x - r); maxX = max(maxX, p.center.x + r)
            minZ = min(minZ, p.center.z - r); maxZ = max(maxZ, p.center.z + r)
            reach = max(reach, hypot(p.center.x, p.center.z) + r)
        }
        centerXZ = lay.isEmpty ? .zero : SIMD2((minX + maxX) / 2, (minZ + maxZ) / 2)
        halfWidth = reach
        maxDiameter = max(0.5, 2 * reach)

        holders = []
        for (i, id) in newParts.enumerated() {
            let spec = id.spec
            let pl = lay[i]
            let q = PartModels.placementRotation(pl)
            let center = F3(Float(pl.center.x), Float(pl.center.y), Float(pl.center.z))
            let half = Float(pl.height / 2)
            // Низ и верх детали в осях корабля (вращение вокруг центра детали).
            let bottomPoint = center + q.act(F3(0, -half, 0))
            let topPoint = center + q.act(F3(0, half, 0))
            // Держатель — в центре детали, модель внутри опущена на полвысоты: поворот идёт вокруг центра.
            let holder = Entity()
            holder.position = center
            holder.orientation = q
            let inner = Entity()
            inner.position = F3(0, -half, 0)
            holder.addChild(inner)
            root.addChild(holder)
            let pieces = spec.kind == .legs
                ? PartModels.pieces(id) + PartModels.legs(diameter: spec.diameter, height: spec.height,
                                                          drop: max(0, pl.bottom))
                : PartModels.pieces(id)
            var models: [ModelEntity] = []
            // Переходный кожух разделителя: часть держателя, улетает вместе с ним.
            var shroudPieces: [PartModels.Piece] = []
            if let sh = pl.shroud {
                shroudPieces = PartModels.shroud(base: spec.height, height: sh.height,
                                                 bottomDiameter: sh.bottomDiameter, topDiameter: sh.topDiameter)
            }
            for p in pieces + shroudPieces {
                let m = ModelEntity(mesh: p.mesh, materials: [p.material])
                inner.addChild(m)
                models.append(m)
            }
            holders.append(models)
            if spec.kind == .engine {
                nozzlePositions[i] = D3(Double(bottomPoint.x), Double(bottomPoint.y), Double(bottomPoint.z))
                makePlume(index: i, spec: spec, at: bottomPoint, rotation: q)
            }
            if spec.kind == .rcs, Self.rcsPuffsEnabled {
                makeRCSPuffs(index: i, at: bottomPoint)
            }
            if spec.kind == .chute {
                makeCanopy(at: topPoint)
            }
        }
        ghostApplied.removeAll()
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

    private func makePlume(index: Int, spec: PartSpec, at origin: F3, rotation: simd_quatf) {
        let kit = Self.softPlumeKit()
        guard let mesh = kit?.outer ?? Self.sharedPlumeMesh() else { return }
        let mats = RenderMaterials.shared
        let e = Entity()
        e.position = origin
        e.orientation = rotation
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

    private func makeRCSPuffs(index: Int, at origin: F3) {
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
        holder.position = origin
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

    private func makeCanopy(at top: F3) {
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
        e.position = top
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
            rebuild(parts: parts, layout: sourceLayoutCount == parts.count ? layout : [])
        }
        updateHeat(v.partHeat)
        updateFlashes(time: time)
        if v.ladders != ladderBuilt { buildLadders(v.ladders) }
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
