import OrbitPhysics
import RealityKit
import SwiftUI
import UIKit
import simd

/// 3D-превью ангара (поток B): корабль стоит вертикально на площадке в круглом ангаре.
/// Корабль собирается из тех же моделей деталей, что и в полёте (`VesselVisual`). Все материалы непрозрачные.
/// Локальные оси: +Y — вверх, низ стека — на верхней грани площадки (`baseY`).
@MainActor
final class HangarScene: HangarPreview {
    let root = Entity()

    private let camera = PerspectiveCamera()
    private let ship = VesselVisual(parts: [], layout: [])
    private let markers = Entity()
    private let highlight = Entity()

    private var design = VesselDesign(name: "", nodes: [])
    private var layout: [PartPlacement] = []
    private var selected: Set<Int> = []
    private var ghost: HangarGhost?

    // Деталь «в руке» и гизмо: сущности переиспользуются между кадрами.
    private let floating = Entity()
    private var floatingPart: PartID?
    private let gizmoRoot = Entity()
    private var gizmo: HangarGizmo?
    private var gizmoBuilt: HangarGizmo?
    private var gizmoRadius: Float = 1

    // Камера: цель (t…) и текущее сглаженное значение (c…).
    private static let defaultAzimuth = 0.6
    private static let defaultElevation = 0.2
    private static let fovDegrees: Float = 40
    private static let baseY: Float = 0.3
    private static let wallRadius: Float = 140
    private var tAz = HangarScene.defaultAzimuth
    private var tEl = HangarScene.defaultElevation
    private var tZoom = 1.0
    private var tFit = 20.0
    private var tCenter = F3(0, 1.3, 0)
    private var cAz = HangarScene.defaultAzimuth
    private var cEl = HangarScene.defaultElevation
    private var cDist = 20.0
    private var cCenter = F3(0, 1.3, 0)
    private var animTask: Task<Void, Never>?

    init() {
        buildInterior()
        buildLights()
        root.addChild(ship.root)
        ship.root.position = F3(0, Self.baseY, 0)
        root.addChild(markers)
        root.addChild(highlight)
        root.addChild(floating)
        root.addChild(gizmoRoot)
        camera.camera.fieldOfViewInDegrees = Self.fovDegrees
        camera.camera.near = 0.3
        camera.camera.far = 600
        root.addChild(camera)
        layoutCamera()
    }

    // MARK: - HangarPreview

    func show(design newDesign: VesselDesign, selected newSelected: Set<Int>, ghost newGhost: HangarGhost?) {
        // Выбор распространяется на копии симметрии.
        var sel = Set<Int>()
        for n in newDesign.nodes where newSelected.contains(n.id) {
            sel.insert(n.id)
            if let g = n.symmetryGroup {
                for m in newDesign.nodes where m.symmetryGroup == g { sel.insert(m.id) }
            }
        }
        let designChanged = newDesign != design
        let ghostChanged = newGhost != ghost
        guard designChanged || ghostChanged || sel != selected else { return }
        ghost = newGhost
        if designChanged {
            design = newDesign
            let lay = newDesign.layout()
            let parts = newDesign.parts
            if parts != ship.parts || lay != layout {
                layout = lay
                ship.rebuild(parts: parts, layout: lay)
                // Во время перетаскивания камера стоит на месте.
                if newGhost == nil { fitCamera() }
                rebuildMarkers()
                startAnimating()
            }
        }
        if designChanged || ghostChanged {
            var idx = Set<Int>()
            if let g = newGhost { for id in g.ids { if let i = design.index(of: id) { idx.insert(i) } } }
            ship.setGhost(idx, valid: newGhost?.valid ?? true)
        }
        selected = sel
        rebuildHighlight()
        if designChanged { refreshGizmo() }
    }

    func apply(_ input: CameraInput) {
        if input.reset {
            tAz = Self.defaultAzimuth
            tEl = Self.defaultElevation
            tZoom = 1
        } else {
            tAz += Double(input.orbitDelta.x)
            tEl = clampd(tEl + Double(input.orbitDelta.y), 0.03, 1.3)
            if input.zoomFactor.isFinite, input.zoomFactor > 0 {
                tZoom = clampd(tZoom * Double(input.zoomFactor), 0.3, 1.6)
            }
        }
        startAnimating()
    }

    /// Точка в осях раскладки (м) → точка экрана; nil — за камерой.
    func project(_ point: Vec3, viewSize: CGSize) -> CGPoint? {
        project(F3(Float(point.x), Self.baseY + Float(point.y), Float(point.z)), viewSize: viewSize)
    }

    private func project(_ point: F3, viewSize: CGSize) -> CGPoint? {
        guard viewSize.width > 1, viewSize.height > 1 else { return nil }
        let local = camera.orientation.inverse.act(point - camera.position)
        guard local.z < -camera.camera.near else { return nil }
        let t = tan(Double(Self.fovDegrees) * .pi / 360)
        let scale = Double(viewSize.height) / (2 * -Double(local.z) * t)
        return CGPoint(x: Double(viewSize.width) / 2 + Double(local.x) * scale,
                       y: Double(viewSize.height) / 2 - Double(local.y) * scale)
    }

    /// Полуразмеры габарита детали в её осях (X — наружу, Y — вдоль оси, Z — по касательной), м.
    private func halfExtents(_ i: Int) -> F3 {
        let p = layout[i]
        let id = design.nodes[i].part
        let along = Float(p.diameter / 2)
        var tangent = along
        switch id {
        case .decouplerRadial: tangent = PartModels.radialPlateWidth / 2
        case .fin: tangent = 0.05
        default: break
        }
        return F3(max(along, 0.08), max(Float(p.height / 2), 0.08), max(tangent, 0.08))
    }

    /// Луч из камеры пересекает габариты деталей. Возвращается id ближайшей к камере.
    func pickPart(at point: CGPoint, viewSize: CGSize) -> Int? {
        guard viewSize.width > 1, viewSize.height > 1, layout.count == design.nodes.count else { return nil }
        let t = Float(tan(Double(Self.fovDegrees) * .pi / 360))
        let x = Float(2 * point.x / viewSize.width - 1) * t * Float(viewSize.width / viewSize.height)
        let y = Float(1 - 2 * point.y / viewSize.height) * t
        let ray = simd_normalize(camera.orientation.act(F3(x, y, -1)))
        let origin = camera.position
        var nearest = Float.infinity
        var result: Int?
        for i in layout.indices {
            if let g = ghost, g.ids.contains(design.nodes[i].id) { continue }
            let p = layout[i]
            let c = F3(Float(p.center.x), Self.baseY + Float(p.center.y), Float(p.center.z))
            // Луч в осях детали.
            let q = PartModels.placementRotation(p).inverse
            let o = q.act(origin - c)
            let d = q.act(ray)
            let h = halfExtents(i)
            var enter: Float = 0
            var exit = Float.infinity
            for axis in 0..<3 {
                if abs(d[axis]) < 1e-6 {
                    if o[axis] < -h[axis] || o[axis] > h[axis] { exit = -1 }
                } else {
                    let a = (-h[axis] - o[axis]) / d[axis]
                    let b = (h[axis] - o[axis]) / d[axis]
                    enter = max(enter, min(a, b))
                    exit = min(exit, max(a, b))
                }
            }
            if exit >= enter, enter < nearest { nearest = enter; result = design.nodes[i].id }
        }
        return result
    }

    // MARK: - Деталь в руке, гизмо

    /// Луч из камеры через точку экрана.
    private func ray(at point: CGPoint, viewSize: CGSize) -> (origin: F3, dir: F3) {
        let t = Float(tan(Double(Self.fovDegrees) * .pi / 360))
        let x = Float(2 * point.x / viewSize.width - 1) * t * Float(viewSize.width / viewSize.height)
        let y = Float(1 - 2 * point.y / viewSize.height) * t
        return (camera.position, simd_normalize(camera.orientation.act(F3(x, y, -1))))
    }

    func showFloating(_ part: PartID?, at point: CGPoint, viewSize: CGSize) {
        guard let part, viewSize.width > 1, viewSize.height > 1 else {
            if floating.isEnabled { floating.isEnabled = false }
            return
        }
        if part != floatingPart {
            floatingPart = part
            for c in Array(floating.children) { c.removeFromParent() }
            let spec = part.spec
            // Модель центрирована по высоте: деталь «висит» центром под пальцем.
            let inner = Entity()
            inner.position = F3(0, -Float(spec.height / 2), 0)
            for p in PartModels.pieces(part) {
                inner.addChild(ModelEntity(mesh: p.mesh, materials: [VesselVisual.ghostMaterial(valid: true)]))
            }
            floating.addChild(inner)
        }
        // Плоскость через центр корабля лицом к камере.
        let r = ray(at: point, viewSize: viewSize)
        let n = camera.orientation.act(F3(0, 0, 1))
        let denom = simd_dot(r.dir, n)
        guard abs(denom) > 1e-4 else { return }
        let dist = simd_dot(tCenter - r.origin, n) / denom
        guard dist > 0 else { return }
        floating.position = r.origin + r.dir * dist
        if !floating.isEnabled { floating.isEnabled = true }
    }

    func showGizmo(_ newGizmo: HangarGizmo?) {
        gizmo = newGizmo
        refreshGizmo()
    }

    private func gizmoIndex() -> Int? {
        guard let g = gizmo else { return nil }
        let id: Int
        switch g {
        case .rotate(let i), .offset(let i): id = i
        }
        guard let i = design.index(of: id), layout.indices.contains(i) else { return nil }
        return i
    }

    private func gizmoCenter() -> F3? {
        guard let i = gizmoIndex() else { return nil }
        let c = layout[i].center
        return F3(Float(c.x), Self.baseY + Float(c.y), Float(c.z))
    }

    /// Оси корабля X, Y, Z и цвета гизмо: красный, синий, зелёный.
    private static let axes: [F3] = [F3(1, 0, 0), F3(0, 1, 0), F3(0, 0, 1)]
    private static let axisColors: [UIColor] = [
        UIColor(red: 0.95, green: 0.25, blue: 0.22, alpha: 1),
        UIColor(red: 0.25, green: 0.5, blue: 1.0, alpha: 1),
        UIColor(red: 0.25, green: 0.85, blue: 0.35, alpha: 1),
    ]

    private func refreshGizmo() {
        guard let g = gizmo, let i = gizmoIndex(), let c = gizmoCenter() else {
            if gizmoRoot.isEnabled { gizmoRoot.isEnabled = false }
            gizmoBuilt = nil
            return
        }
        gizmoRoot.position = c
        gizmoRoot.isEnabled = true
        let p = layout[i]
        let radius = Float(max(0.6, max(p.diameter, p.height) / 2 * 1.3 + 0.2))
        guard gizmoBuilt != g || abs(radius - gizmoRadius) > 1e-4 else { return }
        gizmoBuilt = g
        gizmoRadius = radius
        for ch in Array(gizmoRoot.children) { ch.removeFromParent() }
        let t = max(0.03, radius * 0.035)
        for k in 0..<3 {
            var b = MeshBuilder()
            let axis = Self.axes[k]
            switch g {
            case .rotate:
                // Кольцо вокруг оси k: строим вокруг Y и поворачиваем Y в ось.
                b.lathe(ringProfile(inner: radius - t, outer: radius + t, thickness: t * 2), segments: 48)
                b = rotated(b, from: F3(0, 1, 0), to: axis)
            case .offset:
                let len = radius * 1.35
                var arrow = MeshBuilder()
                arrow.beam(F3(0, 0, 0), F3(0, len, 0), thickness: t * 1.6)
                arrow.lathe([SIMD2(t * 4, len), SIMD2(0, len + radius * 0.3)], segments: 16)
                b = rotated(arrow, from: F3(0, 1, 0), to: axis)
            }
            if let mesh = b.makeMesh(name: "gizmo\(k)") {
                gizmoRoot.addChild(ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: Self.axisColors[k])]))
            }
        }
    }

    private func rotated(_ src: MeshBuilder, from a: F3, to b: F3) -> MeshBuilder {
        if simd_dot(a, b) > 0.999 { return src }
        let q = simd_quatf(from: a, to: b)
        var out = src
        out.positions = src.positions.map { q.act($0) }
        out.normals = src.normals.map { q.act($0) }
        return out
    }

    /// Расстояние от точки до отрезка на экране, pt.
    private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        let t = l2 > 1e-9 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    func pickGizmoAxis(at point: CGPoint, viewSize: CGSize) -> Int? {
        guard let g = gizmo, gizmoRoot.isEnabled, let c = gizmoCenter() else { return nil }
        var best: Int?
        var bestDist: CGFloat = 22
        for k in 0..<3 {
            let axis = Self.axes[k]
            var pts: [CGPoint?] = []
            switch g {
            case .rotate:
                let u = abs(axis.y) < 0.9 ? simd_normalize(simd_cross(axis, F3(0, 1, 0))) : F3(1, 0, 0)
                let v = simd_cross(axis, u)
                for s in 0...48 {
                    let a = Float(s) / 48 * 2 * .pi
                    pts.append(project(c + (u * cos(a) + v * sin(a)) * gizmoRadius, viewSize: viewSize))
                }
            case .offset:
                pts = [project(c, viewSize: viewSize), project(c + axis * (gizmoRadius * 1.6), viewSize: viewSize)]
            }
            for j in 0..<(pts.count - 1) {
                guard let a = pts[j], let b = pts[j + 1] else { continue }
                let d = distance(point, toSegment: a, b)
                if d < bestDist { bestDist = d; best = k }
            }
        }
        return best
    }

    func screenDirection(of axis: Vec3, at point: Vec3, viewSize: CGSize) -> CGVector {
        let far = Vec3(point.x + axis.x * 0.5, point.y + axis.y * 0.5, point.z + axis.z * 0.5)
        guard let a = project(point, viewSize: viewSize), let b = project(far, viewSize: viewSize) else {
            return CGVector(dx: 0, dy: 0)
        }
        let dx = b.x - a.x, dy = b.y - a.y
        let l = hypot(dx, dy)
        return l > 1e-6 ? CGVector(dx: dx / l, dy: dy / l) : CGVector(dx: 0, dy: 0)
    }

    // MARK: - Камера

    /// Вписать габарит дерева (высоту и ширину с боковыми ускорителями); фокус — центр габарита.
    private func fitCamera() {
        let height = ship.stackHeight
        let half = max(max(height, 3) / 2, ship.halfWidth * 0.8) * 1.35 + 0.6
        let t = tan(Double(Self.fovDegrees) * .pi / 360)
        tFit = clampd(half / t, 6, 120)
        tCenter = F3(Float(ship.centerXZ.x), Self.baseY + Float(max(ship.centerY, 0.5)), Float(ship.centerXZ.y))
    }

    private var targetDistance: Double { clampd(tFit * tZoom, 3, 125) }

    private func layoutCamera() {
        let dir = F3(Float(cos(cEl) * sin(cAz)), Float(sin(cEl)), Float(cos(cEl) * cos(cAz)))
        let c = cCenter
        camera.look(at: c, from: c + dir * Float(cDist), relativeTo: nil)
    }

    private func startAnimating() {
        guard animTask == nil else { return }
        animTask = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self else { return }
                let now = ContinuousClock.now
                let d = now - last
                last = now
                let dt = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
                if self.step(dt: min(max(dt, 0.001), 0.1)) {
                    self.animTask = nil
                    return
                }
            }
        }
    }

    /// Шаг сглаживания; true — камера пришла к цели.
    private func step(dt: Double) -> Bool {
        let k = 1 - exp(-dt * 7)
        let dist = targetDistance
        cAz += (tAz - cAz) * k
        cEl += (tEl - cEl) * k
        cCenter += (tCenter - cCenter) * Float(k)
        cDist *= pow(dist / cDist, k)
        layoutCamera()
        let done = abs(tAz - cAz) < 1e-3 && abs(tEl - cEl) < 1e-3 && simd_length(tCenter - cCenter) < 1e-3
            && abs(dist / cDist - 1) < 1e-3
        if done {
            cAz = tAz
            cEl = tEl
            cCenter = tCenter
            cDist = dist
            layoutCamera()
        }
        return done
    }

    // MARK: - Корабль: маркеры и подсветка

    private var lineThickness: Float { max(0.05, Float(ship.stackHeight) * 0.004) }

    private func ringProfile(inner: Float, outer: Float, thickness t: Float) -> [SIMD2<Float>] {
        [SIMD2(outer, -t / 2), SIMD2(outer, t / 2), SIMD2(inner, t / 2), SIMD2(inner, -t / 2), SIMD2(outer, -t / 2)]
    }

    private func replaceChildren(of entity: Entity, with mesh: MeshResource?, material: any RealityKit.Material) {
        for c in Array(entity.children) { c.removeFromParent() }
        if let mesh { entity.addChild(ModelEntity(mesh: mesh, materials: [material])) }
    }

    /// Тонкие цветные кольца на осевых разделителях ступеней.
    private func rebuildMarkers() {
        var b = MeshBuilder()
        let t = lineThickness
        for (i, n) in design.nodes.enumerated() where layout.indices.contains(i) {
            let spec = n.part.spec
            guard spec.kind == .decoupler, n.part != .decouplerRadial else { continue }
            let p = layout[i]
            let r = Float(spec.diameter / 2)
            let ring = ringProfile(inner: r * 0.98, outer: r + t * 1.4, thickness: t * 1.2)
            var one = MeshBuilder()
            one.lathe(ring, segments: 48, y0: Self.baseY + Float(p.center.y))
            one.positions = one.positions.map { $0 + F3(Float(p.center.x), 0, Float(p.center.z)) }
            b.append(one)
        }
        replaceChildren(of: markers, with: b.makeMesh(name: "stageMarkers"),
                        material: UnlitMaterial(color: UIColor(red: 1.0, green: 0.78, blue: 0.12, alpha: 1)))
    }

    /// Контур выбранных деталей: рамка по габариту (12 рёбер).
    private func rebuildHighlight() {
        guard !selected.isEmpty, layout.count == design.nodes.count else {
            replaceChildren(of: highlight, with: nil, material: RenderMaterials.shared.white)
            return
        }
        let t = lineThickness
        var b = MeshBuilder()
        for (i, n) in design.nodes.enumerated() where selected.contains(n.id) {
            let p = layout[i]
            let h = halfExtents(i) * 1.05 + F3(repeating: t)
            let c = F3(Float(p.center.x), Self.baseY + Float(p.center.y), Float(p.center.z))
            let q = PartModels.placementRotation(p)
            func corner(_ sx: Float, _ sy: Float, _ sz: Float) -> F3 { c + q.act(F3(sx * h.x, sy * h.y, sz * h.z)) }
            let signs: [Float] = [-1, 1]
            for sa in signs {
                for sb in signs {
                    b.beam(corner(-1, sa, sb), corner(1, sa, sb), thickness: t * 1.4)
                    b.beam(corner(sa, -1, sb), corner(sa, 1, sb), thickness: t * 1.4)
                    b.beam(corner(sa, sb, -1), corner(sa, sb, 1), thickness: t * 1.4)
                }
            }
        }
        replaceChildren(of: highlight, with: b.makeMesh(name: "partHighlight"),
                        material: UnlitMaterial(color: UIColor(red: 0.2, green: 0.9, blue: 1.0, alpha: 1)))
    }

    // MARK: - Интерьер и свет

    private func buildInterior() {
        let R = Self.wallRadius
        let wallH: Float = 110
        let floorMat = SimpleMaterial(color: UIColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1), roughness: 0.8, isMetallic: false)
        let wallMat = SimpleMaterial(color: UIColor(red: 0.09, green: 0.11, blue: 0.15, alpha: 1), roughness: 0.9, isMetallic: false)
        let ribMat = SimpleMaterial(color: UIColor(red: 0.21, green: 0.25, blue: 0.31, alpha: 1), roughness: 0.6, isMetallic: false)
        let padMat = SimpleMaterial(color: UIColor(white: 0.32, alpha: 1), roughness: 0.85, isMetallic: false)
        let lineMat = SimpleMaterial(color: UIColor(red: 0.55, green: 0.42, blue: 0.10, alpha: 1), roughness: 0.8, isMetallic: false)

        // Пол, стена и потолок — односторонние: снаружи (за стеной) их не видно.
        var floor = MeshBuilder()
        floor.lathe([SIMD2(R, 0), SIMD2(0, 0)], segments: 64)
        var wall = MeshBuilder()
        wall.lathe([SIMD2(R, wallH), SIMD2(R, 0)], segments: 64)
        wall.lathe([SIMD2(0, wallH), SIMD2(R, wallH)], segments: 64)

        // Ребра стены и пояса ферм.
        var ribs = MeshBuilder()
        for k in 0..<32 {
            let a = Float(k) / 32 * 2 * .pi
            let x = (R - 0.8) * cos(a), z = (R - 0.8) * sin(a)
            ribs.beam(F3(x, 0, z), F3(x, wallH, z), thickness: 1.6)
        }
        for y: Float in [18, 42, 66, 90] {
            ribs.lathe([SIMD2(R - 1.5, y), SIMD2(R - 1.5, y + 1.4)], segments: 64, twoSided: true)
        }
        // Колонны ближе к центру: ферма вокруг площадки.
        let colR: Float = 32
        for k in 0..<8 {
            let a = Float(k) / 8 * 2 * .pi + .pi / 8
            let x = colR * cos(a), z = colR * sin(a)
            ribs.beam(F3(x, 0, z), F3(x, 70, z), thickness: 1.4)
        }
        for y: Float in [24, 48, 70] {
            for k in 0..<8 {
                let a0 = Float(k) / 8 * 2 * .pi + .pi / 8
                let a1 = Float(k + 1) / 8 * 2 * .pi + .pi / 8
                ribs.beam(F3(colR * cos(a0), y, colR * sin(a0)), F3(colR * cos(a1), y, colR * sin(a1)), thickness: 0.9)
            }
        }

        // Площадка под кораблём и разметка пола.
        var pad = MeshBuilder()
        pad.lathe([SIMD2(7, 0), SIMD2(7, Self.baseY), SIMD2(0, Self.baseY)], segments: 48)
        var lines = MeshBuilder()
        for (r0, r1) in [(Float(12), Float(12.5)), (Float(22), Float(22.5)), (Float(40), Float(40.6))] {
            lines.lathe([SIMD2(r1, 0), SIMD2(r1, 0.08), SIMD2(r0, 0.08), SIMD2(r0, 0)], segments: 64)
        }

        let list: [(MeshBuilder, any RealityKit.Material, String)] = [
            (floor, floorMat, "hangarFloor"), (wall, wallMat, "hangarWall"), (ribs, ribMat, "hangarRibs"),
            (pad, padMat, "hangarPad"), (lines, lineMat, "hangarLines"),
        ]
        for (b, m, name) in list {
            if let mesh = b.makeMesh(name: name) { root.addChild(ModelEntity(mesh: mesh, materials: [m])) }
        }
    }

    private func buildLights() {
        let key = DirectionalLight()
        key.light.intensity = 5_500
        key.light.color = UIColor(red: 1.0, green: 0.96, blue: 0.9, alpha: 1)
        key.look(at: .zero, from: F3(30, 55, 40), relativeTo: nil)
        root.addChild(key)

        let fill = DirectionalLight()
        fill.light.intensity = 2_400
        fill.light.color = UIColor(red: 0.62, green: 0.72, blue: 1.0, alpha: 1)
        fill.look(at: .zero, from: F3(-40, 20, -30), relativeTo: nil)
        root.addChild(fill)

        // Заполняющий свет с передней стороны: кадр не уходит в чёрное при любом азимуте.
        let front = DirectionalLight()
        front.light.intensity = 1_800
        front.light.color = UIColor(red: 0.9, green: 0.9, blue: 1.0, alpha: 1)
        front.look(at: .zero, from: F3(-25, 15, 45), relativeTo: nil)
        root.addChild(front)
    }
}

/// Вьюха превью ангара: виртуальная камера, содержимое и камеру ведёт `HangarScene`.
struct HangarSceneView: View {
    let scene: HangarScene

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            // Вьюха может пересоздаваться, сцена живёт дольше: отцепить корень от прошлого родителя.
            scene.root.removeFromParent()
            content.add(scene.root)
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.06))
    }
}
