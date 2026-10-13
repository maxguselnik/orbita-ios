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
            case .execute:
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
        #expect(LunaStep.sequence.count == 10)
        #expect(LunaStep.sequence.first == .intro && LunaStep.sequence.last == .finish)
        #expect(LunaStep.brake.kind == .live && LunaStep.land.kind == .live && LunaStep.execute.kind == .wait)
        #expect(LunaStep.mapIntro.kind == .pause && LunaStep.encounter.kind == .pause)
        #expect(LunaStep.execute.target == .mapExecute)
        for step in [LunaStep.mapIntro, .lunaNode, .encounter, .execute] {
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

    @Test func encounterIsAnInfoPauseOnTheMap() {
        var l = lesson(at: .encounter)
        let t = with(orbitT()) { $0.maneuver = node() }
        #expect(l.scene(input(t, map: true, lunaPeri: 30_000)).bubble?.button == "Дальше")
        l.acknowledge(input(t, map: true, lunaPeri: 30_000))
        #expect(l.step == .execute && l.phase == .holding)
        #expect(l.scene(input(t, map: true)).target == .mapExecute)
    }

    @Test func executeStepRunsOnAutoBurnAndEndsWhenTransferIsDone() {
        var l = lesson(at: .execute)
        let t = with(orbitT()) { $0.maneuver = node(toBurn: 600) }
        l.update(input(t, map: true), delta: 0.02)
        #expect(l.step == .execute && l.phase == .holding && l.holdsPhysics)
        var started = input(t, map: true)
        started.autoBurn = true
        l.update(started, delta: 0.02)
        #expect(l.step == .execute && l.phase == .running && !l.holdsPhysics)
        // Пока автопрожиг идёт, шаг не кончается, даже если узел отработан.
        var burning = input(with(orbitT()) { $0.maneuver = node(toBurn: -40, remaining: 0.4, done: true) })
        burning.autoBurn = true
        l.update(burning, delta: 0.02)
        #expect(l.step == .execute)
        // Автопрожиг закончен: узел удалён, орбита вытянута к Луне, тяга 0.
        let done = input(orbitT(apo: 250_000_000), throttle: 0)
        l.update(done, delta: 0.02)
        #expect(l.step == .coast && l.phase == .holding)
    }

    @Test func executePlateFollowsTheBurn() {
        let before = with(orbitT()) { $0.maneuver = node(toBurn: 600) }
        #expect(LunaStep.execute.plate(input(before))?.head.contains("Летим к узлу") == true)
        let burning = with(orbitT()) { $0.maneuver = node(toBurn: -10, remaining: 412) }
        let plate = LunaStep.execute.plate(input(burning))
        #expect(plate?.value == HUDFormat.speed(412) && plate?.tail.contains("из 860") == true)
    }

    @Test func deletingNodeBeforeTheBurnFailsExecuteStep() {
        var l = lesson(at: .execute)
        var started = input(with(orbitT()) { $0.maneuver = node(toBurn: 600) }, map: true)
        started.autoBurn = true
        l.update(started, delta: 0.02)
        #expect(l.phase == .running)
        l.update(input(orbitT(), throttle: 0), delta: 0.02)
        #expect(l.phase == .failed && l.failure?.contains("Узел удалён") == true)
        l.didRestore(input(with(orbitT()) { $0.maneuver = node(toBurn: 12) }))
        #expect(l.phase == .holding && l.failure == nil)
    }

    // MARK: - Прожиг, перелёт, захват, посадка

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
