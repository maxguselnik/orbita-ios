import CoreGraphics
import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Сцена карты (поток B): Терра и Луна в масштабе карты, звёзды, орбита и SOI Луны,
/// траектория по участкам, орбита после узла, значок корабля; своя орбитальная камера.
/// Система координат — `MapScale`. Линии перестраиваются только при новом `MapSnapshot`
/// или заметной смене масштаба (толщина в точках экрана постоянна).
@MainActor
final class MapVisual {
    let root = Entity()
    /// Инерциальная система Терры в единицах карты, сдвинутая на −фокус.
    private let content = Entity()
    private var bodyEntities: [BodyID: ModelEntity] = [:]
    private var orbitEntities: [BodyID: ModelEntity] = [:]
    private let lunaGroup = Entity()
    private let soiSphere = ModelEntity()
    private let vesselMarker = ModelEntity()
    private let stars = Entity()
    private let sunLight = DirectionalLight()
    private let fillLight = DirectionalLight()
    /// По сущности на стиль линии.
    private var lineEntities: [MapLineStyle: ModelEntity] = [:]
    private var lineMaterials: [MapLineStyle: UnlitMaterial] = [:]

    var camera = MapCamera()
    var focus: MapFocus = .vessel {
        didSet {
            guard focus != oldValue else { return }
            focusFrom = view?.focus
            focusBlend = 0
            refocus = true
        }
    }
    var viewSize: CGSize = .zero
    /// Вид последнего кадра карты (для проекции); nil — карта ещё не показывалась.
    private(set) var view: MapViewState?

    private var map: MapSnapshot?
    /// Положение Луны на время снимка карты, единицы карты.
    private var lineOrigin = D3.zero
    private var polylines: [MapPolyline] = []
    private var staticLines: [MapPolyline] = []
    private var linesDirty = true
    private var staticDirty = true
    /// Масштаб (единиц на точку у фокуса), под который построены линии, — ступенями ×2^(1/3).
    private var builtScaleStep: Int?
    private var mesh = MeshBuilder()
    private var focusFrom: D3?
    private var focusBlend = 1.0
    private var refocus = false
    private var bodiesRequested = false
    private var materials: [BodyID: any Material] = [:]
    private let cloudBody = ModelEntity()
    private var cloudTime = 0.0
    private var bodyMeshes: [BodyID: MeshResource] = [:]
    var areBodiesReady: Bool { bodyMeshes.count == BodyID.allCases.count }

    init() {
        root.isEnabled = false
        root.addChild(content)
        root.addChild(stars)
        let sphere = MeshResource.generateSphere(radius: 1)
        for id in BodyID.allCases {
            let body = ModelEntity(mesh: sphere, materials: [SimpleMaterial(
                color: PlanetAppearance.color(id), roughness: 1, isMetallic: false)])
            body.scale = F3(repeating: Float(MapScale.radius(id)))
            content.addChild(body)
            bodyEntities[id] = body
            if Bodies.body(id).parent == .sol {
                let orbit = ModelEntity()
                content.addChild(orbit)
                orbitEntities[id] = orbit
            }
        }
        bodyEntities[.terra]?.addChild(cloudBody)
        cloudBody.scale = F3(repeating: Float(1 + CloudShell.height / Bodies.terra.radius))
        cloudBody.isEnabled = false
        content.addChild(lunaGroup)
        lunaGroup.addChild(soiSphere)
        content.addChild(vesselMarker)

        var soiMat = UnlitMaterial(color: UIColor(red: 0.55, green: 0.38, blue: 0.85, alpha: 1))
        soiMat.blending = .transparent(opacity: .init(floatLiteral: 0.06))
        soiSphere.model = ModelComponent(mesh: sphere, materials: [soiMat])
        soiSphere.scale = F3(repeating: Float(MapScale.lunaSOI))

        vesselMarker.model = ModelComponent(mesh: MeshResource.generateSphere(radius: 1), materials: [
            UnlitMaterial(color: UIColor(red: 0.55, green: 1.0, blue: 0.55, alpha: 1)),
        ])

        for style in MapLineStyle.allCases {
            let c = style.rgb
            lineMaterials[style] = UnlitMaterial(color: UIColor(red: CGFloat(c.x), green: CGFloat(c.y),
                                                                blue: CGFloat(c.z), alpha: 1))
            let e = ModelEntity()
            e.isEnabled = false
            content.addChild(e)
            lineEntities[style] = e
        }
        staticLines = [
            MapLines.circle(radius: MapScale.lunaOrbit, segments: 256, style: .lunaOrbit),
            MapLines.circle(radius: MapScale.lunaSOI, segments: 128, style: .lunaSOI),
        ]
        // Кольцо SOI — вокруг Луны, двигается вместе с ней.
        if let e = lineEntities[.lunaSOI] {
            e.removeFromParent()
            lunaGroup.addChild(e)
        }

        buildStars()

        let sd = f3(SkyVisual.sunDirection)
        sunLight.light.intensity = 6_000
        sunLight.light.color = UIColor(red: 1, green: 0.97, blue: 0.92, alpha: 1)
        sunLight.look(at: -sd, from: .zero, relativeTo: nil)
        root.addChild(sunLight)
        fillLight.light.intensity = 900
        fillLight.light.color = UIColor(red: 0.6, green: 0.7, blue: 1, alpha: 1)
        fillLight.look(at: sd, from: .zero, relativeTo: nil)
        root.addChild(fillLight)
    }

    // MARK: - Тела

    /// Материалы с готовыми атласами рельефа, когда готовы.
    func setMaterials(_ values: [BodyID: any Material]) {
        materials = values
        applyBodyModels()
    }

    /// Облачный слой Терры на карте (когда текстура готова).
    func setCloudTexture(_ tex: TextureResource?) {
        guard let tex, let mesh = CloudShell.unitSphere else { return }
        cloudBody.model = ModelComponent(mesh: mesh, materials: [CloudShell.material(tex, opacity: 0.75)])
        cloudBody.isEnabled = true
    }

    /// Кубосфера уровня 1 (24 патча рельефа) — один меш тела радиуса 1.
    nonisolated static func bodyMesh(_ body: BodyID) -> MeshBuilder {
        var out = MeshBuilder()
        let radius = Float(Bodies.body(body).radius)
        for face in UInt8(0)..<6 {
            for y in UInt32(0)..<2 {
                for x in UInt32(0)..<2 {
                    var geo = PatchBuilder.build(PatchKey(body: body, face: face, level: 1, x: x, y: y))
                    let c = f3(geo.center)
                    for i in geo.mesh.positions.indices {
                        geo.mesh.positions[i] = (geo.mesh.positions[i] + c) / radius
                    }
                    out.append(geo.mesh)
                }
            }
        }
        return out
    }

    private func requestBodies() {
        guard !bodiesRequested else { return }
        bodiesRequested = true
        Task { [weak self] in
            for id in BodyID.allCases {
                let geo = await Task.detached(priority: .userInitiated) { MapVisual.bodyMesh(id) }.value
                guard let self else { return }
                self.bodyMeshes[id] = geo.makeMesh(name: "map-" + id.rawValue)
                self.applyBodyModels()
            }
        }
    }

    private func applyBodyModels() {
        for id in BodyID.allCases {
            if let mesh = bodyMeshes[id], let material = materials[id] {
                bodyEntities[id]?.model = ModelComponent(mesh: mesh, materials: [material])
            }
        }
    }

    // MARK: - Данные

    func updateMap(_ snapshot: MapSnapshot) {
        map = snapshot
        polylines.removeAll(keepingCapacity: true)
        if let t = snapshot.trajectory {
            polylines += MapLines.polylines(t, plan: false, time: snapshot.time)
        }
        if let m = snapshot.maneuver {
            polylines += MapLines.polylines(m.trajectory, plan: true, time: snapshot.time)
        }
        linesDirty = true
    }

    /// Новый полёт: забыть данные и линии, камере — исходный ракурс при следующем показе.
    func reset() {
        map = nil
        polylines.removeAll()
        linesDirty = true
        camera = MapCamera()
        view = nil
        focusFrom = nil
        focusBlend = 1
        refocus = false
    }

    /// Шоу карты начинается: подготовить тела.
    func willShow() {
        requestBodies()
    }

    // MARK: - Кадр

    /// Фокус (единицы карты, система Терры) по живому снимку.
    private func focusPoint(_ s: WorldSnapshot) -> (point: D3, body: BodyID) {
        if let id = focus.bodyID {
            return (World.position(of: id, relativeTo: .terra, at: s.time).d3 / MapScale.metersPerUnit, id)
        }
        guard let v = s.vessels.first(where: { $0.id == s.activeVessel }) ?? s.vessels.first else {
            return (.zero, .terra)
        }
        let center = World.position(of: v.body, relativeTo: .terra, at: s.time).d3
        return ((v.position.d3 + center) / MapScale.metersPerUnit, v.body)
    }

    /// Исходное расстояние: видна вся текущая траектория (у Луны — в пределах её SOI).
    private func defaultDistance(focus f: D3, body: BodyID) -> Double {
        if focus == .sol { return Bodies.taros.orbitRadius / MapScale.metersPerUnit / MapScale.tanHalfFov * 1.15 }
        var extent = MapScale.radius(body) * 1.6
        if focus != .vessel { return extent / MapScale.tanHalfFov * 1.2 }
        let b = Bodies.body(body)
        let cap = b.soiRadius.isFinite ? b.soiRadius / MapScale.metersPerUnit : MapScale.maxDistance
        for line in polylines where !line.style.isPlan {
            for i in stride(from: 0, to: line.points.count, by: 4) {
                extent = max(extent, min(cap, simd_length(line.points[i] - f)))
            }
        }
        return extent / MapScale.tanHalfFov * 1.2
    }

    func update(snapshot s: WorldSnapshot, dt: Double, camera cam: PerspectiveCamera) {
        let (target, body) = focusPoint(s)
        let minDistance = MapScale.radius(body) * (focus == .vessel ? 1.0 : 2.0)
        camera.setLimits(min: minDistance)
        if camera.needsDefault {
            camera.setDefault(distance: defaultDistance(focus: target, body: body), snap: true)
            // Пока прогноза нет — ракурс по телу; уточнить, когда придёт.
            if map == nil { camera.needsDefault = true }
        } else if refocus {
            // Новый фокус: ракурс прежний, расстояние — чтобы была видна его орбита.
            camera.distance = defaultDistance(focus: target, body: body)
            camera.setLimits(min: minDistance)
        }
        refocus = false

        // Плавный перенос фокуса.
        var f = target
        if let from = focusFrom, focusBlend < 1 {
            focusBlend = min(1, focusBlend + dt / 0.6)
            let k = focusBlend * focusBlend * (3 - 2 * focusBlend)
            f = from + (target - from) * k
            if focusBlend >= 1 { focusFrom = nil }
        }

        var eye = camera.step(dt: dt)
        // Камера не внутри тел.
        var surface = Double.infinity
        for id in BodyID.allCases {
            let center = World.position(of: id, relativeTo: .terra, at: s.time).d3 / MapScale.metersPerUnit
            let r = MapScale.radius(id)
            let rel = f + eye - center
            let d = simd_length(rel)
            let minD = r * 1.05
            if d < minD, d > 1e-9 { eye += rel / d * (minD - d) }
            surface = min(surface, max(0, simd_length(f + eye - center) - r))
        }
        let dist = simd_length(eye)
        let near = clampd(0.3 * min(dist, surface), 0.005, 50)
        let far = max(dist * 4, dist + 4_000 + simd_length(f))
        let v = MapViewState(focus: f, eye: eye, near: near, size: viewSize)
        view = v

        // Вычитаем Double-фокус до преобразования в Float, даже у далёких планет.
        content.position = .zero
        for id in BodyID.allCases {
            let center = World.position(of: id, relativeTo: .terra, at: s.time).d3 / MapScale.metersPerUnit
            bodyEntities[id]?.position = f3(center - f)
            bodyEntities[id]?.orientation = quatf(RenderFrame.bodyRotation(id, time: s.time))
            if let parent = Bodies.body(id).parent {
                let origin = World.position(of: parent, relativeTo: .terra, at: s.time).d3 / MapScale.metersPerUnit
                orbitEntities[id]?.position = f3(origin - f)
            }
        }
        cloudTime += dt
        cloudBody.orientation = simd_quatf(angle: Float(CloudShell.driftRate * cloudTime), axis: F3(0, 0, 1))
        let luna = World.position(of: .luna, relativeTo: .terra, at: s.time).d3 / MapScale.metersPerUnit
        lunaGroup.position = f3(luna - f)
        let sun = World.position(of: .sol, relativeTo: .terra, at: s.time).d3 / MapScale.metersPerUnit
        let lightDirection = f3(simd_normalize(sun - f - eye))
        sunLight.look(at: -lightDirection, from: .zero, relativeTo: nil)
        fillLight.look(at: lightDirection, from: .zero, relativeTo: nil)
        if let active = s.vessels.first(where: { $0.id == s.activeVessel }) ?? s.vessels.first {
            let p = (active.position.d3 + World.position(of: active.body, relativeTo: .terra, at: s.time).d3) / MapScale.metersPerUnit
            vesselMarker.isEnabled = true
            vesselMarker.position = f3(p - f)
            let depth = max(near, simd_dot(p - f - eye, v.forward))
            vesselMarker.scale = F3(repeating: Float(v.unitsPerPoint(depth: depth) * 4.5))
        } else {
            vesselMarker.isEnabled = false
        }
        stars.position = f3(eye)
        stars.scale = F3(repeating: Float(far * 0.95))

        rebuildLinesIfNeeded(unitsPerPoint: v.unitsPerPoint(depth: dist))
        for (style, entity) in lineEntities {
            if style == .lunaOrbit { entity.position = f3(-f) }
            else if style != .lunaSOI { entity.position = f3(lineOrigin - f) }
        }

        cam.transform = Transform(scale: .one, rotation: v.rotation, translation: f3(eye))
        cam.camera.fieldOfViewInDegrees = Float(MapScale.fovDegrees)
        cam.camera.near = Float(near)
        cam.camera.far = Float(far)
    }

    private func rebuildLinesIfNeeded(unitsPerPoint upp: Double) {
        let step = Int((log2(max(upp, 1e-9)) * 3).rounded())
        let rescale = step != builtScaleStep
        let currentFocus = view?.focus ?? .zero
        let moved = simd_length(currentFocus - lineOrigin) > max(1, upp * 32)
        guard rescale || linesDirty || moved else { return }
        lineOrigin = currentFocus
        let width = pow(2, Double(step) / 3)
        if rescale || staticDirty {
            for line in staticLines { setLines([line], style: line.style, width: width) }
            for (id, entity) in orbitEntities {
                let body = Bodies.body(id)
                var line = MapLines.circle(radius: body.orbitRadius / MapScale.metersPerUnit,
                                           segments: 256, style: .lunaOrbit)
                let rotation = simd_quatd(angle: body.inclination, axis: D3(1, 0, 0))
                line.points = line.points.map { rotation.act($0) }
                line.normal = rotation.act(line.normal)
                var builder = MeshBuilder()
                MapLines.append(line, radius: width * 0.6, to: &builder)
                if let mesh = builder.makeMesh(name: "orbit-" + id.rawValue) {
                    entity.model = ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: PlanetAppearance.color(id))])
                }
            }
            staticDirty = false
        }
        for style in MapLineStyle.allCases where style != .lunaOrbit && style != .lunaSOI {
            setLines(polylines.filter { $0.style == style }, style: style, width: width)
        }
        builtScaleStep = step
        linesDirty = false
    }

    private func setLines(_ lines: [MapPolyline], style: MapLineStyle, width upp: Double) {
        guard let e = lineEntities[style] else { return }
        mesh.positions.removeAll(keepingCapacity: true)
        mesh.normals.removeAll(keepingCapacity: true)
        mesh.uvs.removeAll(keepingCapacity: true)
        mesh.indices.removeAll(keepingCapacity: true)
        let radius = style.width * upp / 2
        for source in lines {
            var line = source
            if style != .lunaOrbit && style != .lunaSOI {
                line.points = line.points.map { $0 - lineOrigin }
            }
            MapLines.append(line, radius: radius, to: &mesh)
        }
        guard let resource = mesh.makeMesh(name: "mapLine"), let mat = lineMaterials[style] else {
            if e.isEnabled { e.isEnabled = false }
            return
        }
        e.model = ModelComponent(mesh: resource, materials: [mat])
        if !e.isEnabled { e.isEnabled = true }
    }

    // MARK: - Проекция и выбор

    /// Точка в инерциальной системе тела (м, на время снимка карты) → экран.
    func project(_ position: Vec3, body: BodyID) -> CGPoint? {
        guard let view else { return nil }
        let center = World.position(of: body, relativeTo: .terra, at: map?.time ?? 0).d3
        let q = (position.d3 + center) / MapScale.metersPerUnit
        return view.project(q)
    }

    /// Время ближайшей к `point` точки текущей траектории (между соседними точками — интерполяция).
    func orbitPick(at point: CGPoint, maxDistance: CGFloat) -> Double? {
        guard let view else { return nil }
        let px = Double(point.x), py = Double(point.y)
        var best = Double(maxDistance)
        var bestTime: Double?
        for line in polylines where !line.style.isPlan && line.times.count == line.points.count {
            var prev: CGPoint? = nil
            for i in line.points.indices {
                let cur = view.project(line.points[i])
                defer { prev = cur }
                guard let a = prev, let b = cur, i > 0 else { continue }
                let ax = Double(a.x), ay = Double(a.y)
                let dx = Double(b.x) - ax, dy = Double(b.y) - ay
                let len2 = dx * dx + dy * dy
                let u = len2 > 1e-9 ? clampd(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1) : 0
                let ex = ax + dx * u - px, ey = ay + dy * u - py
                let d = (ex * ex + ey * ey).squareRoot()
                if d < best {
                    best = d
                    bestTime = line.times[i - 1] + (line.times[i] - line.times[i - 1]) * u
                }
            }
        }
        return bestTime
    }
}
