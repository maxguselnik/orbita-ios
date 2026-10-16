import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Рендер полёта (поток B).
///
/// Floating origin: мир рендера — инерциальная система тела активного корабля, сдвинутая так,
/// что камера всегда в нуле. Всё считается в Double и переводится в Float только относительно камеры.
/// Глубина: динамическая ближняя плоскость по расстоянию до корабля и грунта; планеты дальше
/// ~30 км от камеры рисуются уменьшенными копиями ближе к камере с тем же угловым размером
/// (масштаб вокруг камеры), другое тело — не дальше 1.6 тыс. км; небо — сфера 4 тыс. км.
@MainActor
final class SceneRenderer: FlightRenderer {
    var cameraMode: CameraMode = .follow {
        didSet {
            if cameraMode != oldValue { rig.defaultAzimuth = cameraMode == .heading ? 0 : -2.1 }
        }
    }

    /// Корень сцены; добавляется в RealityView.
    let root = Entity()
    /// Всё полётное (тела, корабли, эффекты, небо); в режиме карты выключено.
    private let flightRoot = Entity()
    /// Сцена карты.
    private let map = MapVisual()
    private let camera = PerspectiveCamera()
    private let sky = SkyVisual()
    private let planets = Dictionary(uniqueKeysWithValues: BodyID.allCases.map { ($0, PlanetLOD(body: $0)) })
    private let pad = PadVisual()
    private var vessels: [VesselID: VesselVisual] = [:]
    private var rig = CameraRig()
    private var lastActive: VesselID?
    private var renderTime = 0.0
    private var seen: Set<VesselID> = []
    private var explosions: [ExplosionVisual] = []
    private var exploded: Set<VesselID> = []
    private let atmosphere = AtmosphereVisual()
    private let otherAtmospheres = Dictionary(uniqueKeysWithValues: [BodyID.vella, .arda, .taros].map {
        ($0, AtmosphereVisual(body: $0))
    })
    private let clouds = CloudVisual()
    private let backdrop = GroundBackdrop()
    private let cloudShell = CloudShell()
    private let effects = VesselEffects()
    private var governor = QualityGovernor()
    private var shake = CameraShake()
    /// Желаемая частота кадров (из настроек) — для авто-качества.
    var targetFrameRate: Double = 90
    /// Только диагностический кадр -planet-preview: общий план тела в настоящей полётной сцене.
    /// В обычной игре nil: камера и все эффекты работают как прежде.
    var inspectionBody: BodyID?
    /// Только для нативного диагностического кадра поверхности с малой высоты.
    var inspectionCloseup = false
    private(set) var hasSurfaceTextures = false
    private var hasCloudTexture = false
    private var hasSurfaceDetail = false

    /// Готовность именно отрисованного тела для диагностического кадра.
    var isInspectionReady: Bool {
        guard hasSurfaceTextures, hasCloudTexture || !CloudShell.enabled || !SoftTextures.enabled else { return false }
        if isMapMode { return map.areBodiesReady }
        if inspectionCloseup {
            guard let lod = planets[inspectionBody ?? .terra] else { return false }
            return hasSurfaceDetail && lod.finestVisibleLevel == 10
        }
        return (planets[inspectionBody ?? .terra]?.visibleCount ?? 0) > 0
    }

    init() {
        camera.camera.fieldOfViewInDegrees = 60
        camera.camera.near = 0.1
        camera.camera.far = Self.flightFar
        SoftTextures.shared.start()
        root.addChild(camera)
        root.addChild(flightRoot)
        root.addChild(map.root)
        flightRoot.addChild(sky.root)
        for body in BodyID.allCases {
            if let lod = planets[body] { flightRoot.addChild(lod.root) }
        }
        flightRoot.addChild(pad.root)
        flightRoot.addChild(atmosphere.root)
        for visual in otherAtmospheres.values { flightRoot.addChild(visual.root) }
        flightRoot.addChild(clouds.root)
        flightRoot.addChild(backdrop.root)
        flightRoot.addChild(cloudShell.root)
        flightRoot.addChild(effects.root)
        pad.root.isEnabled = false

        Task { [weak self] in
            var materials: [BodyID: any Material] = [:]
            var texturesReady = true
            var detailReady = true
            for body in BodyID.allCases {
                let texture = await PlanetTextures.load(body)
                let material = TerrainMaterial.make(texture, body: body)
                guard let self else { return }
                self.planets[body]?.material = material
                materials[body] = material
                if body != .sol { texturesReady = texturesReady && texture != nil }
                if Bodies.body(body).hasSolidSurface { detailReady = detailReady && material is CustomMaterial }
            }
            guard let self else { return }
            self.map.setMaterials(materials)
            self.hasSurfaceDetail = detailReady
            self.hasSurfaceTextures = texturesReady
            // Облачный слой готовится после загрузки атласов: рельеф уже виден.
            let cloudTex = await CloudShell.makeTexture()
            self.cloudShell.setTexture(cloudTex)
            self.map.setCloudTexture(cloudTex)
            self.hasCloudTexture = cloudTex != nil
        }
    }

    func apply(_ input: CameraInput) {
        if isMapMode {
            if input.reset {
                map.camera.needsDefault = true
            } else {
                map.camera.apply(orbit: input.orbitDelta, zoom: input.zoomFactor)
            }
            return
        }
        rig.apply(orbit: input.orbitDelta, zoom: input.zoomFactor, reset: input.reset)
    }

    // MARK: - Карта

    var isMapMode = false {
        didSet {
            guard isMapMode != oldValue else { return }
            flightRoot.isEnabled = !isMapMode
            map.root.isEnabled = isMapMode
            if isMapMode {
                map.willShow()
            } else {
                // Полётная камера: следующий `update` вернёт положение, поле зрения и ближнюю плоскость.
                camera.camera.far = Self.flightFar
            }
        }
    }

    var mapFocus: MapFocus {
        get { map.focus }
        set { map.focus = newValue }
    }

    var viewSize: CGSize {
        get { map.viewSize }
        set { map.viewSize = newValue }
    }

    func updateMap(_ snapshot: MapSnapshot) {
        map.updateMap(snapshot)
    }

    func project(_ position: Vec3, body: BodyID) -> CGPoint? {
        guard isMapMode else { return nil }
        return map.project(position, body: body)
    }

    func orbitPick(at point: CGPoint, maxDistance: CGFloat) -> Double? {
        guard isMapMode else { return nil }
        return map.orbitPick(at: point, maxDistance: maxDistance)
    }

    private static let flightFar: Float = 1.0e7

    /// Новый полёт: убрать корабли, обломки и эффекты, сбросить камеру и внутреннее состояние.
    func reset() {
        for vis in vessels.values { vis.root.removeFromParent() }
        vessels.removeAll()
        for e in explosions { e.root.removeFromParent() }
        explosions.removeAll()
        exploded.removeAll()
        seen.removeAll()
        lastActive = nil
        renderTime = 0
        rig = CameraRig()
        rig.defaultAzimuth = cameraMode == .heading ? 0 : -2.1
        pad.root.isEnabled = false
        atmosphere.reset()
        for visual in otherAtmospheres.values { visual.reset() }
        clouds.reset()
        backdrop.reset()
        cloudShell.reset()
        effects.reset()
        shake = CameraShake()
        map.reset()
    }

    func update(snapshot: WorldSnapshot, events: [SimEvent], frameDelta: Double) {
        if isMapMode {
            // Полёт не обновляется: только карта и её камера.
            map.update(snapshot: snapshot, dt: frameDelta, camera: camera)
            return
        }
        guard let active = snapshot.vessels.first(where: { $0.id == snapshot.activeVessel }) ?? snapshot.vessels.first
        else { return }
        renderTime += frameDelta
        let quality = governor.update(dt: frameDelta, target: 1 / max(30, targetFrameRate))
        let frame = active.body
        // Разрушение детали: вспышка на её месте — до пересборки модели по новым parts/layout.
        for e in events {
            if case .partDestroyed(let id) = e { vessels[active.id]?.flash(part: id) }
        }
        let activeVisual = visual(for: active)

        // Камера: цель — середина стека.
        let pos = active.position.d3
        let attitude = active.attitude.quatd
        let nose = attitude.act(D3(0, 1, 0))
        let height = activeVisual.stackHeight
        let target = pos + nose * (height / 2)
        let radial = simd_normalize(pos)
        let switched = lastActive != active.id
        lastActive = active.id
        if switched { effects.reset() }
        rig.setDefaultDistance(max(height * 1.7, 14), snap: switched)
        // Плавно раскрывать горизонт на подъёме; ручное вращение сохраняется.
        let altitude = simd_length(pos) - Bodies.body(active.body).radius
        rig.setDefaultElevation(0.12 + 0.33 * clampd(altitude / 70_000, 0, 1))

        let forward: D3, up: D3
        switch cameraMode {
        case .free:
            up = D3(0, 0, 1)
            forward = D3(1, 0, 0)
        case .follow:
            up = radial
            forward = D3(0, 0, 1)
        case .heading:
            up = radial
            var v = active.velocity.d3
            if simd_length(pos) - Bodies.body(frame).radius < Bodies.body(frame).atmosphereHeight {
                v -= simd_cross(World.spin(frame).d3, pos)
            }
            forward = simd_length(v) > 3 ? -simd_normalize(v) : -nose
        }
        let cam = rig.offset(forward: forward, up: up, dt: switched ? 0 : frameDelta)
        var eye = target + cam.offset
        if let inspectionBody {
            let center = RenderFrame.bodyCenter(inspectionBody, in: frame, time: snapshot.time)
            let direction = PlanetInspection.direction(inspectionBody).d3
            if inspectionCloseup {
                let radial = simd_normalize(direction)
                let h = Terrain.surfaceHeight(body: inspectionBody, direction: vec3(radial))
                eye = center + RenderFrame.bodyRotation(inspectionBody, time: snapshot.time)
                    .act(radial * (Bodies.body(inspectionBody).radius + h + 160))
            } else {
                eye = center + simd_normalize(direction) * Bodies.body(inspectionBody).radius * PlanetInspection.distance(inspectionBody)
            }
        }

        // Камера не уходит под грунт.
        let body = Bodies.body(frame)
        let rot = RenderFrame.bodyRotation(frame, time: snapshot.time)
        let eyeDir = simd_normalize(eye)
        let ground = Terrain.surfaceHeight(body: frame, direction: vec3(rot.inverse.act(eyeDir)))
        var clearance = simd_length(eye) - body.radius - ground
        let minClearance = 1.5
        if clearance < minClearance {
            eye += eyeDir * (minClearance - clearance)
            clearance = minClearance
        }

        let sunDirection = simd_normalize(RenderFrame.bodyCenter(.sol, in: frame, time: snapshot.time) - eye)
        sky.setSun(direction: sunDirection)

        // Тела: позиция, поворот, масштаб-импостор.
        let camToTarget = simd_length(target - eye)
        var terraScale = 1.0
        var bodyScales: [BodyID: Double] = [:]
        var renderExtent = 0.0
        for b in BodyID.allCases {
            guard let lod = planets[b] else { continue }
            let center = RenderFrame.bodyCenter(b, in: frame, time: snapshot.time) - eye
            let brot = RenderFrame.bodyRotation(b, time: snapshot.time)
            let dist = simd_length(center)
            var scale = 1.0
            if b == frame {
                let nearest = dist - Bodies.body(b).radius
                // Импостор только на большой высоте: рельеф до 150 км рисуется в натуральную величину,
                // иначе земля у горизонта «ползёт» относительно корабля и эффектов.
                let keep = max(150_000, 4 * camToTarget)
                if nearest > keep { scale = keep / nearest }
            } else {
                scale = min(1, 1.6e6 / dist)
            }
            renderExtent = max(renderExtent, (dist + Bodies.body(b).radius) * scale)
            bodyScales[b] = scale
            if b == .terra { terraScale = scale }
            lod.update(eyeBF: brot.inverse.act(-center), center: center, rotation: brot, scale: scale)
        }

        // Небо всегда за всей видимой геометрией, включая большой газовый гигант.
        // Масштабируем только фон: положение и глубина планеты относительно корабля сохраняются.
        let skyScale = Float(max(1, renderExtent / (Double(SkyVisual.starRadius) * 0.8)))
        sky.root.scale = F3(repeating: skyScale)
        camera.camera.far = max(Self.flightFar, SkyVisual.skyRadius * skyScale * 1.1)

        // Площадка.
        let terraCenter = RenderFrame.bodyCenter(.terra, in: frame, time: snapshot.time) - eye
        let terraRot = RenderFrame.bodyRotation(.terra, time: snapshot.time)
        let padRel = terraCenter + terraRot.act(pad.positionBF)
        let padOn = terraScale == 1 && simd_length(padRel) < 150_000
        if pad.root.isEnabled != padOn { pad.root.isEnabled = padOn }
        if padOn {
            pad.root.transform = Transform(scale: .one, rotation: quatf(terraRot * pad.rotationBF), translation: f3(padRel))
        }

        // Корабли, включая отделённые ступени.
        seen.removeAll(keepingCapacity: true)
        for v in snapshot.vessels {
            seen.insert(v.id)
            let vis = visual(for: v)
            let rel = RenderFrame.bodyCenter(v.body, in: frame, time: snapshot.time) + v.position.d3 - eye
            // Разбившийся корабль скрыт: вместо него взрыв и обломки.
            let on = simd_length(rel) < 300_000 && !v.parts.isEmpty && v.situation != .crashed
            if vis.root.isEnabled != on { vis.root.isEnabled = on }
            guard on else { continue }
            let pressure: Double
            if v.id == active.id {
                pressure = snapshot.telemetry.staticPressure
            } else {
                let b = Bodies.body(v.body)
                pressure = b.relativePressure(altitude: simd_length(v.position.d3) - b.radius)
            }
            vis.update(v, relativePosition: rel, pressure: pressure, time: renderTime)
        }
        // Авария активного корабля: один взрыв на корабль.
        let crashEvent = events.contains { if case .crash = $0 { return true } else { return false } }
        if active.situation == .crashed || crashEvent {
            if exploded.insert(active.id).inserted {
                let dir = simd_normalize(pos)
                let gh = Terrain.surfaceHeight(body: frame, direction: vec3(rot.inverse.act(dir)))
                let ex = ExplosionVisual(body: frame, center: dir * (body.radius + gh), up: dir,
                                         size: max(activeVisual.stackHeight * 0.5, 3), seed: active.id &+ 7,
                                         startTime: renderTime)
                ex.fixedDirection = World.toBodyFixed(vec3(dir), body: frame, time: snapshot.time)
                ex.fixedRadius = body.radius + gh
                explosions.append(ex)
                flightRoot.addChild(ex.root)
            }
        } else {
            exploded.remove(active.id)
        }
        for ex in explosions {
            // Точка аварии вращается вместе с телом.
            let up = World.fromBodyFixed(ex.fixedDirection, body: ex.body, time: snapshot.time).d3
            ex.up = up
            ex.center = up * ex.fixedRadius
            let rel = RenderFrame.bodyCenter(ex.body, in: frame, time: snapshot.time) + ex.center - eye
            let on = simd_length(rel) < 300_000
            if ex.root.isEnabled != on { ex.root.isEnabled = on }
            guard on else { continue }
            ex.update(time: renderTime)
            ex.root.transform = Transform(scale: .one, rotation: simd_quatf(from: F3(0, 1, 0), to: f3(ex.up)),
                                          translation: f3(rel))
        }
        for id in vessels.keys where !seen.contains(id) {
            vessels[id]?.root.removeFromParent()
            vessels[id] = nil
        }

        // Небо: темнеет с высотой и ночью.
        let localUp = simd_normalize(eye - RenderFrame.bodyCenter(frame, in: frame, time: snapshot.time))
        var brightness = 0.0
        if body.atmosphereHeight > 0 {
            let alt = simd_length(eye) - body.radius
            if alt < body.atmosphereHeight {
                let atm = pow(exp(-max(0, alt) / body.scaleHeight), 0.3)
                let day = clampd(simd_dot(localUp, sunDirection) * 2.5 + 0.35, 0.03, 1)
                brightness = atm * day
            }
        }
        sky.update(up: localUp, brightness: brightness, body: frame)
        sky.setFill(luna: body.atmosphereHeight == 0)

        // Атмосфера Терры: дымка, ореол, облака.
        let terraRel = RenderFrame.bodyCenter(.terra, in: frame, time: snapshot.time) - eye
        let atmo = AtmosphereFrame(
            time: renderTime, dt: frameDelta, terraCenter: terraRel, terraRotation: terraRot, terraScale: terraScale,
            up: simd_normalize(-terraRel), altitude: simd_length(terraRel) - Bodies.terra.radius,
            skyBrightness: brightness, sun: sunDirection, frameBody: frame, quality: quality)
        atmosphere.update(atmo)
        for (id, visual) in otherAtmospheres {
            var local = atmo
            let center = RenderFrame.bodyCenter(id, in: frame, time: snapshot.time) - eye
            local.terraCenter = center
            local.terraRotation = RenderFrame.bodyRotation(id, time: snapshot.time)
            local.terraScale = bodyScales[id] ?? 1
            local.up = simd_normalize(-center)
            local.altitude = simd_length(center) - Bodies.body(id).radius
            local.skyBrightness = frame == id ? brightness : 0
            visual.update(local)
        }
        clouds.update(atmo)
        backdrop.update(atmo)
        cloudShell.update(atmo)

        // Эффекты активного корабля: дым, потоки воздуха, конденсация, плазма.
        let t = snapshot.telemetry
        let wind = simd_cross(World.spin(frame).d3, pos)
        let groundUnder = Terrain.surfaceHeight(body: frame, direction: vec3(rot.inverse.act(radial)))
        effects.update(VesselEffectFrame(
            time: renderTime, dt: frameDelta, vessel: active, vesselRel: pos - eye,
            stackHeight: activeVisual.stackHeight, halfWidth: activeVisual.halfWidth,
            nozzlePositions: activeVisual.nozzlePositions,
            airVelocity: active.velocity.d3 - wind, windVelocity: wind, up: radial,
            heightAboveGround: t.heightAboveTerrain, groundRel: radial * (body.radius + groundUnder) - eye,
            telemetry: t, daylight: clampd(simd_dot(radial, sunDirection) * 2.5 + 0.35, 0.03, 1),
            quality: quality))

        // Камера в нуле; ближняя плоскость — по ближайшему объекту.
        // Смотрим чуть ниже цели: корабль выше центра кадра, факел и земля не под навболом.
        // Тряска по скоростному напору, тяге и событиям — угловое смещение точки взгляда.
        let jolt = shake.update(telemetry: snapshot.telemetry, events: events, time: renderTime, dt: frameDelta)
        let side = simd_normalize(simd_cross(cam.up, target - eye))
        let lookPoint = target - cam.up * (camToTarget * (0.12 - jolt.y)) + side * (camToTarget * jolt.x)
        camera.look(at: f3(lookPoint - eye), from: .zero, upVector: f3(cam.up), relativeTo: nil)
        camera.camera.fieldOfViewInDegrees = Float(60 + 5 * shake.speedFeel)
        if let inspectionBody {
            let center = RenderFrame.bodyCenter(inspectionBody, in: frame, time: snapshot.time)
            var look = center - eye
            if inspectionCloseup {
                let radial = simd_normalize(eye - center)
                let along = simd_normalize(simd_cross(D3(0, 0, 1), radial))
                // Косой взгляд: видны и фактура рядом с камерой, и уходящие вдаль склоны.
                look = along * 180 - radial * 160
            }
            camera.look(at: f3(look), from: .zero, upVector: F3(0, 0, 1), relativeTo: nil)
            camera.camera.fieldOfViewInDegrees = Float(MapScale.fovDegrees)
        }
        let toVessel = max(0.1, camToTarget - activeVisual.boundingRadius)
        // Ближняя плоскость мала, пока камера у корабля: факел длиной с корабль не должен
        // обрезаться у камеры; дальность глубины на горизонте для рельефа не критична.
        var near = clampd(0.08 * min(toVessel, clearance), 0.05, 1_000)
        if camToTarget < 300 { near = min(near, 0.6) }
        if clearance < 500 { near = min(near, 0.5) }
        camera.camera.near = Float(near)
    }

    private func visual(for v: VesselState) -> VesselVisual {
        if let vis = vessels[v.id] {
            if vis.parts != v.parts || vis.sourceLayoutCount != v.layout.count {
                vis.rebuild(parts: v.parts, layout: v.layout)
            }
            return vis
        }
        let vis = VesselVisual(parts: v.parts, layout: v.layout)
        vessels[v.id] = vis
        flightRoot.addChild(vis.root)
        return vis
    }
}
