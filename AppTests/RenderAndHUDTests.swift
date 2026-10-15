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
        let design = VesselDesign(name: "Тест", parts: [.podK1])
        scene.show(design: design, selected: [], ghost: nil)
        #expect(scene.pickPart(at: CGPoint(x: 150, y: 150), viewSize: size) == design.nodes[0].id)
        #expect(scene.pickPart(at: .zero, viewSize: size) == nil)
        let targets = VesselEditing.attachTargets(for: .t100, symmetry: 1, in: design)
        let top = targets.first { $0.node == .top }
        let bottom = targets.first { $0.node == .bottom }
        let topPoint = top.flatMap { scene.project($0.position, viewSize: size) }
        let bottomPoint = bottom.flatMap { scene.project($0.position, viewSize: size) }
        #expect(topPoint != nil && bottomPoint != nil)
        if let topPoint, let bottomPoint { #expect(topPoint.y < bottomPoint.y) }
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

    @Test func ascentTargetPitchStartsOneKilometerAboveHighPad() {
        // Площадка на 1787 м: вертикально до 2787 м над уровнем моря, пороги 10/45/60 км — прежние.
        let ground = 1_787.0
        func pitch(_ alt: Double) -> Double {
            AscentGuide.targetPitchDegrees(altitude: alt, heightAboveTerrain: alt - ground)
        }
        #expect(pitch(2_500) == 90)
        #expect(pitch(ground + 1_000) == 90)
        #expect(abs(pitch(10_000) - 45) < 1e-9)
        #expect(abs(pitch(45_000) - 10) < 1e-9)
        #expect(pitch(80_000) == 0)
        let mid = pitch(6_000)
        #expect(mid > 45 && mid < 90)
        // Без рельефа — как раньше.
        #expect(AscentGuide.targetPitchDegrees(altitude: 5_500, heightAboveTerrain: 5_500)
                == AscentGuide.targetPitchDegrees(altitude: 5_500))
    }

    @Test func ascentAdviceStaysVerticalOverHighPad() {
        var t = FlightTelemetry(altitude: 2_500, heightAboveTerrain: 713, situation: .flying, pitch: .pi / 2)
        t.mission.launched = true
        t.thrust = 1_000
        let advice = AscentGuide.advice(t)
        #expect(advice?.text == "Вертикально до 1 км")
        #expect(advice?.targetPitch == .pi / 2)
    }

    @Test func ascentAdviceFollowsFlightPhases() {
        var t = FlightTelemetry(situation: .prelaunch)
        t.nextStageAction = .ignite
        #expect(AscentGuide.advice(t)?.text == "Пуск → Тяга MAX")

        t = FlightTelemetry(altitude: 20_000, heightAboveTerrain: 20_000, situation: .suborbital, pitch: 1.0, heading: .pi / 2)
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

    @Test func stageGroupsFollowStageInfoPartsAndFlags() {
        func info(_ parts: [PartID]) -> StageInfo {
            var i = StageInfo(deltaV: 100, twr: 1.5, twrVacuum: 1.6, fuelFraction: 1, burnTime: 30, hasSolid: false,
                              fuelMass: 100, fuelCapacity: 100, hasLiquidEngine: true)
            i.parts = parts
            return i
        }
        let stages = [info([.shtil, .t400]), info([.decoupler, .vikhr]), info([.chute])]
        let groups = StageGroup.groups(stages: stages)
        #expect(groups.map(\.number) == [3, 2, 1])
        #expect(groups.first?.items.map(\.kind) == [.chute])
        #expect(groups.last?.isCurrent == true)
        #expect(groups.last?.items.count == 2)
        #expect(groups.last?.items.contains { $0.kind == .tank } == true)
        // Без списка деталей — значки по флагам ступени.
        let stub = StageGroup.groups(stages: [info([])])
        #expect(stub.last?.items.map(\.kind) == [.tank, .engine])
        // Новые глифы.
        let aero = StageGroup.groups(stages: [info([.fairing, .fin, .fin])])
        #expect(aero.last?.items.map(\.kind) == [.fairing, .fin])
        #expect(aero.last?.items.last?.count == 2)
    }

    @Test func throttleArcMapsTouchAngleToFraction() {
        let center = CGPoint(x: 50, y: 50)
        func touch(_ degrees: Double) -> CGPoint {
            let r = degrees * .pi / 180
            return CGPoint(x: 50 + 40 * cos(r), y: 50 + 40 * sin(r))
        }
        #expect(abs(GaugeMath.fraction(forTouch: touch(180), center: center)) < 1e-6)
        #expect(abs(GaugeMath.fraction(forTouch: touch(215), center: center) - 0.5) < 1e-6)
        #expect(abs(GaugeMath.fraction(forTouch: touch(250), center: center) - 1) < 1e-6)
        #expect(GaugeMath.fraction(forTouch: CGPoint(x: 50, y: 100), center: center) == 0)
        #expect(GaugeMath.fraction(forTouch: CGPoint(x: 50, y: 0), center: center) == 1)
    }

    @Test func crewShownOnlyWithCabin() {
        #expect(!CrewModel.crew(forParts: VesselDesign.orbit.parts).isEmpty)
        #expect(CrewModel.crew(forParts: [.chute, .decoupler, .t100]).isEmpty)
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
        #expect(CatalogTab.rcs.parts.map(\.id).contains(.rcsBlock))
        #expect(CatalogTab.tanks.parts.map(\.id).contains(.m100))
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

    @Test func dpadSectorsDeadZoneAndDiagonal() {
        typealias S = DPadSector
        let r: CGFloat = 75
        #expect(S.sector(for: CGPoint(x: 0, y: -50), radius: r) == .up)
        #expect(S.sector(for: CGPoint(x: 0, y: 50), radius: r) == .down)
        #expect(S.sector(for: CGPoint(x: -50, y: 0), radius: r) == .left)
        #expect(S.sector(for: CGPoint(x: 50, y: 0), radius: r) == .right)
        // Мёртвая зона 18 % радиуса (13.5 pt).
        #expect(S.sector(for: .zero, radius: r) == nil)
        #expect(S.sector(for: CGPoint(x: 9, y: 9), radius: r) == nil)
        #expect(S.sector(for: CGPoint(x: 0, y: -14), radius: r) == .up)
        // Диагональ: побеждает вертикаль; чуть в сторону от диагонали — горизонталь.
        #expect(S.sector(for: CGPoint(x: 30, y: -30), radius: r) == .up)
        #expect(S.sector(for: CGPoint(x: -30, y: 30), radius: r) == .down)
        #expect(S.sector(for: CGPoint(x: 31, y: -30), radius: r) == .right)
        #expect(S.sector(for: CGPoint(x: -31, y: -30), radius: r) == .left)
        // За краем круга сектор сохраняется.
        #expect(S.sector(for: CGPoint(x: 200, y: 10), radius: r) == .right)
        #expect(Set(S.allCases.map(\.button)).count == 4)
    }

    @Test func compactLayoutFitsScreenWithoutOverlaps() {
        let model = FlightHUDModel()
        func fitted<V: View>(_ view: V) -> CGSize {
            UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 852, height: 393))
        }
        func rect(_ c: CGPoint, _ size: CGSize) -> CGRect {
            CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        }
        // Кадр 852×393: все координаты от физических краёв экрана (боковая безопасная зона не учитывается).
        let screen = CGRect(x: 0, y: 0, width: 852, height: 393)
        let island = CGRect(x: 0, y: 393 / 2 - 60, width: 50, height: 120)   // Dynamic Island у бокового края
        let islandRight = CGRect(x: 852 - 44, y: 393 / 2 - 60, width: 44, height: 120)
        let homeZone: CGFloat = 40   // отступ дуги, ручки и MAX от системного жеста «домой»

        let cluster = fitted(NavballCluster(model: model))
        #expect(cluster == CGSize(width: NavballCluster.width, height: NavballCluster.height))
        #expect(NavballCluster.size == 156)
        let stage = fitted(StageButton(model: model))
        #expect(stage.height == 44)
        let rcs = fitted(RCSControls(model: model))
        let block = fitted(AttitudeControls(model: model))
        #expect(block == AttitudeControls.frameSize)

        // Навбол по центру, опущен: низ кольца за краем экрана, шар виден целиком.
        let clusterOrigin = CGPoint(x: (852 - cluster.width) / 2, y: 393 - NavballCluster.lift - cluster.height)
        let clusterRect = CGRect(origin: clusterOrigin, size: cluster)
        let ringRect = CGRect(x: clusterOrigin.x + NavballCluster.ringOrigin.x, y: clusterOrigin.y + NavballCluster.ringOrigin.y,
                              width: NavballCluster.size, height: NavballCluster.size)
        #expect(NavballCluster.lift < 0 && clusterRect.maxY > 393)
        let ball = rect(CGPoint(x: clusterOrigin.x + NavballCluster.center.x, y: clusterOrigin.y + NavballCluster.center.y),
                        CGSize(width: NavballCluster.ballDiameter, height: NavballCluster.ballDiameter))
        #expect(screen.contains(ball))
        // Метка MAX не заходит на кнопку RCS.
        let rcsButton = CGRect(x: clusterOrigin.x + NavballCluster.center.x - 98,
                               y: clusterOrigin.y, width: 48, height: NavballCluster.rowHeight)
        // Дуга, ручка и MAX сохраняют отступ 40 pt от низа.
        let touch = ThrottleGauge.touchRect.offsetBy(dx: clusterOrigin.x, dy: clusterOrigin.y)
        func labelRect(_ c: CGPoint) -> CGRect {
            rect(CGPoint(x: clusterOrigin.x + c.x, y: clusterOrigin.y + c.y), ThrottleGauge.labelTouch)
        }
        let maxLabel = labelRect(ThrottleGauge.maxLabelCenter), zeroLabel = labelRect(ThrottleGauge.zeroLabelCenter)
        let knobLow = GaugeMath.point(center: NavballCluster.center, radius: NavballCluster.arcRadius, side: .left, fraction: 0)
        let knobHigh = GaugeMath.point(center: NavballCluster.center, radius: NavballCluster.arcRadius, side: .left, fraction: 1)
        for y in [touch.maxY, maxLabel.maxY, clusterOrigin.y + knobLow.y + ThrottleGauge.knobRadius,
                  clusterOrigin.y + knobHigh.y + ThrottleGauge.knobRadius] {
            #expect(393 - y >= homeZone)
        }
        // По согласованному макету «0» ниже: капсула остаётся в 44 pt от края,
        // а расширенная невидимая зона касания — в 30 pt (выше нижней safe area).
        #expect(393 - zeroLabel.maxY >= 30)
        #expect(maxLabel.width >= 44 && maxLabel.height >= 44 && zeroLabel.width >= 44 && zeroLabel.height >= 44)
        #expect(!maxLabel.intersects(zeroLabel) && screen.contains(maxLabel) && screen.contains(zeroLabel))
        #expect(!maxLabel.intersects(rcsButton))
        // Подпись «ТЯГА» (видимая часть) не пересекается с видимыми метками.
        let caption = rect(CGPoint(x: clusterOrigin.x + ThrottleGauge.captionCenter.x,
                                   y: clusterOrigin.y + ThrottleGauge.captionCenter.y), CGSize(width: 30, height: 22))
        for c in [ThrottleGauge.maxLabelCenter, ThrottleGauge.zeroLabelCenter] {
            #expect(!rect(CGPoint(x: clusterOrigin.x + c.x, y: clusterOrigin.y + c.y), CGSize(width: 30, height: 16)).intersects(caption))
        }

        // Правая группа: круг 140 pt, центр 120 pt от низа, внешний край 66 pt от правого края.
        let origin = CGPoint(x: 852 - AttitudeControls.trailingInset - block.width, y: 393 - AttitudeControls.bottomInset - block.height)
        func onScreen(_ r: CGRect) -> CGRect { r.offsetBy(dx: origin.x, dy: origin.y) }
        let circle = onScreen(AttitudeControls.circleRect)
        let rollL = onScreen(AttitudeControls.rollLeftRect)
        let rollR = onScreen(AttitudeControls.rollRightRect)
        let pill = onScreen(AttitudeControls.pillRect)
        let rcsRect = CGRect(x: 852 - FlightLayer.rcsTrailing - rcs.width,
                             y: origin.y - 6 - rcs.height, width: rcs.width, height: rcs.height)
        #expect(circle.width == 140 && abs(393 - circle.midY - 120) <= 2 && abs(852 - circle.maxX - 66) <= 2)
        #expect(393 - circle.maxY >= homeZone && 393 - pill.maxY >= homeZone)
        // Крен: над «плечами», зазор до круга ≥ 6 pt, правая кнопка ≥ 44 pt от края и вне зоны острова.
        for c in [rollL, rollR] {
            let d = ((c.midX - circle.midX) * (c.midX - circle.midX) + (c.midY - circle.midY) * (c.midY - circle.midY)).squareRoot()
            #expect(d >= AttitudeControls.radius + c.width / 2 + 6)
            #expect(c.midY < circle.midY && c.width >= 44)
            #expect(!c.intersects(island) && !c.intersects(islandRight))
        }
        #expect(852 - rollR.maxX >= 44 && rollL.midX < circle.midX && rollR.midX > circle.midX)
        #expect(!rollL.intersects(rollR) && !rollL.intersects(pill) && !rollR.intersects(pill))
        // «Точно» — снизу-слева, со стороны навбола; круг его не задевает.
        func gap(_ r: CGRect, toCenterOf c: CGRect) -> CGFloat {
            let dx = max(r.minX - c.midX, 0, c.midX - r.maxX), dy = max(r.minY - c.midY, 0, c.midY - r.maxY)
            return (dx * dx + dy * dy).squareRoot()
        }
        #expect(gap(pill, toCenterOf: circle) >= AttitudeControls.radius)
        #expect(pill.midX < circle.midX && pill.midY > circle.midY && pill.width >= 44 && pill.height >= 44)
        #expect(!circle.intersects(island) && !circle.intersects(islandRight))

        // Левая группа: капсула «Пуск» зеркальна кругу — тот же центр по высоте (±2), тот же отступ от края (±4).
        let stageRect = CGRect(x: FlightLayer.stageLeading, y: 393 - FlightLayer.controlCenterFromBottom - stage.height / 2,
                               width: stage.width, height: stage.height)
        #expect(abs(stageRect.midY - circle.midY) <= 2)
        #expect(abs(stageRect.minX - (852 - circle.maxX)) <= 4)
        #expect(!stageRect.intersects(island) && stageRect.height >= 44)

        let all: [(String, CGRect)] = [("ball", ball), ("maxLabel", maxLabel), ("zeroLabel", zeroLabel), ("circle", circle),
                                       ("rollL", rollL), ("rollR", rollR), ("pill", pill), ("stage", stageRect), ("rcs", rcsRect)]
        for r in all { #expect(screen.contains(r.1), "\(r.0) вне экрана") }
        // Навбол (кольцо и строка над ним) не пересекается ни с правой, ни с левой группой; метки — тоже.
        let center = clusterRect.union(maxLabel).union(zeroLabel)
        #expect(clusterRect.contains(ringRect))
        #expect(!stageRect.intersects(center) && !rcsRect.intersects(center))
        for r in [circle, rollL, rollR] { #expect(!r.intersects(clusterRect), "правая группа задевает навбол") }
        #expect(!rcsRect.intersects(rollL) && !rcsRect.intersects(rollR) && !rcsRect.intersects(circle))
        #expect(!rcsRect.intersects(island) && !rcsRect.intersects(islandRight))
        #expect(rcsRect.minY > 75)   // под кнопками экипажа и карты

        // Левая колонка: стопка и под ней карточка миссии не пересекаются с капсулой; не помещается — свёрнута по умолчанию.
        let safe: CGFloat = 59
        let expandedCard = fitted(MissionCard(model: model, autoExpand: true))
        #expect(expandedCard.height <= MissionCard.expandedHeight)
        for rows in [3, 5] {
            let shown = min(rows, StageStackView.maxRows)
            let stackH = CGFloat(shown) * 22 + CGFloat(shown - 1) * 3
            let fits = MissionCard.fitsExpanded(stackHeight: stackH, blockTop: stageRect.minY)
            let card = fitted(MissionCard(model: model, autoExpand: fits))
            #expect(card.width <= MissionCard.width)
            // По умолчанию: развёрнутая — только если помещается, иначе одна строка; в обоих случаях над капсулой.
            let cardRect = CGRect(x: safe + 6, y: 36 + stackH + MissionCard.gap, width: card.width, height: card.height)
            #expect(cardRect.maxY <= stageRect.minY)
            #expect(fits == (rows == 3))
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
