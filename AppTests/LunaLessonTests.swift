import CoreGraphics
import Testing
import OrbitPhysics
@testable import Orbita

/// Урок «Полёт к Луне»: переходы шагов по телеметрии и прогнозу карты.
@MainActor
struct LunaLessonTests {
    // MARK: - Помощники

    private func orbitT(body: BodyID = .terra, apo: Double = 80_000, peri: Double = 79_000,
                        situation: VesselSituation = .orbiting) -> FlightTelemetry {
        var t = FlightTelemetry(altitude: peri, heightAboveTerrain: peri, body: body, situation: situation)
        t.orbit = OrbitSummary(body: body, apoapsisAltitude: apo, periapsisAltitude: peri, timeToApoapsis: 600,
                               timeToPeriapsis: 1_200, eccentricity: 0.01, inclination: 0, period: 2_400)
        t.mission.launched = true
        return t
    }

    private func node(toBurn: Double = 600, deltaV: Double = 860, remaining: Double = 860,
                      done: Bool = false) -> ManeuverStatus {
        ManeuverStatus(node: ManeuverNode(time: 1_000), timeToNode: toBurn + 30, deltaV: deltaV,
                       remainingDeltaV: remaining, burnTime: 60, timeToBurn: toBurn, isDone: done)
    }

    private func input(_ t: FlightTelemetry, map: Bool = false, throttle: Double = 0,
                       lunaPeri: Double? = nil) -> LessonInput {
        var i = LessonInput(telemetry: t, throttle: throttle, yawRightHeld: false)
        i.mapOpen = map
        i.lunaPeriapsis = lunaPeri
        return i
    }

    private func with(_ t: FlightTelemetry, _ change: (inout FlightTelemetry) -> Void) -> FlightTelemetry {
        var copy = t
        change(&copy)
        return copy
    }

    /// Урок, доведённый до шага `target` по сценарию из макета.
    private func lesson(at target: LunaStep) -> LunaLesson {
        var l = LunaLesson()
        let base = orbitT()
        let withNode = with(base) { $0.maneuver = node() }
        for _ in 0..<LunaStep.allCases.count {
            if l.step == target { break }
            switch l.step {
            case .intro: l.acknowledge(input(base))
            case .openMap: l.update(input(base, map: true), delta: 0.02)
            case .mapIntro: l.acknowledge(input(base, map: true))
            case .lunaNode: l.update(input(withNode, map: true, lunaPeri: 300_000), delta: 0.02)
            case .encounter: l.acknowledge(input(withNode, map: true, lunaPeri: 300_000))
            case .tune: l.update(input(withNode, map: true, lunaPeri: 30_000), delta: 0.02)
            case .toNode:
                l.update(input(with(withNode) { $0.maneuver = node(toBurn: 10) }, map: true), delta: 0.02)
            case .sasNode:
                l.update(input(with(withNode) { $0.sas = .maneuver; $0.maneuver = node(toBurn: 10) }, map: true),
                         delta: 0.02)
            case .burn:
                l.update(input(with(base) { $0.maneuver = node(toBurn: -30, remaining: 0.5, done: true) }), delta: 0.02)
            case .coast: l.update(input(orbitT(body: .luna, apo: .infinity, peri: 30_000)), delta: 0.02)
            case .brake: l.update(input(orbitT(body: .luna, apo: 90_000, peri: 30_000)), delta: 0.02)
            case .land: l.update(input(orbitT(body: .luna, apo: 0, peri: 0, situation: .landed)), delta: 0.02)
            case .finish: break
            }
        }
        #expect(l.step == target)
        return l
    }

    // MARK: - Порядок

    @Test func stepsFollowTheMockup() {
        #expect(LunaStep.sequence.count == 13)
        #expect(LunaStep.sequence.first == .intro && LunaStep.sequence.last == .finish)
        #expect(LunaStep.burn.kind == .live && LunaStep.brake.kind == .live && LunaStep.land.kind == .live)
        #expect(LunaStep.mapIntro.kind == .pause && LunaStep.encounter.kind == .pause)
        for step in [LunaStep.mapIntro, .lunaNode, .encounter, .tune, .toNode, .sasNode] {
            #expect(step.screen == .map)
        }
    }

    @Test func wholeLessonReachesSummary() {
        let l = lesson(at: .finish)
        #expect(l.reachedEnd && l.holdsPhysics && !l.isClosed)
        let scene = l.scene(input(orbitT(body: .luna, situation: .landed)))
        #expect(scene.bubble?.role == .hangar && scene.bubble?.exitTitle == "Остаться на Луне")
    }

    // MARK: - Карта

    @Test func openMapStepWaitsForTheMapButton() {
        var l = lesson(at: .openMap)
        let closed = input(orbitT())
        l.update(closed, delta: 0.02)
        #expect(l.step == .openMap && l.holdsPhysics)
        #expect(l.scene(closed).target == .mapButton && l.scene(closed).passThrough)
        l.update(input(orbitT(), map: true), delta: 0.02)
        #expect(l.step == .mapIntro)
    }

    @Test func mapStepAsksToReopenClosedMap() {
        var l = lesson(at: .mapIntro)
        let closed = input(orbitT())
        let scene = l.scene(closed)
        #expect(scene.target == .mapButton && scene.bubble?.button == nil)
        let refused = l.acknowledge(closed)
        #expect(!refused && l.step == .mapIntro)
        #expect(l.scene(input(orbitT(), map: true)).target == .mapSummary)
        let advanced = l.acknowledge(input(orbitT(), map: true))
        #expect(advanced)
        #expect(l.step == .lunaNode)
    }

    @Test func lunaNodeStepEndsWhenNodeIsPlaced() {
        var l = lesson(at: .lunaNode)
        l.update(input(orbitT(), map: true), delta: 0.02)
        #expect(l.step == .lunaNode)
        #expect(l.scene(input(orbitT(), map: true)).target == .mapLuna)
        l.update(input(with(orbitT()) { $0.maneuver = node() }, map: true), delta: 0.02)
        #expect(l.step == .encounter)
    }

    @Test func tuneStepWaitsForPeriapsisInRange() {
        var l = lesson(at: .tune)
        let t = with(orbitT()) { $0.maneuver = node() }
        l.update(input(t, map: true, lunaPeri: 120_000), delta: 0.02)
        #expect(l.step == .tune && l.holdsPhysics)
        let scene = l.scene(input(t, map: true, lunaPeri: 120_000))
        #expect(scene.ringOnly && !scene.dims && scene.target == .mapHandle && scene.plateBar)
        #expect(l.plate(input(t, map: true, lunaPeri: 120_000))?.value == HUDFormat.distance(120_000))
        #expect(l.plate(input(t, map: true))?.head.contains("Встречи") == true)
        l.update(input(t, map: true, lunaPeri: 25_000), delta: 0.02)
        #expect(l.step == .toNode)
    }

    @Test func tuneStepRangeIsFifteenToSixtyKilometers() {
        #expect(LunaStep.periapsisRange == 15_000...60_000)
        #expect(LunaStep.periapsisRangeText == "15–60")
        let t = with(orbitT()) { $0.maneuver = node() }
        for (peri, passes) in [(16_000.0, true), (55_000.0, true), (14_000.0, false), (61_000.0, false)] {
            var l = lesson(at: .tune)
            l.update(input(t, map: true, lunaPeri: peri), delta: 0.02)
            #expect((l.step == .toNode) == passes)
        }
        var none = lesson(at: .tune)
        none.update(input(t, map: true), delta: 0.02)
        #expect(none.step == .tune)
    }

    @Test func tuneStepPassesAtOnceIfNodeIsAlreadyGood() {
        var l = lesson(at: .encounter)
        let t = with(orbitT()) { $0.maneuver = node() }
        l.acknowledge(input(t, map: true, lunaPeri: 32_000))
        l.update(input(t, map: true, lunaPeri: 32_000), delta: 0.02)
        #expect(l.step == .toNode)
    }

    @Test func toNodeRunsTimeAfterWarpAndEndsNearTheBurn() {
        var l = lesson(at: .toNode)
        let far = with(orbitT()) { $0.maneuver = node(toBurn: 900) }
        l.update(input(far, map: true), delta: 0.02)
        #expect(l.phase == .holding)
        l.update(input(with(far) { $0.warpIndex = 5 }, map: true), delta: 0.02)
        #expect(l.step == .toNode && l.phase == .running && !l.holdsPhysics)
        l.update(input(with(far) { $0.maneuver = node(toBurn: 15) }, map: true), delta: 0.02)
        #expect(l.step == .sasNode && l.phase == .holding)
    }

    @Test func sasNodeWaitsForManeuverMode() {
        var l = lesson(at: .sasNode)
        let t = with(orbitT()) { $0.maneuver = node(toBurn: 15) }
        l.update(input(with(t) { $0.sas = .prograde }, map: true), delta: 0.02)
        #expect(l.step == .sasNode)
        l.update(input(with(t) { $0.sas = .maneuver }, map: true), delta: 0.02)
        #expect(l.step == .burn && l.phase == .running)
    }

    // MARK: - Прожиг, перелёт, захват, посадка

    @Test func burnFollowsRemainingDeltaVAndWaitsForThrottleZero() {
        var l = lesson(at: .burn)
        let before = with(orbitT()) { $0.maneuver = node(toBurn: 12) }
        #expect(l.plate(input(before))?.head.contains("Прожиг через") == true)
        let burning = with(orbitT()) { $0.maneuver = node(toBurn: -10, remaining: 412) }
        let plate = l.plate(input(burning, throttle: 1))
        #expect(plate?.value == HUDFormat.speed(412) && plate?.tail.contains("из 860") == true)
        let done = with(orbitT()) { $0.maneuver = node(toBurn: -40, remaining: 0.4, done: true) }
        l.update(input(done, throttle: 1), delta: 0.02)
        #expect(l.step == .burn)
        l.update(input(done, throttle: 0), delta: 0.02)
        #expect(l.step == .coast && l.phase == .holding)
    }

    @Test func deletingNodeBeforeTheBurnFailsStep() {
        var l = lesson(at: .burn)
        l.update(input(orbitT(), throttle: 1), delta: 0.02)
        #expect(l.phase == .failed && l.failure?.contains("Узел удалён") == true)
        l.didRestore(input(with(orbitT()) { $0.maneuver = node(toBurn: 12) }))
        #expect(l.phase == .ready && l.failure == nil)
        l.acknowledge(input(orbitT()))
        #expect(l.phase == .running)
    }

    @Test func coastWaitsForWarpThenForLunaSOI() {
        var l = lesson(at: .coast)
        let t = with(orbitT(apo: 11_000_000)) { $0.maneuver = node(done: true) }
        l.update(input(t), delta: 0.02)
        #expect(l.phase == .holding && l.scene(input(t)).target == .warp)
        l.update(input(with(t) { $0.warpIndex = 7 }), delta: 0.02)
        #expect(l.phase == .running && !l.holdsPhysics)
        l.update(input(orbitT(body: .luna, apo: .infinity, peri: 30_000)), delta: 0.02)
        #expect(l.step == .brake && l.phase == .running)
    }

    @Test func brakeEndsWithCapturedOrbitBelowHundredKilometers() {
        var l = lesson(at: .brake)
        l.update(input(orbitT(body: .luna, apo: .infinity, peri: 30_000)), delta: 0.02)
        #expect(l.step == .brake)
        #expect(l.plate(input(orbitT(body: .luna, apo: .infinity, peri: 30_000)))?.value == "∞")
        l.update(input(orbitT(body: .luna, apo: 600_000, peri: 30_000)), delta: 0.02)
        #expect(l.step == .brake)
        l.update(input(orbitT(body: .luna, apo: 95_000, peri: 30_000)), delta: 0.02)
        #expect(l.step == .land && l.phase == .running)
    }

    @Test func flyingPastLunaFailsBraking() {
        var l = lesson(at: .brake)
        var t = orbitT(body: .terra, apo: 300_000_000, peri: 50_000_000)
        t.mission.enteredLunaSOI = true
        l.update(input(t), delta: 0.02)
        #expect(l.phase == .failed && l.failure?.contains("мимо Луны") == true)
    }

    @Test func crashFailsLandingAndSoftTouchdownFinishes() {
        var crash = lesson(at: .land)
        crash.update(input(orbitT(body: .luna, apo: 0, peri: 0, situation: .crashed)), delta: 0.02)
        #expect(crash.phase == .failed && crash.holdsPhysics && crash.failure?.contains("Авария") == true)

        var soft = lesson(at: .land)
        var t = orbitT(body: .luna, apo: 900, peri: -1_000, situation: .flying)
        t.heightAboveTerrain = 1_200
        t.surfaceSpeed = 38
        let plate = soft.plate(input(t))
        #expect(plate?.value.contains(HUDFormat.distance(1_200)) == true && plate?.tail.contains("5 м/с") == true)
        soft.update(input(orbitT(body: .luna, apo: 0, peri: 0, situation: .landed)), delta: 0.02)
        #expect(soft.step == .finish && soft.reachedEnd)
        var landed = input(orbitT(body: .luna, situation: .landed))
        landed.touchdownSpeed = 3
        #expect(soft.scene(landed).bubble?.text.contains(HUDFormat.speed(3)) == true)
    }

    // MARK: - Контроллер

    @Test func controllerBuildsLessonById() {
        #expect(TutorialController.makeLesson(.firstFlight) is FirstFlightLesson)
        #expect(TutorialController.makeLesson(.toLuna) is LunaLesson)
        #expect(TutorialController.makeLesson(.controls) is ControlsTour)
        let controller = TutorialController(id: .toLuna)
        #expect(controller.holdsPhysics && controller.firstFlightStep == nil)
        #expect(controller.display.bubble?.button == "Понятно")
    }
}
