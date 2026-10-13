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
}
