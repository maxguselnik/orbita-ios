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
        var t = FlightTelemetry(altitude: altitude, stages: [stage(fuel: fuel)], thrust: 1_000,
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

    private func input(_ t: FlightTelemetry, throttle: Double = 1, yaw: Bool = false) -> LessonInput {
        LessonInput(telemetry: t, throttle: throttle, yawRightHeld: yaw)
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
            (.warpToApoapsis, input(flight(altitude: 70_000, apo: 85_000, toApo: 20))),
        ]
        for (step, i) in script {
            if l.step == target { break }
            #expect(l.step == step)
            if step == .separate { l.update(input(flight(altitude: 20_000, fuel: 0)), delta: 0.02) }
            if step == .apoapsisCut { l.update(input(flight(altitude: 40_000, apo: 85_000)), delta: 0.02) }
            if step == .turn { l.update(input(flight(altitude: 1_500), yaw: true), delta: 0.02) }
            l.update(i, delta: 0.02)
        }
        return l
    }

    // MARK: - Порядок и переходы

    @Test func stepsGoInDocumentedOrder() {
        #expect(LessonStep.allCases == [.intro, .throttleMax, .launch, .vertical, .turn, .follow, .separate,
                                        .apoapsisCut, .warpToApoapsis, .circularize, .finish])
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
        #expect(l.step == .warpToApoapsis && l.phase == .holding)
    }

    @Test func warpStepStartsOnWarpAndEndsNearApoapsis() {
        var l = lesson(at: .warpToApoapsis)
        let far = flight(altitude: 60_000, apo: 85_000, toApo: 120)
        l.update(input(far, throttle: 0), delta: 0.02)
        #expect(l.phase == .holding)
        l.update(input(flight(altitude: 60_000, apo: 85_000, toApo: 120, warpIndex: 2), throttle: 0), delta: 0.02)
        #expect(l.step == .warpToApoapsis && l.phase == .running)
        l.update(input(flight(altitude: 79_000, apo: 85_000, toApo: 45, warpIndex: 2), throttle: 0), delta: 0.02)
        #expect(l.step == .warpToApoapsis)
        l.update(input(flight(altitude: 80_000, apo: 85_000, toApo: 29), throttle: 0), delta: 0.02)
        #expect(l.step == .circularize && l.phase == .running)
    }

    @Test func orbitFinishesLessonAndHoldsOnSummary() {
        var l = lesson(at: .circularize)
        l.update(input(flight(altitude: 80_000, apo: 84_000, peri: 60_000, toApo: 10)), delta: 0.02)
        #expect(l.step == .circularize)
        l.update(input(flight(altitude: 80_000, apo: 84_000, peri: 72_000, toApo: 10)), delta: 0.02)
        #expect(l.step == .finish && l.phase == .holding && l.holdsPhysics)
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

    @Test func apoapsisDroppingDuringCircularizationFailsStep() {
        var l = lesson(at: .circularize)
        l.update(input(flight(altitude: 80_000, apo: 84_000, peri: 50_000, toApo: 10)), delta: 0.02)
        #expect(l.phase == .running)
        l.update(input(flight(altitude: 80_000, apo: 70_000, peri: 50_000, toApo: 10)), delta: 0.02)
        #expect(l.phase == .failed)
        #expect(l.failure?.contains("Апоцентр") == true)
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

    @Test func liveStepsHavePlates() {
        let t = flight(altitude: 640, apo: 85_000, peri: 34_000)
        #expect(LessonStep.vertical.plate(t, phase: .running)?.head.contains("высота") == true)
        #expect(LessonStep.circularize.plate(t, phase: .running)?.tail.contains("70 км") == true)
        #expect(LessonStep.finish.plate(t, phase: .holding) == nil)
    }

    @Test func bubbleStaysOnScreenAndOffTheCutout() {
        let screen = CGSize(width: 852, height: 393)
        let bubble = CGSize(width: 260, height: 90)
        let holes: [CGRect] = [
            CGRect(x: 0, y: 90, width: 162, height: 40),     // карточка миссии
            CGRect(x: 322, y: 191, width: 78, height: 104),  // дуга тяги
            CGRect(x: 60, y: 300, width: 162, height: 52),   // кнопка ступени
            CGRect(x: 693, y: 240, width: 52, height: 52),   // ▶ крестовины (у правого края)
            CGRect(x: 6, y: 0, width: 160, height: 36),      // ускорение времени
        ]
        for hole in holes {
            let origin = TutorialLayout.bubbleOrigin(hole: hole, bubble: bubble, screen: screen)
            let rect = CGRect(origin: origin, size: bubble)
            #expect(CGRect(origin: .zero, size: screen).contains(rect))
            #expect(!rect.intersects(hole))
        }
        let centered = TutorialLayout.bubbleOrigin(hole: nil, bubble: bubble, screen: screen)
        #expect(centered == CGPoint(x: 296, y: 151.5))
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
        #expect(tutorial.step == .intro)

        model.tutorialAcknowledge()
        #expect(tutorial.step == .throttleMax)
        model.throttle = 1
        model.tick(now: 1.15)
        #expect(tutorial.step == .launch)
        model.send(.stage)
        model.tick(now: 1.2)
        #expect(tutorial.step == .vertical)
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

    @Test func ordinaryFlightHasNoLesson() {
        #expect(FlightHUDModel().tutorial == nil)
    }
}
