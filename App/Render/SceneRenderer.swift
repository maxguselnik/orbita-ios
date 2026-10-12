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
    private let camera = PerspectiveCamera()
    private let sky = SkyVisual()
    private let terra = PlanetLOD(body: .terra)
    private let luna = PlanetLOD(body: .luna)
    private let pad = PadVisual()
    private var vessels: [VesselID: VesselVisual] = [:]
    private var rig = CameraRig()
    private var lastActive: VesselID?
    private var renderTime = 0.0
    private var seen: Set<VesselID> = []

    init() {
        camera.camera.fieldOfViewInDegrees = 60
        camera.camera.near = 0.1
        camera.camera.far = 1.0e7
        root.addChild(camera)
        root.addChild(sky.root)
        root.addChild(terra.root)
        root.addChild(luna.root)
        root.addChild(pad.root)
        pad.root.isEnabled = false

        Task { [weak self] in
            let terraTex = await Palette.texture([Palette.terraRow, Palette.terraPolarRow])
            let lunaTex = await Palette.texture([Palette.lunaRow, Palette.lunaCraterRow])
            guard let self else { return }
            self.terra.material = Self.terrainMaterial(terraTex, fallback: UIColor(red: 0.25, green: 0.42, blue: 0.22, alpha: 1))
            self.luna.material = Self.terrainMaterial(lunaTex, fallback: UIColor(white: 0.5, alpha: 1))
        }
    }

    private static func terrainMaterial(_ tex: TextureResource?, fallback: UIColor) -> any Material {
        guard let tex else { return SimpleMaterial(color: fallback, roughness: 0.95, isMetallic: false) }
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .white, texture: .init(tex))
        m.roughness = .init(floatLiteral: 0.93)
        m.metallic = .init(floatLiteral: 0)
        // Без бликов: иначе по краю диска с орбиты Френель отражает студийное окружение (бежевая «дымка»).
        m.specular = .init(floatLiteral: 0)
        return m
    }

    func apply(_ input: CameraInput) {
        rig.apply(orbit: input.orbitDelta, zoom: input.zoomFactor, reset: input.reset)
    }

    func update(snapshot: WorldSnapshot, events: [SimEvent], frameDelta: Double) {
        guard let active = snapshot.vessels.first(where: { $0.id == snapshot.activeVessel }) ?? snapshot.vessels.first
        else { return }
        renderTime += frameDelta
        let frame = active.body
        let luna = snapshot.lunaPosition.d3
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
        rig.setDefaultDistance(max(height * 1.7, 14), snap: switched)
        if switched {
            // Высоко над телом — смотреть сверху, чтобы была видна кривизна; у земли — почти горизонтально.
            let alt = simd_length(pos) - Bodies.body(active.body).radius
            rig.setDefaultElevation(alt > 30_000 ? 0.45 : 0.12)
        }

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
            if frame == .terra, simd_length(pos) - Bodies.terra.radius < Bodies.terra.atmosphereHeight {
                v -= simd_cross(World.spin(.terra).d3, pos)
            }
            forward = simd_length(v) > 3 ? -simd_normalize(v) : -nose
        }
        let cam = rig.offset(forward: forward, up: up, dt: switched ? 0 : frameDelta)
        var eye = target + cam.offset

        // Камера не уходит под грунт.
        let body = Bodies.body(frame)
        let rot = RenderFrame.bodyRotation(frame, terraRotation: snapshot.terraRotation)
        let eyeDir = simd_normalize(eye)
        let ground = Terrain.surfaceHeight(body: frame, direction: vec3(rot.inverse.act(eyeDir)))
        var clearance = simd_length(eye) - body.radius - ground
        let minClearance = 1.5
        if clearance < minClearance {
            eye += eyeDir * (minClearance - clearance)
            clearance = minClearance
        }

        // Тела: позиция, поворот, масштаб-импостор.
        let camToTarget = simd_length(target - eye)
        var terraScale = 1.0
        for b in [BodyID.terra, .luna] {
            let lod = b == .terra ? terra : self.luna
            let center = RenderFrame.bodyCenter(b, in: frame, luna: luna) - eye
            let brot = RenderFrame.bodyRotation(b, terraRotation: snapshot.terraRotation)
            let dist = simd_length(center)
            var scale = 1.0
            if b == frame {
                let nearest = dist - Bodies.body(b).radius
                let keep = max(30_000, 4 * camToTarget)
                if nearest > keep { scale = keep / nearest }
            } else {
                scale = min(1, 1.6e6 / dist)
            }
            if b == .terra { terraScale = scale }
            lod.update(eyeBF: brot.inverse.act(-center), center: center, rotation: brot, scale: scale)
        }

        // Площадка.
        let terraCenter = RenderFrame.bodyCenter(.terra, in: frame, luna: luna) - eye
        let terraRot = RenderFrame.bodyRotation(.terra, terraRotation: snapshot.terraRotation)
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
            let rel = RenderFrame.bodyCenter(v.body, in: frame, luna: luna) + v.position.d3 - eye
            let on = simd_length(rel) < 300_000 && !v.parts.isEmpty
            if vis.root.isEnabled != on { vis.root.isEnabled = on }
            guard on else { continue }
            let pressure: Double
            if v.id == active.id {
                pressure = snapshot.telemetry.staticPressure
            } else if v.body == .terra {
                pressure = exp(-max(0, simd_length(v.position.d3) - Bodies.terra.radius) / Bodies.terra.scaleHeight)
            } else {
                pressure = 0
            }
            vis.update(v, relativePosition: rel, pressure: pressure, time: renderTime)
        }
        for id in vessels.keys where !seen.contains(id) {
            vessels[id]?.root.removeFromParent()
            vessels[id] = nil
        }

        // Небо: темнеет с высотой и ночью.
        let localUp = simd_normalize(eye - RenderFrame.bodyCenter(frame, in: frame, luna: luna))
        var brightness = 0.0
        if frame == .terra {
            let alt = simd_length(eye) - Bodies.terra.radius
            if alt < Bodies.terra.atmosphereHeight {
                let atm = pow(exp(-max(0, alt) / Bodies.terra.scaleHeight), 0.3)
                let day = clampd(simd_dot(localUp, SkyVisual.sunDirection) * 2.5 + 0.35, 0.03, 1)
                brightness = atm * day
            }
        }
        sky.update(up: localUp, brightness: brightness)

        // Камера в нуле; ближняя плоскость — по ближайшему объекту.
        let toTarget = f3(target - eye)
        camera.look(at: toTarget, from: .zero, upVector: f3(cam.up), relativeTo: nil)
        let toVessel = max(0.1, camToTarget - activeVisual.boundingRadius)
        var near = clampd(0.25 * min(toVessel, clearance), 0.05, 1_000)
        if clearance < 500 { near = min(near, 0.5) }
        camera.camera.near = Float(near)
    }

    private func visual(for v: VesselState) -> VesselVisual {
        if let vis = vessels[v.id] {
            if vis.parts != v.parts { vis.rebuild(v.parts) }
            return vis
        }
        let vis = VesselVisual(parts: v.parts)
        vessels[v.id] = vis
        root.addChild(vis.root)
        return vis
    }
}
