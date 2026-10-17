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

    private var lunaOrbit: FlightTelemetry { orbitT(body: .luna, apo: .infinity, peri: 30_000, situation: .flying) }

    /// Узел «Скруглить орбиту» у Луны.
    private var captureNode: FlightTelemetry { with(lunaOrbit) { $0.maneuver = node(toBurn: 3_000, deltaV: 700, remaining: 700) } }

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
            case .lunaNode: l.update(input(withNode, map: true, lunaPeri: 300_000), delta: 0.02)
            case .encounter: l.acknowledge(input(withNode, map: true, lunaPeri: 300_000))
            case .execute:
                var started = input(withNode, map: true)
                started.autoBurn = true
                l.update(started, delta: 0.02)
                l.update(input(orbitT(apo: 250_000_000), throttle: 0), delta: 0.02)
            case .coast: l.update(input(lunaOrbit), delta: 0.02)
            case .captureNode: l.update(input(captureNode, map: true), delta: 0.02)
            case .captureBurn:
                var started = input(captureNode, map: true)
                started.autoBurn = true
                l.update(started, delta: 0.02)
                l.update(input(orbitT(body: .luna, apo: 32_000, peri: 30_000), throttle: 0), delta: 0.02)
            case .retro:
                l.update(input(with(orbitT(body: .luna, apo: 32_000, peri: 30_000)) {
                    $0.sas = .retrograde
                    $0.surfaceSpeed = 1_600
                }), delta: 0.02)
            case .brake:
                l.update(input(with(orbitT(body: .luna, apo: 32_000, peri: 30_000, situation: .flying)) {
                    $0.surfaceSpeed = 60
                }), delta: 0.02)
            case .land: l.update(input(orbitT(body: .luna, apo: 0, peri: 0, situation: .landed)), delta: 0.02)
            case .finish: break
            }
        }
        #expect(l.step == target)
        return l
    }

    // MARK: - Порядок

    @Test func stepsFollowTheMockup() {
        #expect(LunaStep.sequence == [.intro, .openMap, .lunaNode, .encounter, .execute, .coast, .captureNode,
                                      .captureBurn, .retro, .brake, .land, .finish])
        #expect(LunaStep.brake.kind == .live && LunaStep.land.kind == .live && LunaStep.execute.kind == .wait)
        #expect(LunaStep.encounter.kind == .pause)
        #expect(LunaStep.execute.target == .mapExecute && LunaStep.captureBurn.target == .mapExecute)
        #expect(LunaStep.lunaNode.target == .mapLuna && LunaStep.captureNode.target == .mapCircularize)
        #expect(LunaStep.coast.target == .encounterWarp && LunaStep.retro.target == .sas)
        // SAS и тяга есть только в полёте: с карты эти шаги просят «Полёт», а не ждут недоступную кнопку.
        #expect([LunaStep.retro, .brake, .land].allSatisfy { $0.screen == .flight })
        for step in [LunaStep.lunaNode, .encounter, .execute, .coast, .captureNode, .captureBurn] {
            #expect(step.screen == .map)
        }
    }

    @Test func everyActionStepHasTextAndReason() {
        let i = input(orbitT())
        for step in LunaStep.sequence where step.kind == .wait {
            let bubble = step.bubble(i)
            #expect(bubble != nil && bubble?.button == nil && bubble?.why != nil)
            #expect(step.target != nil)
        }
    }

    @Test func progressSkipsIntroAndFinish() {
        #expect(lesson(at: .intro).progress == nil)
        #expect(lesson(at: .openMap).progress == LessonProgress(step: 1, total: 10))
        #expect(lesson(at: .land).progress == LessonProgress(step: 10, total: 10))
        #expect(lesson(at: .finish).progress == nil)
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
        #expect(l.step == .lunaNode)
    }

    @Test func mapStepAsksToReopenClosedMap() {
        var l = lesson(at: .lunaNode)
        let closed = input(orbitT())
        let scene = l.scene(closed)
        #expect(scene.target == .mapButton && scene.bubble?.button == nil)
        l.update(closed, delta: 0.02)
        #expect(l.step == .lunaNode)
        #expect(l.scene(input(orbitT(), map: true)).target == .mapLuna)
    }

    @Test func lunaNodeStepEndsWhenNodeIsPlaced() {
        var l = lesson(at: .lunaNode)
        l.update(input(orbitT(), map: true), delta: 0.02)
        #expect(l.step == .lunaNode)
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

    @Test func executeStepRunsOnAutoBurnAndWaitsForCorrectionToFinish() {
        var l = lesson(at: .execute)
        let t = with(orbitT()) { $0.maneuver = node(toBurn: 600) }
        l.update(input(t, map: true), delta: 0.02)
        #expect(l.step == .execute && l.phase == .holding && l.holdsPhysics)
        var started = input(t, map: true)
        started.autoBurn = true
        l.update(started, delta: 0.02)
        #expect(l.step == .execute && l.phase == .running && !l.holdsPhysics)
        // Прожиг отработан, но идёт коррекция (автопрожиг продолжается): шаг не кончается.
        var burning = input(with(orbitT()) { $0.maneuver = node(toBurn: -40, remaining: 0.4, done: true) })
        burning.autoBurn = true
        l.update(burning, delta: 0.02)
        #expect(l.step == .execute)
        var correction = input(with(orbitT(apo: 250_000_000)) { $0.maneuver = node(toBurn: 50, deltaV: 3, remaining: 3) })
        correction.autoBurn = true
        l.update(correction, delta: 0.02)
        #expect(l.step == .execute && l.phase == .running)
        // Автопрожиг закончен: узел удалён, орбита вытянута к Луне, тяга 0.
        l.update(input(orbitT(apo: 250_000_000), throttle: 0), delta: 0.02)
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

    @Test func deletingNodeWhileWaitingReturnsToTheGoalStep() {
        var l = lesson(at: .execute)
        let advanced = l.update(input(orbitT(), map: true), delta: 0.02)
        #expect(advanced && l.step == .lunaNode && l.phase == .holding)
    }

    // MARK: - Перелёт, захват, посадка

    @Test func coastWaitsForWarpThenForLunaSOI() {
        var l = lesson(at: .coast)
        let t = with(orbitT(apo: 11_000_000)) { $0.maneuver = node(done: true) }
        // Шаг на карте: закрытая карта просит её открыть, открытая подсвечивает «Промотать до встречи».
        #expect(l.scene(input(t)).target == .mapButton)
        l.update(input(t, map: true), delta: 0.02)
        #expect(l.phase == .holding && l.scene(input(t, map: true)).target == .encounterWarp)
        l.update(input(with(t) { $0.warpIndex = 7 }, map: true), delta: 0.02)
        #expect(l.phase == .running && !l.holdsPhysics)
        l.update(input(lunaOrbit), delta: 0.02)
        #expect(l.step == .captureNode && l.phase == .holding && l.holdsPhysics)
    }

    @Test func captureAsksForCircularizeThenExecuteOnTheMap() {
        var l = lesson(at: .captureNode)
        let closed = input(lunaOrbit)
        #expect(l.scene(closed).target == .mapButton)
        let open = input(lunaOrbit, map: true)
        #expect(l.scene(open).target == .mapCircularize)
        l.update(open, delta: 0.02)
        #expect(l.step == .captureNode)
        l.update(input(captureNode, map: true), delta: 0.02)
        #expect(l.step == .captureBurn && l.phase == .holding)
        #expect(l.scene(input(captureNode, map: true)).target == .mapExecute)

        var started = input(captureNode, map: true)
        started.autoBurn = true
        l.update(started, delta: 0.02)
        #expect(l.phase == .running)
        // Открытая орбита и узел ещё не отработан — шаг идёт.
        l.update(started, delta: 0.02)
        #expect(l.step == .captureBurn)
        l.update(input(orbitT(body: .luna, apo: 32_000, peri: 30_000), throttle: 0), delta: 0.02)
        #expect(l.step == .retro && l.phase == .holding)
    }

    @Test func captureNodeDeletedBeforeBurnReturnsToCircularizeStep() {
        var l = lesson(at: .captureBurn)
        l.update(input(lunaOrbit, map: true), delta: 0.02)
        #expect(l.step == .captureNode)
    }

    @Test func retroWaitsForRetrogradeSASAndThenBrakingEndsBelowHundredMetersPerSecond() {
        var l = lesson(at: .retro)
        let flying = with(orbitT(body: .luna, apo: 32_000, peri: 30_000)) { $0.surfaceSpeed = 1_600 }
        l.update(input(flying), delta: 0.02)
        #expect(l.step == .retro && l.scene(input(flying)).target == .sas)
        l.update(input(with(flying) { $0.sas = .retrograde }), delta: 0.02)
        #expect(l.step == .brake && l.phase == .running)
        let fast = with(flying) { $0.surfaceSpeed = 900 }
        l.update(input(fast), delta: 0.02)
        #expect(l.step == .brake)
        #expect(l.plate(input(fast))?.value == HUDFormat.speed(900))
        l.update(input(with(flying) { $0.surfaceSpeed = 80 }), delta: 0.02)
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
        let controller = TutorialController(id: .toLuna)
        #expect(controller.holdsPhysics && controller.firstFlightStep == nil)
        #expect(controller.display.bubble?.button == "Понятно")
    }
}
