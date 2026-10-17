import OrbitPhysics
import Testing
@testable import Orbita

/// «Промотать до встречи»: встреча видна без узла, перемотка останавливается за 10 мин до входа в сферу Луны.
@MainActor
struct EncounterWarpTests {
    @Test func coastToLunaStopsTenMinutesBeforeEncounter() throws {
        let flight = ScenarioFlight(design: .luna, goal: .lunaEncounter, keepAutopilot: false) { sim, _ in
            sim.activeBody == .terra && sim.snapshot.telemetry.altitude > 2_000_000
        }
        let model = FlightHUDModel(makeSimulation: { flight })
        var now = 1.0
        model.tick(now: now)
        now += FlightHUDModel.encounterInterval + 0.1
        model.tick(now: now)
        let e = try #require(model.encounterWarp)
        #expect(e.body == .luna)
        #expect(model.canWarpToEncounter)
        let target = e.time - FlightHUDModel.encounterLead

        model.warpToEncounter()
        var frames = 0
        var started = false
        while frames < 3_000 {
            frames += 1
            now += 1.0 / 60
            model.tick(now: now)
            if model.snapshot.telemetry.warpIndex > 0 { started = true }
            if started && model.snapshot.telemetry.warpIndex == 0 { break }
        }
        #expect(started)
        #expect(model.snapshot.telemetry.warpIndex == 0)
        #expect(abs(model.snapshot.time - target) < 2, "остановка \(model.snapshot.time), цель \(target)")
        #expect(model.snapshot.telemetry.body == .terra, "до сферы Луны ещё 10 мин")
        // Запаса больше нет — кнопка неактивна.
        #expect(!model.canWarpToEncounter)
    }
}
