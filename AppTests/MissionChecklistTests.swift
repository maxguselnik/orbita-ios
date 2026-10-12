import Testing
import OrbitPhysics
@testable import Orbita

@MainActor
struct MissionChecklistTests {
    private func states(_ t: FlightTelemetry, reached: Int = 0) -> [MissionStepState] {
        MissionChecklist.steps(t, reached: reached).map(\.state)
    }

    private func flying(altitude: Double, apo: Double? = nil, peri: Double = -300_000) -> FlightTelemetry {
        var t = FlightTelemetry(altitude: altitude, situation: .suborbital)
        t.mission.launched = true
        t.thrust = 1_000
        if let apo {
            t.orbit = OrbitSummary(body: .terra, apoapsisAltitude: apo, periapsisAltitude: peri,
                                   timeToApoapsis: 100, timeToPeriapsis: nil, eccentricity: 0.5, inclination: 0, period: 3_000)
        }
        return t
    }

    @Test func padShowsIgnitionAsCurrent() {
        let t = FlightTelemetry(situation: .prelaunch)
        #expect(states(t) == [.current, .pending, .pending, .pending, .pending])
        #expect(MissionChecklist.summary(done: 0) == "1/5 · Зажигание")
    }

    @Test func afterIgnitionVerticalStepIsCurrent() {
        var t = FlightTelemetry(situation: .prelaunch)
        t.thrust = 500
        #expect(states(t) == [.done, .current, .pending, .pending, .pending])
    }

    @Test func turnStepAtFiveKilometers() {
        let t = flying(altitude: 5_000)
        #expect(states(t) == [.done, .done, .current, .pending, .pending])
    }

    @Test func apoapsisAndCircularization() {
        var t = flying(altitude: 40_000, apo: 85_000)
        #expect(states(t) == [.done, .done, .done, .current, .pending])
        t.altitude = AscentGuide.spaceAltitude + 1
        t.thrust = 0
        #expect(states(t) == [.done, .done, .done, .done, .current])
    }

    @Test func orbitCompletesAllSteps() {
        let t = flying(altitude: 80_000, apo: 82_000, peri: 75_000)
        #expect(states(t) == Array(repeating: .done, count: 5))
        #expect(MissionChecklist.summary(done: 5) == "Вы на орбите")
    }

    @Test func progressNeverRegresses() {
        // Корабль упал назад на 5 км, но шаги до Ап 80 км остаются отмеченными.
        let t = flying(altitude: 5_000)
        #expect(states(t, reached: 3) == [.done, .done, .done, .current, .pending])
        #expect(MissionChecklist.steps(t, reached: 99).allSatisfy { $0.state == .done })
    }

    @Test func notTerraHasNoProgress() {
        var t = flying(altitude: 5_000)
        t.body = .luna
        #expect(MissionChecklist.completed(t) == 0)
    }

    @Test func modelKeepsMaximumProgress() {
        let model = FlightHUDModel()
        #expect(model.missionActive == (model.telemetry.body == .terra && model.telemetry.situation == .prelaunch))
        #expect(model.missionProgress == 0)
    }

    @Test func altimeterModeUsesTerrainNearGroundWithHysteresis() {
        var t = FlightTelemetry(altitude: 1_786, heightAboveTerrain: 0, situation: .prelaunch)
        #expect(AltimeterMode.overTerrain(previous: false, t))
        t.situation = .flying
        t.heightAboveTerrain = 800
        #expect(AltimeterMode.overTerrain(previous: false, t))
        t.heightAboveTerrain = 1_200
        #expect(!AltimeterMode.overTerrain(previous: false, t))
        #expect(AltimeterMode.overTerrain(previous: true, t))
        t.heightAboveTerrain = 1_600
        #expect(!AltimeterMode.overTerrain(previous: true, t))
        t.situation = .landed
        #expect(AltimeterMode.overTerrain(previous: false, t))
    }
}
