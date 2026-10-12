import OrbitPhysics
import RealityKit
import Testing
import UIKit
@testable import Orbita

@MainActor
@Suite("Регрессии рендера и HUD")
struct RenderAndHUDTests {
    @Test func automaticElevationPreservesManualCamera() {
        var rig = CameraRig()
        rig.setDefaultElevation(0.4)
        #expect(rig.elevation == 0.4)
        rig.apply(orbit: SIMD2(0, 0.2), zoom: 1, reset: false)
        let manual = rig.elevation
        rig.setDefaultElevation(0.45)
        #expect(rig.elevation == manual)
        rig.apply(orbit: .zero, zoom: 1, reset: true)
        #expect(rig.elevation == 0.45)
        rig.setDefaultElevation(0.3)
        #expect(rig.elevation == 0.3)
    }

    @Test func previewPickingAndAttachmentProjection() {
        let scene = HangarScene()
        let size = CGSize(width: 300, height: 300)
        #expect(scene.pickPart(at: CGPoint(x: 150, y: 150), viewSize: size) == nil)
        scene.show(parts: [.podK1], selected: nil)
        #expect(scene.pickPart(at: CGPoint(x: 150, y: 150), viewSize: size) == 0)
        #expect(scene.pickPart(at: .zero, viewSize: size) == nil)
        #expect(scene.nearestAttachment(at: CGPoint(x: 150, y: 130), viewSize: size) == 0)
        #expect(scene.nearestAttachment(at: CGPoint(x: 150, y: 170), viewSize: size) == 1)
    }

    @Test func chuteHintDoesNotMistakeUnlitLastEngineForParachute() {
        var advisor = FlightAdvisor()
        var t = FlightTelemetry(altitude: 10_000, surfaceSpeed: 100, verticalSpeed: -100,
                                situation: .suborbital, chute: .stowed, chuteSafe: true)
        t.mission.launched = true
        t.nextStageAction = .ignite
        advisor.update(t, throttle: 0, events: [], now: 0)
        #expect(advisor.hint == .chuteStages)
        t.nextStageAction = .armChute
        advisor.update(t, throttle: 0, events: [], now: 1)
        #expect(advisor.hint == .chute)
    }

    @Test func initialAndRestartThrottleMatchSimulation() {
        let model = FlightHUDModel(makeSimulation: {
            let sim = FlightSim(design: .orbit)
            sim.setInput(ControlInput(throttle: 0.65))
            _ = sim.advance(realDelta: 0) // опубликовать заданный ввод в снимке
            return sim
        })
        #expect(model.throttle == 0.65)
        model.throttle = 0.2
        model.tick(now: 1)
        #expect(model.throttle == 0.2)
        model.restart()
        #expect(model.throttle == 0.65)
    }

    @Test func autopilotThrottleIsReflectedInHUD() {
        let model = FlightHUDModel(makeSimulation: {
            ScenarioFlight(design: .orbit, goal: .orbit, keepAutopilot: true) { sim, _ in sim.time >= 1 }
        })
        #expect(model.throttle > 0)
        model.throttle = 0 // автопилот игнорирует ручной ввод в сцене отладки
        model.tick(now: 1)
        #expect(model.throttle > 0)
        #expect(model.throttle == model.snapshot.vessels.first?.throttle)
    }

    @Test func solidThrottleLocksOnlyWithoutLiquidEngines() {
        let solid = FlightHUDModel(makeSimulation: {
            let sim = FlightSim(design: .jump)
            sim.send(.stage)
            _ = sim.advance(realDelta: 0.1)
            return sim
        })
        #expect(solid.solidLocked)
        let mixed = FlightHUDModel(makeSimulation: {
            let sim = FlightSim(design: VesselDesign(name: "", parts: [.podK1, .t400, .vikhr, .molot]))
            sim.send(.stage)
            _ = sim.advance(realDelta: 0.1)
            return sim
        })
        #expect(mixed.telemetry.solidBurning)
        #expect(!mixed.solidLocked)
    }

    @Test func lodTransitionsNeverRenderParentAndChildrenTogether() async throws {
        let lod = PlanetLOD(body: .terra)
        lod.material = SimpleMaterial(color: .green, roughness: 1, isMetallic: false)
        // Сначала высокая детализация, затем соседний участок и укрупнение:
        // посещение готовых детей ради кеша не должно оставлять их видимыми под родителем.
        for eye in [D3(Bodies.terra.radius + 500, 0, 0), D3(Bodies.terra.radius + 500, 4_000, 0),
                    D3(Bodies.terra.radius * 3, 0, 0)] {
            for _ in 0..<100 {
                lod.update(eyeBF: eye, center: -eye, rotation: .init(), scale: 1)
                let patches = lod.renderedPatches
                for a in patches {
                    for b in patches where b.face == a.face && b.level > a.level {
                        let shift = UInt32(b.level - a.level)
                        #expect(b.x >> shift != a.x || b.y >> shift != a.y,
                                "Одновременно видны родитель и потомок: \(a), \(b)")
                    }
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(!lod.renderedPatches.isEmpty)
    }
}
