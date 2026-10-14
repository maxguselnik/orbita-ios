import CoreGraphics
import Testing
import OrbitPhysics
@testable import Orbita

@MainActor
struct FirstFlightLessonTests {
    // MARK: - Помощники

    private func orbit(apo: Double, peri: Double = -300_000, toApo: Double? = 100) -> OrbitSummary {
        OrbitSummary(body: .terra, apoapsisAltitude: apo, periapsisAltitude: peri,
                     timeToApoapsis: toApo, timeToPeriapsis: nil, eccentricity: 0.5, inclination: 0, period: 3_000)
    }

    private func stage(fuel: Double) -> StageInfo {
        StageInfo(deltaV: 1_000, twr: 1.5, twrVacuum: 1.7, fuelFraction: fuel, burnTime: 60, hasSolid: false,
                  fuelMass: 100 * fuel, fuelCapacity: 100, hasLiquidEngine: true)
    }

    private func flight(altitude: Double, pitchDegrees: Double = 90, apo: Double? = nil, peri: Double = -300_000,
                        toApo: Double? = 100, fuel: Double = 0.8, action: StageAction = .separate,
                        warpIndex: Int = 0) -> FlightTelemetry {
        var t = FlightTelemetry(altitude: altitude, heightAboveTerrain: altitude, stages: [stage(fuel: fuel)], thrust: 1_000,
                                situation: .suborbital, pitch: pitchDegrees * .pi / 180, warpIndex: warpIndex)
        t.mission.launched = true
        t.nextStageAction = action
        if let apo { t.orbit = orbit(apo: apo, peri: peri, toApo: toApo) }
        return t
    }

    private var pad: FlightTelemetry {
        var t = FlightTelemetry(situation: .prelaunch)
        t.nextStageAction = .ignite
        return t
    }

    private func input(_ t: FlightTelemetry, throttle: Double = 1, yaw: Bool = false, map: Bool = false,
                       autoBurn: Bool = false) -> LessonInput {
        var i = LessonInput(telemetry: t, throttle: throttle, yawRightHeld: yaw)
        i.mapOpen = map
        i.autoBurn = autoBurn
        return i
    }

    private func node(toBurn: Double = 120, remaining: Double = 25, done: Bool = false) -> ManeuverStatus {
        ManeuverStatus(node: ManeuverNode(time: 1_000), timeToNode: toBurn + 2, deltaV: 25, remainingDeltaV: remaining,
                       burnTime: 4, timeToBurn: toBurn, isDone: done)
    }

    /// Подъём закончен: Ап 85 км, корабль ещё в атмосфере, тяга 0.
    private var coasting: FlightTelemetry { flight(altitude: 60_000, apo: 85_000, toApo: 150) }

    private func withNode(_ t: FlightTelemetry, _ status: ManeuverStatus? = nil) -> FlightTelemetry {
        var copy = t
        copy.maneuver = status ?? node()
        return copy
    }

    /// Урок, доведённый до шага `target`: на каждом шаге подаётся нужная телеметрия.
    private func lesson(at target: LessonStep) -> FirstFlightLesson {
        var l = FirstFlightLesson()
        l.acknowledge(pad)
        let script: [(LessonStep, LessonInput)] = [
            (.throttleMax, input(pad, throttle: 1)),
            (.launch, input(flight(altitude: 0, action: .separate))),
            (.vertical, input(flight(altitude: 1_500))),
            (.turn, input(flight(altitude: 1_500, pitchDegrees: 79))),
            (.follow, input(flight(altitude: 10_500, pitchDegrees: 40))),
            (.separate, input(flight(altitude: 20_000, fuel: 0, action: .none))),
            (.apoapsisCut, input(flight(altitude: 40_000, apo: 85_000), throttle: 0)),
            (.openMap, input(coasting, throttle: 0, map: true)),
            (.circularize, input(withNode(coasting), throttle: 0, map: true)),
            (.execute, input(withNode(coasting, node(toBurn: -5, remaining: 0.05, done: true)),
                             throttle: 0, map: true, autoBurn: true)),
        ]
        for (step, i) in script {
            if l.step == target { break }
            #expect(l.step == step)
            if step == .separate { l.update(input(flight(altitude: 20_000, fuel: 0)), delta: 0.02) }
            if step == .apoapsisCut { l.update(input(flight(altitude: 40_000, apo: 85_000)), delta: 0.02) }
            if step == .turn { l.update(input(flight(altitude: 1_500), yaw: true), delta: 0.02) }
            if step == .execute {
                // Автопрожиг запускается, потом заканчивается выходом на орбиту.
                l.update(input(withNode(coasting), throttle: 0, map: true, autoBurn: true), delta: 0.02)
                l.update(input(flight(altitude: 80_000, apo: 84_000, peri: 72_000, toApo: 10), throttle: 0, map: true),
                         delta: 0.02)
                continue
            }
            l.update(i, delta: 0.02)
        }
        return l
    }

    // MARK: - Порядок и переходы

    @Test func stepsGoInDocumentedOrder() {
        #expect(LessonStep.allCases == [.intro, .throttleMax, .launch, .vertical, .turn, .follow, .separate,
                                        .apoapsisCut, .openMap, .circularize, .execute, .finish])
        #expect(LessonStep.numberedCount == 10)
    }

    @Test func introHoldsPhysicsUntilAcknowledged() {
        var l = FirstFlightLesson()
        #expect(l.step == .intro && l.holdsPhysics)
        l.update(input(pad), delta: 1)
        #expect(l.step == .intro)
        let advanced = l.acknowledge(pad)
        #expect(advanced)
        #expect(l.step == .throttleMax && l.phase == .holding)
    }

    @Test func throttleStepWaitsForMax() {
        var l = lesson(at: .throttleMax)
        l.update(input(pad, throttle: 0.5), delta: 0.02)
        #expect(l.step == .throttleMax)
        let advanced = l.update(input(pad, throttle: 1), delta: 0.02)
        #expect(advanced)
        #expect(l.step == .launch && l.holdsPhysics)
    }

    @Test func launchStepEndsWithIgnitionAndThenFliesFreely() {
        var l = lesson(at: .launch)
        var t = FlightTelemetry(situation: .prelaunch)
        t.nextStageAction = .ignite
        l.update(input(t), delta: 0.02)
        #expect(l.step == .launch)
        t.nextStageAction = .separate
        l.update(input(t), delta: 0.02)
        #expect(l.step == .vertical && l.phase == .running && !l.holdsPhysics)
    }

    @Test func verticalEndsAtOneKilometer() {
        var l = lesson(at: .vertical)
        l.update(input(flight(altitude: 900)), delta: 0.02)
        #expect(l.step == .vertical)
        l.update(input(flight(altitude: AscentGuide.verticalLimit + 1)), delta: 0.02)
        #expect(l.step == .turn && l.phase == .holding)
    }

    @Test func turnWaitsForRightButtonThenForEightyDegrees() {
        var l = lesson(at: .turn)
        l.update(input(flight(altitude: 1_500, pitchDegrees: 89)), delta: 0.02)
        #expect(l.phase == .holding)
        l.update(input(flight(altitude: 1_500, pitchDegrees: 88), yaw: true), delta: 0.02)
        #expect(l.step == .turn && l.phase == .running)
        l.update(input(flight(altitude: 1_600, pitchDegrees: 80)), delta: 0.02)
        #expect(l.step == .follow)
    }

    @Test func followEndsAtTenKilometersAndSeparationWaitsForEmptyStage() {
        var l = lesson(at: .follow)
        l.update(input(flight(altitude: 9_000, pitchDegrees: 47)), delta: 0.02)
        #expect(l.step == .follow)
        l.update(input(flight(altitude: 10_000, pitchDegrees: 45)), delta: 0.02)
        #expect(l.step == .separate && l.phase == .waiting && !l.holdsPhysics)
        l.update(input(flight(altitude: 18_000, pitchDegrees: 30, fuel: 0.001)), delta: 0.02)
        #expect(l.step == .separate && l.phase == .holding)
        l.update(input(flight(altitude: 18_000, pitchDegrees: 30, fuel: 0, action: .none)), delta: 0.02)
        #expect(l.step == .apoapsisCut && l.phase == .waiting)
    }

    @Test func emptyStageBeforeTenKilometersSkipsToSeparation() {
        var l = lesson(at: .follow)
        l.update(input(flight(altitude: 8_000, pitchDegrees: 50, fuel: 0)), delta: 0.02)
        #expect(l.step == .separate && l.phase == .holding)
    }

    @Test func apoapsisStepHoldsAtEightyKilometersUntilThrottleZero() {
        var l = lesson(at: .apoapsisCut)
        l.update(input(flight(altitude: 40_000, pitchDegrees: 20, apo: 79_000), throttle: 1), delta: 0.02)
        #expect(l.phase == .waiting)
        l.update(input(flight(altitude: 41_000, pitchDegrees: 20, apo: 80_500), throttle: 1), delta: 0.02)
        #expect(l.phase == .holding && l.holdsPhysics)
        l.update(input(flight(altitude: 41_000, pitchDegrees: 20, apo: 80_500), throttle: 0), delta: 0.02)
        #expect(l.step == .openMap && l.phase == .holding)
    }

    @Test func apoapsisStepHighlightsApoapsisRowAndThrottleWithPlainText() {
        let l = lesson(at: .apoapsisCut)
        var t = flight(altitude: 35_000, pitchDegrees: 20, apo: 80_500)
        t.altitude = 35_000
        var armed = l
        armed.update(input(t, throttle: 1), delta: 0.02)
        let scene = armed.scene(input(t, throttle: 1))
        #expect(scene.target == .throttle && scene.alsoTargets == [.apoapsis])
        let text = scene.bubble?.text ?? ""
        #expect(text.contains(HUDFormat.distance(35_000)) && text.contains("80 км") && text.contains("тягу до 0"))
        #expect(scene.bubble?.why != nil)
    }

    @Test func openMapStepWaitsForMapButton() {
        var l = lesson(at: .openMap)
        l.update(input(coasting, throttle: 0), delta: 0.02)
        #expect(l.step == .openMap && l.holdsPhysics)
        #expect(l.scene(input(coasting, throttle: 0)).target == .mapButton)
        l.update(input(coasting, throttle: 0, map: true), delta: 0.02)
        #expect(l.step == .circularize && l.phase == .holding)
    }

    @Test func circularizeStepPointsAtGoalButtonAndEndsWithTheNode() {
        var l = lesson(at: .circularize)
        let scene = l.scene(input(coasting, throttle: 0, map: true))
        #expect(scene.target == .mapCircularize && scene.dims && scene.passThrough)
        l.update(input(coasting, throttle: 0, map: true), delta: 0.02)
        #expect(l.step == .circularize)
        l.update(input(withNode(coasting), throttle: 0, map: true), delta: 0.02)
        #expect(l.step == .execute && l.phase == .holding)
        #expect(l.scene(input(withNode(coasting), throttle: 0, map: true)).target == .mapExecute)
    }

    @Test func mapStepAsksToReopenClosedMapAndFlightStepAsksToCloseIt() {
        let l = lesson(at: .circularize)
        let closed = l.scene(input(coasting, throttle: 0))
        #expect(closed.target == .mapButton && closed.bubble?.button == nil)
        let flightStep = lesson(at: .apoapsisCut)
        var armed = flightStep
        armed.update(input(flight(altitude: 41_000, apo: 80_500)), delta: 0.02)
        let open = armed.scene(input(flight(altitude: 41_000, apo: 80_500), map: true))
        #expect(open.target == .mapFlight)
    }

    @Test func executeStepRunsOnAutoBurnAndEndsInOrbit() {
        var l = lesson(at: .execute)
        l.update(input(withNode(coasting), throttle: 0, map: true), delta: 0.02)
        #expect(l.step == .execute && l.phase == .holding && l.holdsPhysics)
        l.update(input(withNode(coasting), throttle: 0, map: true, autoBurn: true), delta: 0.02)
        #expect(l.phase == .running && !l.holdsPhysics && !l.forcesRealTime)
        // Пока автопрожиг идёт, шаг не кончается, даже если Пе уже выше атмосферы.
        let burning = input(flight(altitude: 79_000, apo: 84_000, peri: 72_000, toApo: 10), throttle: 0.4,
                            map: true, autoBurn: true)
        l.update(burning, delta: 0.02)
        #expect(l.step == .execute)
        l.update(input(flight(altitude: 80_000, apo: 84_000, peri: 72_000, toApo: 10), throttle: 0, map: true),
                 delta: 0.02)
        #expect(l.step == .finish && l.phase == .holding && l.holdsPhysics)
    }

    @Test func deletingNodeBeforeBurnReturnsToCircularize() {
        var l = lesson(at: .execute)
        l.update(input(coasting, throttle: 0, map: true), delta: 0.02)
        #expect(l.step == .circularize && l.phase == .holding)
    }

    @Test func burnThatMissesTheOrbitFailsStep() {
        var l = lesson(at: .execute)
        l.update(input(withNode(coasting), throttle: 0, map: true, autoBurn: true), delta: 0.02)
        #expect(l.phase == .running)
        l.update(input(flight(altitude: 80_000, apo: 84_000, peri: 40_000, toApo: 10), throttle: 0, map: true),
                 delta: 0.02)
        #expect(l.phase == .failed && l.failure?.contains("не вывел") == true)
    }

    @Test func progressCountsVisibleSteps() {
        #expect(FirstFlightLesson().progress == nil)
        #expect(lesson(at: .throttleMax).progress == LessonProgress(step: 1, total: 10))
        #expect(lesson(at: .execute).progress == LessonProgress(step: 10, total: 10))
        #expect(lesson(at: .finish).progress == nil)
        #expect(LessonProgress(step: 3, total: 10).text == "Шаг 3 из 10")
    }

    // MARK: - Ошибки и откат

    @Test func nosePastFifteenDegreesForMoreThanThreeSecondsFailsStep() {
        var l = lesson(at: .follow)
        // Высота 5 км: цель около 67°, нос на 90° — отклонение больше 15°.
        let off = input(flight(altitude: 5_000, pitchDegrees: 90))
        l.update(off, delta: 1.5)
        l.update(off, delta: 1.5)
        #expect(l.phase == .running)
        l.update(off, delta: 0.5)
        #expect(l.phase == .failed && l.holdsPhysics)
        #expect(l.failure?.hasPrefix("Нос ушёл на") == true)
    }

    @Test func returningToTheMarkerResetsErrorTimer() {
        var l = lesson(at: .follow)
        let target = AscentGuide.targetPitchDegrees(altitude: 5_000)
        l.update(input(flight(altitude: 5_000, pitchDegrees: 90)), delta: 2.5)
        l.update(input(flight(altitude: 5_000, pitchDegrees: target)), delta: 0.1)
        #expect(l.pitchErrorTime == 0)
        l.update(input(flight(altitude: 5_000, pitchDegrees: 90)), delta: 2.5)
        #expect(l.phase == .running)
    }

    @Test func dismissFailureContinuesWithoutRestore() {
        var l = lesson(at: .follow)
        l.update(input(flight(altitude: 5_000, pitchDegrees: 90)), delta: 4)
        #expect(l.phase == .failed)
        l.dismissFailure()
        #expect(l.phase == .running && l.failure == nil && l.pitchErrorTime == 0)
    }

    @Test func restoreWaitsForReadyOnLiveStepButHoldsOnWaitStep() {
        var live = lesson(at: .follow)
        let t = flight(altitude: 5_000, pitchDegrees: 60)
        live.update(input(flight(altitude: 5_000, pitchDegrees: 90)), delta: 4)
        live.didRestore(t)
        #expect(live.phase == .ready && live.holdsPhysics && live.failure == nil)
        live.acknowledge(t)
        #expect(live.phase == .running)

        var wait = lesson(at: .turn)
        wait.update(input(flight(altitude: 1_500), yaw: true), delta: 0.02)
        #expect(wait.phase == .running)
        wait.didRestore(flight(altitude: 1_500))
        #expect(wait.phase == .holding)
    }

    @Test func failureIsNotCountedWhilePhysicsIsHeld() {
        var l = lesson(at: .separate)
        l.update(input(flight(altitude: 20_000, pitchDegrees: 90, fuel: 0)), delta: 10)
        #expect(l.phase == .holding && l.failure == nil)
    }

    // MARK: - Тексты и раскладка

    @Test func everyHoldingStepWithoutButtonPointsAtAnElement() {
        let t = flight(altitude: 1_500, apo: 85_000)
        for step in LessonStep.allCases where step.kind == .wait {
            #expect(step.target != nil)
            #expect(step.bubble(t) != nil)
            #expect(step.bubble(t)?.button == nil)
        }
        #expect(LessonStep.intro.bubble(t)?.button != nil)
        #expect(LessonStep.finish.bubble(t)?.button == "В ангар")
    }

    @Test func protocolSceneMatchesPhases() {
        var l = FirstFlightLesson()
        let intro = l.scene(input(pad))
        #expect(intro.dims && !intro.passThrough && intro.bubble?.button == "Понятно" && intro.target == .mission)
        #expect(l.stepIndex == 0 && !l.reachedEnd && !l.isClosed)
        l.acknowledge(input(pad))
        let wait = l.scene(input(pad, throttle: 0))
        #expect(wait.dims && wait.passThrough && wait.pausedTag && wait.target == .throttle)
        let skipped = l.skip(input(pad))
        #expect(!skipped)

        let live = lesson(at: .vertical)
        let scene = live.scene(input(flight(altitude: 500)))
        #expect(!scene.dims && scene.plateBar && scene.bubble == nil)
        #expect(live.plate(input(flight(altitude: 500)))?.head.contains("высота") == true)

        var end = lesson(at: .execute)
        end.update(input(withNode(coasting), throttle: 0, map: true, autoBurn: true), delta: 0.02)
        end.update(input(flight(altitude: 80_000, apo: 84_000, peri: 72_000, toApo: 10), throttle: 0, map: true),
                   delta: 0.02)
        let finish = end.scene(input(flight(altitude: 80_000, apo: 84_000, peri: 72_000)))
        #expect(end.reachedEnd)
        #expect(finish.bubble?.role == .hangar && finish.bubble?.exitTitle == "Остаться на орбите")
    }

    @Test func liveStepsHavePlates() {
        let t = flight(altitude: 640, apo: 85_000, peri: 34_000)
        #expect(LessonStep.vertical.plate(input(t), phase: .running)?.head.contains("высота") == true)
        var burning = t
        burning.maneuver = node(toBurn: -3, remaining: 12)
        let plate = LessonStep.execute.plate(input(burning), phase: .running)
        #expect(plate?.value == HUDFormat.speed(12) && plate?.tail.contains("из 25") == true)
        #expect(LessonStep.finish.plate(input(t), phase: .holding) == nil)
    }

    // MARK: - Раскладка плашки и стрелка

    private let screen = CGSize(width: 852, height: 393)
    private let stack = CGSize(width: TutorialLayout.plaqueWidth, height: 80)

    @Test func stackSitsTopCenterUnlessItCoversTheTarget() {
        let top = TutorialLayout.stackFrame(size: stack, screen: screen, holes: [], top: 88, bottom: 140)
        #expect(top == CGRect(x: 236, y: 88, width: 380, height: 80))
        // Цель внизу (дуга тяги) — плашка остаётся сверху.
        let throttle = CGRect(x: 322, y: 191, width: 78, height: 104)
        #expect(TutorialLayout.stackFrame(size: stack, screen: screen, holes: [throttle], top: 88, bottom: 140) == top)
        // Цель под плашкой сверху (сводка карты) — плашка уходит вниз по центру.
        let summary = CGRect(x: 170, y: 50, width: 260, height: 60)
        let moved = TutorialLayout.stackFrame(size: stack, screen: screen, holes: [summary], top: 6, bottom: 64)
        #expect(moved.minY == screen.height - 64 - stack.height && moved.midX == screen.width / 2)
        #expect(!moved.intersects(summary))
    }

    @Test func arrowLeavesThePlaqueEdgeAndStopsShortOfTheTarget() throws {
        let plaque = CGRect(x: 236, y: 88, width: 380, height: 80)
        // Цель справа внизу (кнопка «Выполнить манёвр»).
        let hole = CGRect(x: 700, y: 300, width: 140, height: 62)
        let arrow = try #require(TutorialLayout.arrow(from: plaque, to: hole))
        let onEdge = abs(arrow.start.x - plaque.maxX) < 1e-6 || abs(arrow.start.y - plaque.maxY) < 1e-6
        #expect(onEdge && plaque.insetBy(dx: -0.001, dy: -0.001).contains(arrow.start))
        #expect(!hole.contains(arrow.end))
        #expect(hole.insetBy(dx: -TutorialLayout.arrowGap - 0.5, dy: -TutorialLayout.arrowGap - 0.5).contains(arrow.end))
        // Направление — от плашки к цели.
        #expect(arrow.end.x > arrow.start.x && arrow.end.y > arrow.start.y)

        // Цель слева сверху (ускорение времени): стрелка идёт влево.
        let warp = CGRect(x: 6, y: 0, width: 160, height: 36)
        let back = try #require(TutorialLayout.arrow(from: plaque, to: warp))
        #expect(abs(back.start.x - plaque.minX) < 1e-6 && back.end.x < back.start.x)
    }

    @Test func arrowIsHiddenWhenTargetIsAdjacentOrCovered() {
        let plaque = CGRect(x: 236, y: 88, width: 380, height: 80)
        #expect(TutorialLayout.arrow(from: plaque, to: CGRect(x: 300, y: 100, width: 50, height: 30)) == nil)
        #expect(TutorialLayout.arrow(from: plaque, to: CGRect(x: 300, y: 172, width: 100, height: 20)) == nil)
        #expect(TutorialLayout.arrow(from: plaque, to: CGRect(x: 300, y: 200, width: 100, height: 40)) != nil)
    }

    @Test func edgePointLiesOnTheBorder() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
        func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }
        #expect(close(TutorialLayout.edgePoint(of: rect, towards: CGPoint(x: 300, y: 20)), CGPoint(x: 100, y: 20)))
        #expect(close(TutorialLayout.edgePoint(of: rect, towards: CGPoint(x: 50, y: -100)), CGPoint(x: 50, y: 0)))
        #expect(close(TutorialLayout.edgePoint(of: rect, towards: CGPoint(x: 50, y: 20)), CGPoint(x: 50, y: 20)))
    }

    // MARK: - Модель полёта

    @Test func modelHoldsPhysicsOnIntroAndFollowsTheLesson() throws {
        let model = FlightHUDModel(makeSimulation: { FlightSim(design: .orbit) }, tutorial: .firstFlight)
        let tutorial = try #require(model.tutorial)
        model.tick(now: 1)
        model.tick(now: 1.05)
        let start = model.snapshot.time
        model.tick(now: 1.1)
        #expect(model.snapshot.time == start)
        #expect(tutorial.firstFlightStep == .intro)

        model.tutorialAcknowledge()
        #expect(tutorial.firstFlightStep == .throttleMax)
        model.throttle = 1
        model.tick(now: 1.15)
        #expect(tutorial.firstFlightStep == .launch)
        model.send(.stage)
        model.tick(now: 1.2)
        #expect(tutorial.firstFlightStep == .vertical)
        #expect(!tutorial.holdsPhysics)

        model.tick(now: 1.25)
        model.tick(now: 1.3)
        #expect(model.snapshot.time > start)

        model.tutorialRepeat()
        #expect(model.snapshot.time == start)
        #expect(tutorial.display.phase == .ready)
        #expect(tutorial.holdsPhysics)
        model.tutorialAcknowledge()
        #expect(!tutorial.holdsPhysics)

        model.exitTutorial()
        #expect(!tutorial.isActive)
    }

    /// Площадка выше уровня моря: шаг «вертикально» считает высоту над рельефом, а не над морем.
    @Test func verticalStepCountsHeightAboveTerrainNotSeaLevel() {
        var l = lesson(at: .vertical)
        var t = flight(altitude: 1_790)
        t.heightAboveTerrain = 5
        l.update(input(t), delta: 0.02)
        #expect(l.step == .vertical && l.phase == .running)
    }

    @Test func ordinaryFlightHasNoLesson() {
        #expect(FlightHUDModel().tutorial == nil)
    }
}
