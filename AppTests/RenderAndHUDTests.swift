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

    @Test func attitudeCurveTapRampAndFine() {
        typealias C = AttitudeInputCurve
        #expect(C.value(heldFor: 0, fine: false) == 0.15)
        #expect(abs(C.value(heldFor: 0.4, fine: false) - 0.575) < 1e-9)
        #expect(C.value(heldFor: 0.8, fine: false) == 1)
        #expect(C.value(heldFor: 5, fine: false) == 1)
        #expect(C.value(heldFor: -1, fine: false) == 0.15)
        #expect(abs(C.value(heldFor: 5, fine: true) - 0.3) < 1e-9)
        #expect(abs(C.value(heldFor: 0, fine: true) - 0.045) < 1e-9)
    }

    @Test func attitudeButtonsFeedControlInput() {
        let flight = RecordingFlight()
        let model = FlightHUDModel(makeSimulation: { flight })
        model.setAttitude(.pitchUp, pressed: true, now: 10)
        model.setAttitude(.rollRight, pressed: true, now: 10)
        model.tick(now: 10)
        model.tick(now: 11)
        #expect(flight.lastInput.pitch == 1 && flight.lastInput.roll == 1 && flight.lastInput.yaw == 0)
        // Противоположные кнопки вместе дают 0, отпускание одной возвращает ввод другой.
        model.setAttitude(.yawLeft, pressed: true, now: 11)
        model.setAttitude(.yawRight, pressed: true, now: 11)
        #expect(model.attitudeAxes(now: 12).yaw == 0)
        model.setAttitude(.yawLeft, pressed: false)
        #expect(model.attitudeAxes(now: 12).yaw == 1)
        // Повторное нажатие не сбрасывает разгон; «ТОЧНО» масштабирует и сбрасывается при перезапуске.
        model.setAttitude(.yawRight, pressed: true, now: 12)
        #expect(model.attitudeAxes(now: 12).yaw == 1)
        model.fineControl = true
        #expect(abs(model.attitudeAxes(now: 12).pitch - 0.3) < 1e-9)
        model.restart()
        #expect(!model.fineControl)
        #expect(model.attitudeAxes(now: 20) == (0, 0, 0))
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
        let mm = fitted(ControlsCluster(model: model, guide: nil))
        let rcs = fitted(RCSControls(model: model))
        let block = fitted(AttitudeControls(model: model))
        let fine = fitted(FineControlToggle(model: model))
        let stack = fitted(StageStackView(model: model))
        #expect(block == CGSize(width: AttitudeControls.side, height: AttitudeControls.side))
        #expect(fine.width >= HUDStyle.minTouch && fine.height >= HUDStyle.minTouch)
        #expect(stack.height <= CGFloat(StageStackView.maxRows) * 22 + 9)

        // Кадр 852×393, боковые безопасные зоны ≈ 59 pt, нижняя игнорируется. Прямоугольники (x, y, ширина, высота).
        let safe: CGFloat = 59
        let screen = CGRect(x: 0, y: 0, width: 852, height: 393)
        let blockRect = CGRect(x: safe + 16, y: 393 - FlightLayer.attitudeBottom - block.height, width: block.width, height: block.height)
        let ringRect = CGRect(x: (852 - ring.width) / 2, y: 393 - (ring.height - NavballCluster.overhang),
                              width: ring.width, height: ring.height - NavballCluster.overhang)
        let stageRect = CGRect(x: 852 - safe - 6 - stage.width, y: 393 - 24 - stage.height,
                               width: stage.width, height: stage.height)
        let mmRect = CGRect(x: stageRect.minX - 6 - mm.width, y: 393 - 24 - mm.height, width: mm.width, height: mm.height)
        let rcsRect = CGRect(x: 852 - safe - 6 - rcs.width, y: stageRect.minY - mm.height - 6 - rcs.height - 4,
                             width: rcs.width, height: rcs.height)
        let allRight = [stageRect, mmRect, rcsRect]
        for r in [blockRect, ringRect] + allRight { #expect(screen.contains(r)) }
        #expect(!blockRect.intersects(ringRect) && ringRect.maxX < mmRect.minX)
        #expect(!mmRect.intersects(stageRect) && !rcsRect.intersects(mmRect) && !rcsRect.intersects(stageRect))
        #expect(!rcsRect.intersects(ringRect) && !rcsRect.intersects(blockRect))
        // Крест: ▲ выше ◀ ▶, ▼ ниже них, ◀ левее ▶; нижний край блока ≥ 40 pt от низа, центр креста ≈ 140 pt.
        let c = AttitudeControls.cell, g = AttitudeControls.gap
        func cell(_ col: Int, _ row: Int) -> CGRect {
            CGRect(x: blockRect.minX + CGFloat(col) * (c + g), y: blockRect.minY + CGFloat(row) * (c + g), width: c, height: c)
        }
        let up = cell(1, 0), left = cell(0, 1), right = cell(2, 1), down = cell(1, 2)
        #expect(up.maxY < left.minY && up.maxY < right.minY && down.minY > left.maxY && down.minY > right.maxY)
        #expect(left.maxX < right.minX)
        #expect(393 - blockRect.maxY >= 40)
        #expect(abs((393 - cell(1, 1).midY) - 140) <= 4)
        #expect(c >= HUDStyle.minTouch && g >= 6)
        #expect(393 - stageRect.maxY >= 24)
        // Левая колонка: стопка и карточка выше блока; если развёрнутая не помещается — карточка свёрнута.
        let expandedCard = fitted(MissionCard(model: model, forceCollapsed: false))
        #expect(expandedCard.height <= MissionCard.expandedHeight)
        for rows in [3, 5] {
            let shown = min(rows, StageStackView.maxRows)
            let stackH = CGFloat(shown) * 22 + CGFloat(shown - 1) * 3
            let fits = MissionCard.fitsExpanded(stackHeight: stackH, blockTop: blockRect.minY)
            let card = fitted(MissionCard(model: model, forceCollapsed: !fits))
            #expect(card.width <= MissionCard.width)
            let cardRect = CGRect(x: safe + 6, y: 36 + stackH + 6, width: card.width, height: card.height)
            #expect(cardRect.maxY < blockRect.minY || cardRect.maxX < blockRect.minX)
            if !fits { #expect(card.height < 40) }
        }
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
