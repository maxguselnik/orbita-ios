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
        camera.camera.fieldOfViewInDegrees = Self.fovDegrees
        camera.camera.near = 0.3
        camera.camera.far = 600
        root.addChild(camera)
        layoutCamera()
    }

    // MARK: - HangarPreview

    func show(design newDesign: VesselDesign, selected newSelected: Set<Int>) {
        // Выбор распространяется на копии симметрии.
        var sel = Set<Int>()
        for n in newDesign.nodes where newSelected.contains(n.id) {
            sel.insert(n.id)
            if let g = n.symmetryGroup {
                for m in newDesign.nodes where m.symmetryGroup == g { sel.insert(m.id) }
            }
        }
        let designChanged = newDesign != design
        guard designChanged || sel != selected else { return }
        if designChanged {
            design = newDesign
            let lay = newDesign.layout()
            let parts = newDesign.parts
            if parts != ship.parts || lay != layout {
                layout = lay
                ship.rebuild(parts: parts, layout: lay)
                fitCamera()
                rebuildMarkers()
                startAnimating()
            }
        }
        selected = sel
        rebuildHighlight()
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
            let p = layout[i]
            let c = F3(Float(p.center.x), Self.baseY + Float(p.center.y), Float(p.center.z))
            // Луч в осях детали (поворот вокруг Y только у деталей с направлением).
            let q = PartModels.rotatesWithOutward(design.nodes[i].part)
                ? simd_quatf(angle: PartModels.yaw(outward: p.outward), axis: F3(0, 1, 0)).inverse
                : simd_quatf(angle: 0, axis: F3(0, 1, 0))
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
            let q = PartModels.rotatesWithOutward(n.part)
                ? simd_quatf(angle: PartModels.yaw(outward: p.outward), axis: F3(0, 1, 0))
                : simd_quatf(angle: 0, axis: F3(0, 1, 0))
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
