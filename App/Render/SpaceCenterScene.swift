import OrbitPhysics
import RealityKit
import SwiftUI
import UIKit
import simd

/// 3D-сцена космоцентра (поток B): площадка на Терре, шесть зданий вокруг, море вдали, небо.
/// Камера медленно облетает центр; после жеста пальцем облёт стоит 5 с. Все модели процедурные.
/// Оси: +Y — вверх, площадка с ракетой — в начале координат, земля на y = 0.
@MainActor
final class SpaceCenterScene: SpaceCenterPreview {
    let root = Entity()

    private let camera = PerspectiveCamera()
    private let ship = VesselVisual(parts: [.chute, .podK1, .decoupler, .t400, .shtil, .decoupler, .t800, .t800, .vikhr], layout: [])
    private let highlightEntity = Entity()

    /// Габарит здания в мировых осях (для выбора, подписи и подсветки).
    private struct Footprint {
        var building: Building
        var center: F3
        var half: F3
    }
    private var footprints: [Footprint] = []
    private var highlighted: Building?

    // Камера.
    private static let fovDegrees: Float = 40
    private static let defaultAzimuth = 0.55
    private static let defaultElevation = 0.3
    private static let baseDistance = 150.0
    private static let focus = F3(0, 9, 4)
    private static let autoSpeed = 0.045
    private static let pauseAfterGesture = 5.0
    private var az = SpaceCenterScene.defaultAzimuth
    private var el = SpaceCenterScene.defaultElevation
    private var zoom = 1.0
    private var lastGesture: ContinuousClock.Instant?
    private var loop: Task<Void, Never>?

    init() {
        buildSky()
        buildGround()
        buildLights()
        buildBuildings()
        root.addChild(highlightEntity)
        root.addChild(ship.root)
        ship.root.position = F3(0, 0.5, 0)
        camera.camera.fieldOfViewInDegrees = Self.fovDegrees
        camera.camera.near = 0.5
        camera.camera.far = 8000
        root.addChild(camera)
        layoutCamera()
    }

    // MARK: - SpaceCenterPreview

    func apply(_ input: CameraInput) {
        lastGesture = .now
        if input.reset {
            az = Self.defaultAzimuth
            el = Self.defaultElevation
            zoom = 1
        } else {
            az += Double(input.orbitDelta.x)
            el = clampd(el + Double(input.orbitDelta.y), 0.06, 1.2)
            if input.zoomFactor.isFinite, input.zoomFactor > 0 {
                zoom = clampd(zoom * Double(input.zoomFactor), 0.4, 1.5)
            }
        }
        layoutCamera()
    }

    func labelPoint(of building: Building, viewSize: CGSize) -> CGPoint? {
        guard let f = footprints.first(where: { $0.building == building }) else { return nil }
        return project(f.center + F3(0, f.half.y + 2, 0), viewSize: viewSize)
    }

    func pickBuilding(at point: CGPoint, viewSize: CGSize) -> Building? {
        guard viewSize.width > 1, viewSize.height > 1 else { return nil }
        let t = Float(tan(Double(Self.fovDegrees) * .pi / 360))
        let x = Float(2 * point.x / viewSize.width - 1) * t * Float(viewSize.width / viewSize.height)
        let y = Float(1 - 2 * point.y / viewSize.height) * t
        let dir = simd_normalize(camera.orientation.act(F3(x, y, -1)))
        let origin = camera.position
        var nearest = Float.infinity
        var result: Building?
        for f in footprints {
            let lo = f.center - f.half, hi = f.center + f.half
            var enter: Float = 0
            var exit = Float.infinity
            for axis in 0..<3 {
                if abs(dir[axis]) < 1e-6 {
                    if origin[axis] < lo[axis] || origin[axis] > hi[axis] { exit = -1 }
                } else {
                    let a = (lo[axis] - origin[axis]) / dir[axis]
                    let b = (hi[axis] - origin[axis]) / dir[axis]
                    enter = max(enter, min(a, b))
                    exit = min(exit, max(a, b))
                }
            }
            if exit >= enter, enter < nearest { nearest = enter; result = f.building }
        }
        return result
    }

    func highlight(_ building: Building?) {
        guard building != highlighted else { return }
        highlighted = building
        for c in Array(highlightEntity.children) { c.removeFromParent() }
        guard let building, let f = footprints.first(where: { $0.building == building }) else { return }
        var b = MeshBuilder()
        let h = f.half + F3(repeating: 0.6)
        let signs: [Float] = [-1, 1]
        func corner(_ sx: Float, _ sy: Float, _ sz: Float) -> F3 { f.center + F3(sx * h.x, sy * h.y, sz * h.z) }
        for sa in signs {
            for sb in signs {
                b.beam(corner(-1, sa, sb), corner(1, sa, sb), thickness: 0.35)
                b.beam(corner(sa, -1, sb), corner(sa, 1, sb), thickness: 0.35)
                b.beam(corner(sa, sb, -1), corner(sa, sb, 1), thickness: 0.35)
            }
        }
        if let mesh = b.makeMesh(name: "buildingHighlight") {
            highlightEntity.addChild(ModelEntity(
                mesh: mesh, materials: [UnlitMaterial(color: UIColor(red: 0.2, green: 0.9, blue: 1.0, alpha: 1))]))
        }
    }

    // MARK: - Камера

    private func layoutCamera() {
        let dist = Float(Self.baseDistance * zoom)
        let dir = F3(Float(cos(el) * sin(az)), Float(sin(el)), Float(cos(el) * cos(az)))
        camera.look(at: Self.focus, from: Self.focus + dir * dist, relativeTo: nil)
    }

    /// Запустить облёт: вызывать, пока сцена на экране (`SpaceCenterSceneView.onAppear`).
    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self else { return }
                let now = ContinuousClock.now
                let d = now - last
                last = now
                let dt = min(0.1, Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18)
                if let g = self.lastGesture, now - g < .seconds(Self.pauseAfterGesture) { continue }
                self.az += Self.autoSpeed * dt
                self.layoutCamera()
            }
        }
    }

    /// Остановить облёт (сцена скрыта): цикл не крутится в полёте и других экранах.
    func stop() {
        loop?.cancel()
        loop = nil
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

    // MARK: - Небо, земля, море

    private func buildSky() {
        // Купол из 14 поясов с градиентом от бледного горизонта к синему зениту (изнутри).
        let r: Float = 3000
        let steps = 14
        let horizon = (r: Float(0.74), g: Float(0.86), b: Float(0.96))
        let zenith = (r: Float(0.20), g: Float(0.44), b: Float(0.80))
        for i in 0..<steps {
            let a0 = Float.pi / 2 * (1 - Float(i) / Float(steps)) + 0.0
            let a1 = Float.pi / 2 * (1 - Float(i + 1) / Float(steps)) - (i == steps - 1 ? 0.12 : 0)
            var b = MeshBuilder()
            b.lathe([SIMD2(r * cos(a0), r * sin(a0)), SIMD2(r * cos(a1), r * sin(a1))], segments: 40)
            let k = pow(Float(i) / Float(steps - 1), 1.6)
            let color = UIColor(red: CGFloat(zenith.r + (horizon.r - zenith.r) * k),
                                green: CGFloat(zenith.g + (horizon.g - zenith.g) * k),
                                blue: CGFloat(zenith.b + (horizon.b - zenith.b) * k), alpha: 1)
            if let mesh = b.makeMesh(name: "skyBand") {
                root.addChild(ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]))
            }
        }
    }

    private func buildGround() {
        let grass = SimpleMaterial(color: UIColor(red: 0.30, green: 0.50, blue: 0.22, alpha: 1), roughness: 0.95, isMetallic: false)
        let sand = SimpleMaterial(color: UIColor(red: 0.78, green: 0.72, blue: 0.52, alpha: 1), roughness: 0.95, isMetallic: false)
        let sea = SimpleMaterial(color: UIColor(red: 0.10, green: 0.32, blue: 0.52, alpha: 1), roughness: 0.25, isMetallic: false)
        let road = SimpleMaterial(color: UIColor(white: 0.40, alpha: 1), roughness: 0.9, isMetallic: false)

        var g = MeshBuilder()
        g.lathe([SIMD2(262, 0), SIMD2(0, 0)], segments: 64)
        var s = MeshBuilder()
        s.lathe([SIMD2(310, -1.2), SIMD2(262, 0)], segments: 64)
        var w = MeshBuilder()
        w.lathe([SIMD2(4000, -1.2), SIMD2(0, -1.2)], segments: 48)

        // Дороги от площадки к зданиям.
        var r = MeshBuilder()
        for site in Self.sites.values where site.building != .launchPad {
            let p = SIMD2<Float>(site.x, site.z)
            let len = simd_length(p)
            let d = p / len
            let mid = d * (len / 2)
            r.box(center: F3(mid.x, 0.05, mid.y), x: F3(d.x, 0, d.y) * (len / 2), y: F3(0, 0.04, 0),
                  z: F3(-d.y, 0, d.x) * 2.2)
        }
        let list: [(MeshBuilder, any RealityKit.Material, String)] = [
            (g, grass, "ground"), (s, sand, "beach"), (w, sea, "sea"), (r, road, "roads"),
        ]
        for (b, m, name) in list {
            if let mesh = b.makeMesh(name: name) { root.addChild(ModelEntity(mesh: mesh, materials: [m])) }
        }
    }

    private func buildLights() {
        let key = DirectionalLight()
        key.light.intensity = 6_500
        key.light.color = UIColor(red: 1.0, green: 0.96, blue: 0.88, alpha: 1)
        key.look(at: .zero, from: F3(60, 90, 40), relativeTo: nil)
        root.addChild(key)
        let fill = DirectionalLight()
        fill.light.intensity = 2_600
        fill.light.color = UIColor(red: 0.65, green: 0.75, blue: 1.0, alpha: 1)
        fill.look(at: .zero, from: F3(-70, 40, -50), relativeTo: nil)
        root.addChild(fill)
    }

    // MARK: - Здания

    private struct Site {
        var building: Building
        var x: Float
        var z: Float
    }

    private static let sites: [Building: Site] = [
        .launchPad: Site(building: .launchPad, x: 0, z: 0),
        .hangar: Site(building: .hangar, x: -48, z: -24),
        .research: Site(building: .research, x: 42, z: -38),
        .missionControl: Site(building: .missionControl, x: 64, z: 20),
        .astronauts: Site(building: .astronauts, x: -64, z: 36),
        .tracking: Site(building: .tracking, x: -6, z: 68),
    ]

    private struct Materials {
        let wall = SimpleMaterial(color: UIColor(white: 0.84, alpha: 1), roughness: 0.7, isMetallic: false)
        let wallWarm = SimpleMaterial(color: UIColor(red: 0.86, green: 0.80, blue: 0.70, alpha: 1), roughness: 0.75, isMetallic: false)
        let dark = SimpleMaterial(color: UIColor(white: 0.14, alpha: 1), roughness: 0.5, isMetallic: false)
        let glass = SimpleMaterial(color: UIColor(red: 0.10, green: 0.20, blue: 0.32, alpha: 1), roughness: 0.15, isMetallic: true)
        let metal = SimpleMaterial(color: UIColor(white: 0.62, alpha: 1), roughness: 0.35, isMetallic: true)
        let accent = SimpleMaterial(color: UIColor(red: 0.86, green: 0.40, blue: 0.10, alpha: 1), roughness: 0.6, isMetallic: false)
        let roof = SimpleMaterial(color: UIColor(red: 0.55, green: 0.18, blue: 0.14, alpha: 1), roughness: 0.7, isMetallic: false)
        let concrete = SimpleMaterial(color: UIColor(white: 0.55, alpha: 1), roughness: 0.95, isMetallic: false)
        let concreteDark = SimpleMaterial(color: UIColor(white: 0.30, alpha: 1), roughness: 0.95, isMetallic: false)
        let steel = SimpleMaterial(color: UIColor(red: 0.60, green: 0.17, blue: 0.10, alpha: 1), roughness: 0.7, isMetallic: false)
        let white = SimpleMaterial(color: UIColor(white: 0.95, alpha: 1), roughness: 0.5, isMetallic: false)
    }

    private func add(_ parent: Entity, _ b: MeshBuilder, _ m: any RealityKit.Material, _ name: String) {
        if let mesh = b.makeMesh(name: name) { parent.addChild(ModelEntity(mesh: mesh, materials: [m])) }
    }

    /// Параллелепипед по центру и полному размеру.
    private func block(_ b: inout MeshBuilder, _ c: F3, _ size: F3) {
        b.box(center: c, x: F3(size.x / 2, 0, 0), y: F3(0, size.y / 2, 0), z: F3(0, 0, size.z / 2))
    }

    private func place(_ building: Building, center: F3, half: F3, into group: Entity) {
        let site = Self.sites[building] ?? Site(building: building, x: 0, z: 0)
        group.position = F3(site.x, 0, site.z)
        root.addChild(group)
        footprints.append(Footprint(building: building, center: F3(site.x, 0, site.z) + center, half: half))
    }

    private func buildBuildings() {
        let m = Materials()
        buildHangar(m)
        buildResearch(m)
        buildMissionControl(m)
        buildAstronauts(m)
        buildTracking(m)
        buildLaunchPad(m)
    }

    /// Сборочный цех: высокий ангар с большими воротами и оранжевым поясом.
    private func buildHangar(_ m: Materials) {
        let g = Entity()
        var body = MeshBuilder(), gate = MeshBuilder(), seams = MeshBuilder(), trim = MeshBuilder()
        block(&body, F3(0, 18, 0), F3(28, 36, 36))
        block(&body, F3(0, 36.6, 0), F3(30, 1.2, 38))
        // Ворота на стороне +Z (к площадке), створки и стыки.
        block(&gate, F3(0, 14, 18.05), F3(14, 28, 0.3))
        for k in -3...3 { block(&seams, F3(Float(k) * 2, 14, 18.25), F3(0.25, 28, 0.2)) }
        block(&trim, F3(0, 28.6, 18.2), F3(15.5, 1.2, 0.5))
        block(&trim, F3(0, 31, 0), F3(28.4, 0.8, 36.4))
        add(g, body, m.wall, "hangarBody")
        add(g, gate, m.dark, "hangarGate")
        add(g, seams, m.metal, "hangarSeams")
        add(g, trim, m.accent, "hangarTrim")
        place(.hangar, center: F3(0, 18.5, 0), half: F3(15, 18.5, 19), into: g)
    }

    /// Исследовательский центр: низкий корпус с окнами и куполом обсерватории.
    private func buildResearch(_ m: Materials) {
        let g = Entity()
        var body = MeshBuilder(), glass = MeshBuilder(), dome = MeshBuilder(), annex = MeshBuilder()
        block(&body, F3(0, 4.5, 0), F3(28, 9, 18))
        block(&glass, F3(0, 5, 9.05), F3(24, 3, 0.2))
        block(&glass, F3(0, 5, -9.05), F3(24, 3, 0.2))
        block(&annex, F3(-17, 3, 2), F3(8, 6, 10))
        // Купол: четверть эллипса на цилиндрическом основании.
        var prof: [SIMD2<Float>] = [SIMD2(0, 9), SIMD2(6.5, 9), SIMD2(6.5, 10)]
        for i in 1...10 {
            let a = Float(i) / 10 * .pi / 2
            prof.append(SIMD2(6.5 * cos(a), 10 + 5.5 * sin(a)))
        }
        var domeMesh = MeshBuilder()
        domeMesh.lathe(prof, segments: 32)
        domeMesh.positions = domeMesh.positions.map { $0 + F3(-3, 0, 0) }
        dome = domeMesh
        var slit = MeshBuilder()
        block(&slit, F3(-3, 13, 5.2), F3(1.2, 6, 1.4))
        add(g, body, m.white, "researchBody")
        add(g, annex, m.wallWarm, "researchAnnex")
        add(g, glass, m.glass, "researchGlass")
        add(g, dome, m.metal, "researchDome")
        add(g, slit, m.dark, "researchSlit")
        place(.research, center: F3(-1.5, 7.5, 0), half: F3(18.5, 7.5, 9.5), into: g)
    }

    /// Центр управления: здание с треугольной (фронтонной) крышей и антенной.
    private func buildMissionControl(_ m: Materials) {
        let g = Entity()
        var body = MeshBuilder(), roof = MeshBuilder(), glass = MeshBuilder(), mast = MeshBuilder()
        block(&body, F3(0, 4, 0), F3(26, 8, 16))
        block(&glass, F3(0, 4.5, 8.05), F3(20, 3, 0.2))
        roof.prism([SIMD2(-14, 0), SIMD2(14, 0), SIMD2(0, 6.5)], halfThickness: 8.8)
        roof.positions = roof.positions.map { $0 + F3(0, 8, 0) }
        mast.beam(F3(8, 14, 0), F3(8, 22, 0), thickness: 0.35)
        mast.beam(F3(6, 19, 0), F3(10, 19, 0), thickness: 0.25)
        add(g, body, m.wallWarm, "controlBody")
        add(g, roof, m.roof, "controlRoof")
        add(g, glass, m.glass, "controlGlass")
        add(g, mast, m.metal, "controlMast")
        place(.missionControl, center: F3(0, 11, 0), half: F3(14, 11, 9), into: g)
    }

    /// Отряд космонавтов: низкий длинный корпус с навесом и флагом.
    private func buildAstronauts(_ m: Materials) {
        let g = Entity()
        var body = MeshBuilder(), awning = MeshBuilder(), glass = MeshBuilder(), pole = MeshBuilder(), flag = MeshBuilder()
        block(&body, F3(0, 2.5, 0), F3(38, 5, 14))
        block(&awning, F3(0, 5.4, 1), F3(41, 0.8, 17))
        for k in -7...7 { block(&glass, F3(Float(k) * 2.4, 2.8, 7.05), F3(1.4, 2, 0.2)) }
        pole.beam(F3(-22, 0, 9), F3(-22, 11, 9), thickness: 0.25)
        block(&flag, F3(-20.6, 9.7, 9), F3(2.8, 1.6, 0.1))
        add(g, body, m.wall, "astroBody")
        add(g, awning, m.accent, "astroAwning")
        add(g, glass, m.glass, "astroGlass")
        add(g, pole, m.metal, "astroPole")
        add(g, flag, m.accent, "astroFlag")
        place(.astronauts, center: F3(-0.5, 5.5, 0.5), half: F3(21, 5.5, 9), into: g)
    }

    /// Станция слежения: мачта с антенной-тарелкой и будка.
    private func buildTracking(_ m: Materials) {
        let g = Entity()
        var hut = MeshBuilder(), mast = MeshBuilder(), dish = MeshBuilder(), feed = MeshBuilder()
        block(&hut, F3(0, 2, 0), F3(9, 4, 9))
        // Мачта-ферма: четыре стойки и перекладины.
        for sx: Float in [-1, 1] {
            for sz: Float in [-1, 1] {
                mast.beam(F3(sx * 1.4, 4, sz * 1.4), F3(sx * 0.5, 26, sz * 0.5), thickness: 0.35)
            }
        }
        for y in stride(from: Float(7), through: 25, by: 3.6) {
            let k = 1.4 - (y - 4) / 22 * 0.9
            mast.beam(F3(-k, y, -k), F3(k, y, -k), thickness: 0.2)
            mast.beam(F3(-k, y, k), F3(k, y, k), thickness: 0.2)
            mast.beam(F3(-k, y, -k), F3(-k, y, k), thickness: 0.2)
            mast.beam(F3(k, y, -k), F3(k, y, k), thickness: 0.2)
        }
        // Тарелка: параболоид, повёрнутый к небу под углом.
        var bowl = MeshBuilder()
        var prof: [SIMD2<Float>] = []
        for i in 0...10 {
            let t = Float(i) / 10
            prof.append(SIMD2(8 * t, 3.2 * t * t))
        }
        bowl.lathe(prof, segments: 32, twoSided: true)
        feed.beam(F3(0, 0, 0), F3(0, 5.5, 0), thickness: 0.25)
        let tilt = simd_quatf(angle: -0.9, axis: F3(0, 0, 1))
        for var part in [bowl, feed] {
            part.positions = part.positions.map { tilt.act($0) + F3(0, 27.5, 0) }
            part.normals = part.normals.map { tilt.act($0) }
            dish.append(part)
        }
        add(g, hut, m.wall, "trackHut")
        add(g, mast, m.steel, "trackMast")
        add(g, dish, m.white, "trackDish")
        place(.tracking, center: F3(0, 16, 0), half: F3(8, 16, 8), into: g)
    }

    /// Стартовая площадка: бетонный диск, газоотвод и башня обслуживания рядом с ракетой.
    private func buildLaunchPad(_ m: Materials) {
        let g = Entity()
        var disc = MeshBuilder(), ring = MeshBuilder(), tower = MeshBuilder(), trench = MeshBuilder()
        disc.lathe([SIMD2(15, 0), SIMD2(15, 0.5), SIMD2(0, 0.5)], segments: 48)
        ring.lathe([SIMD2(9, 0.5), SIMD2(9, 0.53), SIMD2(8.4, 0.53), SIMD2(8.4, 0.5)], segments: 48)
        block(&trench, F3(0, 0.52, 0), F3(5, 0.06, 5))
        // Башня: четыре стойки, пояса, рука к ракете.
        let tx: Float = 8
        let top: Float = 30
        for sx: Float in [-1, 1] {
            for sz: Float in [-1, 1] {
                tower.beam(F3(tx + sx * 1.3, 0.5, sz * 1.3), F3(tx + sx * 1.3, top, sz * 1.3), thickness: 0.45)
            }
        }
        for y in stride(from: Float(3), through: top, by: 3.5) {
            tower.beam(F3(tx - 1.3, y, -1.3), F3(tx + 1.3, y, -1.3), thickness: 0.22)
            tower.beam(F3(tx - 1.3, y, 1.3), F3(tx + 1.3, y, 1.3), thickness: 0.22)
            tower.beam(F3(tx - 1.3, y, -1.3), F3(tx - 1.3, y, 1.3), thickness: 0.22)
            tower.beam(F3(tx + 1.3, y, -1.3), F3(tx + 1.3, y, 1.3), thickness: 0.22)
        }
        var arm = MeshBuilder()
        arm.beam(F3(tx - 1.3, 12, 0), F3(1.1, 12, 0), thickness: 0.5)
        arm.beam(F3(tx - 1.3, 11, 0), F3(2.5, 12, 0), thickness: 0.25)
        add(g, disc, m.concrete, "padDisc")
        add(g, ring, m.concreteDark, "padRing")
        add(g, trench, m.dark, "padTrench")
        add(g, tower, m.steel, "padTower")
        add(g, arm, m.accent, "padArm")
        place(.launchPad, center: F3(0, 16, 0), half: F3(15, 16, 15), into: g)
    }
}

/// Вьюха космоцентра: виртуальная камера, содержимое и камеру ведёт `SpaceCenterScene`.
struct SpaceCenterSceneView: View {
    let scene: SpaceCenterScene

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            // Вьюха может пересоздаваться, сцена живёт дольше: отцепить корень от прошлого родителя.
            scene.root.removeFromParent()
            content.add(scene.root)
        }
        .onAppear { scene.start() }
        .onDisappear { scene.stop() }
        .background(Color(red: 0.55, green: 0.72, blue: 0.9))
    }
}
