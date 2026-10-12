import OrbitPhysics
import RealityKit
import SwiftUI
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

    @Test func ascentTargetPitchInterpolatesByAltitude() {
        #expect(AscentGuide.targetPitchDegrees(altitude: 0) == 90)
        #expect(AscentGuide.targetPitchDegrees(altitude: 1_000) == 90)
        #expect(abs(AscentGuide.targetPitchDegrees(altitude: 10_000) - 45) < 1e-9)
        #expect(abs(AscentGuide.targetPitchDegrees(altitude: 45_000) - 10) < 1e-9)
        #expect(AscentGuide.targetPitchDegrees(altitude: 80_000) == 0)
        let mid = AscentGuide.targetPitchDegrees(altitude: 5_500)
        #expect(mid > 45 && mid < 90)
    }

    @Test func ascentAdviceFollowsFlightPhases() {
        var t = FlightTelemetry(situation: .prelaunch)
        t.nextStageAction = .ignite
        #expect(AscentGuide.advice(t)?.text == "Зажигание → Тяга MAX")

        t = FlightTelemetry(altitude: 20_000, situation: .suborbital, pitch: 1.0, heading: .pi / 2)
        t.mission.launched = true
        t.thrust = 1_000
        let turning = AscentGuide.advice(t)
        #expect(turning?.text.contains("нос выше") == true)
        #expect(turning?.targetPitch != nil)

        t.orbit = OrbitSummary(body: .terra, apoapsisAltitude: 85_000, periapsisAltitude: -300_000,
                               timeToApoapsis: 100, timeToPeriapsis: nil, eccentricity: 0.9, inclination: 0, period: 3_000)
        #expect(AscentGuide.advice(t)?.text == "Ап 80 км — тяга 0")

        t.altitude = 80_000
        t.thrust = 0
        #expect(AscentGuide.advice(t)?.text.contains("ПРОГРАДИЕНТ") == true)

        t.orbit?.periapsisAltitude = 80_000
        #expect(AscentGuide.advice(t)?.text == "Вы на орбите")
        #expect(AscentGuide.advice(t)?.targetPitch == nil)
    }

    @Test func warpWindowKeepsCurrentLevelVisible() {
        #expect(WarpButtons.window(current: 0) == [0, 1, 2])
        #expect(WarpButtons.window(current: 3) == [2, 3, 4])
        let last = TimeWarp.levels.count - 1
        #expect(WarpButtons.window(current: last) == [last - 2, last - 1, last])
    }

    @Test func odometerShowsSixDigitsAndSwitchesToKilometers() {
        let low = AltimeterReading(altitude: 11_704.9)
        #expect(low.digits.joined() == "011704")
        #expect(low.unit == "м")
        let high = AltimeterReading(altitude: 1_234_567)
        #expect(high.digits.joined() == "001234")
        #expect(high.unit == "км")
        #expect(AltimeterReading(altitude: -5).digits.joined() == "000000")
        #expect(AtmosphereScale.markerPosition(altitude: 0) == 1)
        #expect(AtmosphereScale.markerPosition(altitude: 70_000) == 0)
    }

    @Test func stageGroupsFollowDecouplersAndTelemetry() {
        let design = VesselDesign.orbit
        let groups = StageGroup.groups(parts: design.parts, stages: design.stageInfos())
        #expect(groups.map(\.number) == [3, 2, 1])
        #expect(groups.first?.items.map(\.kind) == [.chute, .pod])
        #expect(groups.last?.isCurrent == true)
        #expect(groups.last?.items.contains { $0.kind == .tank && $0.count == 2 } == true)
        // Без деталей — заглушка по флагам ступени.
        let stub = StageGroup.groups(parts: [], stages: design.stageInfos())
        #expect(stub.count == 3)
        #expect(stub.last?.items.map(\.kind) == [.tank, .engine])
    }

    @Test func throttleArcMapsTouchAngleToFraction() {
        let center = CGPoint(x: 50, y: 50)
        func touch(_ degrees: Double) -> CGPoint {
            let r = degrees * .pi / 180
            return CGPoint(x: 50 + 40 * cos(r), y: 50 + 40 * sin(r))
        }
        #expect(abs(GaugeMath.fraction(forTouch: touch(145), center: center)) < 1e-6)
        #expect(abs(GaugeMath.fraction(forTouch: touch(180), center: center) - 0.5) < 1e-6)
        #expect(abs(GaugeMath.fraction(forTouch: touch(215), center: center) - 1) < 1e-6)
        #expect(GaugeMath.fraction(forTouch: CGPoint(x: 50, y: 100), center: center) == 0)
        #expect(GaugeMath.fraction(forTouch: CGPoint(x: 50, y: 0), center: center) == 1)
    }

    @Test func crewShownOnlyWithCabin() {
        #expect(CrewPlaceholder.hasCabin(VesselDesign.orbit.parts))
        #expect(!CrewPlaceholder.hasCabin([.chute, .decoupler, .t100]))
    }

    @Test func translationReachesPhysicsOnlyWhenRCSEnabled() {
        let flight = RecordingFlight()
        let model = FlightHUDModel(makeSimulation: { flight })
        model.rcsRightInput = 0.5
        model.rcsForwardPressed = true
        model.tick(now: 1)
        #expect(flight.lastInput.translation == .zero)

        model.toggleRCS()
        #expect(model.rcs.enabled)
        model.rcsRightInput = 0.5
        model.rcsForwardPressed = true
        model.tick(now: 2)
        #expect(flight.lastInput.translation == Vec3(0.5, 1, 0))

        model.toggleRCS()
        #expect(!model.rcs.enabled)
        model.tick(now: 3)
        #expect(flight.lastInput.translation == .zero)
    }

    @Test func rcsWithoutBlocksShowsToastAndStaysOff() {
        let flight = RecordingFlight()
        flight.rcsAvailable = false
        let model = FlightHUDModel(makeSimulation: { flight })
        model.toggleRCS()
        #expect(!model.rcs.enabled)
        #expect(model.toast?.text == "Нет блоков РСУ")
    }

    @Test func rcsPartsAppearInHangarCatalog() {
        let misc = CatalogTab.misc.parts.map(\.id)
        #expect(misc.contains(.rcsBlock) && misc.contains(.m100))
        #expect(HangarFormat.details(PartCatalog.spec(.rcsBlock)) == ["Монотопливо 60 кг · сопла 2 кН", "140 кг"])
        #expect(HangarFormat.details(PartCatalog.spec(.m100)).first == "Монотопливо 160 кг")
    }

    @Test func compactLayoutFitsScreenWithoutOverlaps() {
        let model = FlightHUDModel()
        func fitted<V: View>(_ view: V) -> CGSize {
            UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 852, height: 393))
        }
        let ring = fitted(NavballCluster(model: model))
        #expect(ring == CGSize(width: 184, height: 184))
        #expect(ring.height - NavballCluster.overhang <= 150)
        let stage = fitted(StageButton(model: model))
        #expect(stage.height == 40)
        let controls = fitted(ControlsCluster(model: model, guide: nil))
        let rcs = fitted(RCSControls(model: model))
        let stack = fitted(StageStackView(model: model))
        #expect(stack.height <= CGFloat(StageStackView.maxRows) * 22 + 9)

        // По горизонтали на кадре 852 pt (боковые безопасные зоны ≈ 59 pt): кнопка ступени, группа РСУ, кольцо, джойстик.
        let safe: CGFloat = 59
        let stageRight = safe + 6 + stage.width
        let rcsLeft = FlightLayer.rcsCenterX - rcs.width / 2
        let rcsRight = FlightLayer.rcsCenterX + rcs.width / 2
        let ringLeft = (852 - ring.width) / 2
        let ringRight = ringLeft + ring.width
        let controlsLeft = 852 - safe - 4 - controls.width
        #expect(stageRight < rcsLeft)
        #expect(rcsRight < ringLeft - 4)
        #expect(ringRight + 30 < controlsLeft)
        #expect(controls.height <= 80 && rcs.height <= 80)
    }
}

/// Полёт-заглушка, запоминающий последний ввод; доступность РСУ можно отключить.
private final class RecordingFlight: FlightSimulation {
    private let base = MockFlight()
    private(set) var lastInput = ControlInput.neutral
    var rcsAvailable = true

    var snapshot: WorldSnapshot {
        var shot = base.snapshot
        if !rcsAvailable { shot.telemetry.rcs = RCSStatus() }
        return shot
    }

    func setInput(_ input: ControlInput) {
        lastInput = input
        base.setInput(input)
    }

    func send(_ command: FlightCommand) { base.send(command) }
    func advance(realDelta: Double) -> [SimEvent] { base.advance(realDelta: realDelta) }
    func predictTrajectory(maxPatches: Int) -> Trajectory { base.predictTrajectory(maxPatches: maxPatches) }
    func predictManeuver(_ node: ManeuverNode, maxPatches: Int) -> ManeuverPrediction? {
        base.predictManeuver(node, maxPatches: maxPatches)
    }
}
