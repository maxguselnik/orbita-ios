import Testing
import OrbitPhysics
@testable import Orbita

/// Автопрожиг на настоящей физике: цель «К Луне» → «Выполнить манёвр» → узел выполнен, встреча с Луной.
@MainActor
struct AutoBurnIntegrationTests {
    @Test func toLunaAutoBurnReachesEncounter() throws {
        let model = FlightHUDModel(makeSimulation: { TutorialID.toLuna.makeSimulation() })
        var now = 1.0
        model.tick(now: now)
        model.planManeuver(.toLuna)
        let planned = try #require(model.telemetry.maneuver)
        #expect(planned.deltaV > 500)
        model.executeManeuver()
        #expect(model.isAutoBurning)
        var frames = 0
        while (model.isAutoBurning || model.telemetry.maneuver != nil) && frames < 60_000 {
            now += 1.0 / 60
            model.tick(now: now)
            frames += 1
        }
        #expect(!model.isAutoBurning)
        #expect(model.telemetry.maneuver == nil)
        #expect(model.throttle == 0)
        let snap = model.snapshot
        let v = try #require(snap.vessels.first { $0.id == snap.activeVessel })
        let trajectory = TrajectoryPredictor.predict(body: v.body, state: StateVector(position: v.position, velocity: v.velocity),
                                                     time: snap.time, maxPatches: TrajectoryPredictor.defaultMapPatches)
        let encounter = try #require(trajectory.encounter)
        #expect(encounter.body == .luna)
        // Прожиг на конечной тяге + коррекция: Пе у Луны в годном диапазоне цели.
        #expect(encounter.periapsisAltitude > 15_000 && encounter.periapsisAltitude < 60_000, "Пе у Луны \(Int(encounter.periapsisAltitude)) м")
    }

    /// Прогон кадров 1/60 с, пока идёт автопрожиг или остаётся узел.
    private func run(_ model: FlightHUDModel, now: inout Double, limit: Int = 90_000) {
        var frames = 0
        while (model.isAutoBurning || model.telemetry.maneuver != nil) && frames < limit {
            now += 1.0 / 60
            model.tick(now: now)
            frames += 1
        }
    }

    /// Сразу после подъёма: Ап ≈ 80 км, корабль ещё в атмосфере, тяга 0.
    private func ascentTop() -> any FlightSimulation {
        ScenarioFlight(design: .orbit, goal: .orbit, keepAutopilot: false) { sim, _ in
            let t = sim.snapshot.telemetry
            return (t.orbit?.apoapsisAltitude ?? 0) >= AscentGuide.cutoffApoapsis && t.altitude > 20_000
        }
    }

    /// «Первый полёт», шаги «Скруглить орбиту» и «Выполнить манёвр»: с суборбиты в атмосфере автопрожиг
    /// сам ускоряет время (физическое ×4, потом рельсы) и выводит на орбиту с Пе выше атмосферы.
    @Test func circularizeFromAscentInAtmosphereReachesOrbit() throws {
        let model = FlightHUDModel(makeSimulation: { ascentTop() })
        model.throttle = 0
        var now = 1.0
        model.tick(now: now)
        let start = model.telemetry
        #expect(start.altitude < AscentGuide.spaceAltitude && start.warpBlocked == .atmosphere)
        #expect((start.orbit?.apoapsisAltitude ?? 0) >= AscentGuide.cutoffApoapsis)
        #expect(start.orbit.map { $0.periapsisAltitude < 0 } == true)

        model.toggleMap()
        now += 0.3
        model.tick(now: now)
        #expect(model.availableGoals.contains(.circularize))

        model.planManeuver(.circularize)
        #expect(model.maneuverGoal == .circularize)
        let planned = try #require(model.telemetry.maneuver)
        #expect(planned.deltaV > 100)
        model.executeManeuver()
        #expect(model.isAutoBurning)

        var sawPhysicalWarp = false
        var frames = 0
        while (model.isAutoBurning || model.telemetry.maneuver != nil) && frames < 90_000 {
            now += 1.0 / 60
            model.tick(now: now)
            if model.telemetry.warpIndex == TimeWarp.physicalCount - 1 { sawPhysicalWarp = true }
            frames += 1
        }
        #expect(sawPhysicalWarp, "в атмосфере должно быть физическое ×4")
        #expect(!model.isAutoBurning && model.telemetry.maneuver == nil && model.throttle == 0)
        let orbit = try #require(model.telemetry.orbit)
        #expect(orbit.periapsisAltitude > AscentGuide.spaceAltitude, "Пе \(Int(orbit.periapsisAltitude)) м")
        #expect(model.telemetry.situation == .orbiting)
    }

    /// «Полёт к Луне» целиком до захвата: «К Луне» + автопрожиг с коррекцией, ускорение до сферы Луны, там
    /// «Скруглить орбиту» + «Выполнить манёвр» — замкнутая орбита Луны (Ап < 100 км).
    @Test func lunaLessonPathFromTransferToCapture() throws {
        let model = FlightHUDModel(makeSimulation: { TutorialID.toLuna.makeSimulation() })
        var now = 1.0
        model.tick(now: now)
        model.toggleMap()
        now += 0.3
        model.tick(now: now)
        model.planManeuver(.toLuna)
        model.executeManeuver()
        run(model, now: &now)
        #expect(!model.isAutoBurning && model.telemetry.maneuver == nil)

        // Ускорить до Луны: смена сферы влияния сама сбрасывает ускорение.
        var frames = 0
        while model.telemetry.body != .luna && frames < 20_000 {
            if model.telemetry.warpIndex == 0 { model.send(.setWarp(index: TimeWarp.levels.count - 1)) }
            now += 1.0 / 60
            model.tick(now: now)
            frames += 1
        }
        #expect(model.telemetry.body == .luna, "до Луны не долетели")
        // Игра на ×1 с границы сферы влияния; цели обновляются раз в 0.25 с.
        now += 0.3
        model.tick(now: now)
        #expect(model.availableGoals.contains(.circularize), "цели у Луны: \(model.availableGoals)")

        model.planManeuver(.circularize)
        #expect(model.maneuverGoal == .circularize)
        let planned = try #require(model.telemetry.maneuver)
        #expect(planned.deltaV > 100)
        model.executeManeuver()
        #expect(model.isAutoBurning)
        run(model, now: &now)
        #expect(!model.isAutoBurning && model.telemetry.maneuver == nil)
        let orbit = try #require(model.telemetry.orbit)
        #expect(model.telemetry.body == .luna)
        #expect(orbit.apoapsisAltitude.isFinite && orbit.apoapsisAltitude < LunaStep.captureApoapsis,
                "Ап \(orbit.apoapsisAltitude) м")
        #expect(LunaStep.captured(model.telemetry))
    }
}
