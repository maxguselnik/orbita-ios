import OrbitPhysics
import Testing
@testable import Orbita

@Suite("Музыка: выбор настроения")
@MainActor
struct MusicDirectorTests {
    private func mood(_ t: FlightTelemetry, previous: MusicMood? = nil) -> MusicMood {
        MusicDirector.cue(for: .flight(t), previous: previous).mood
    }

    @Test func placesAndSituations() {
        #expect(MusicDirector.cue(for: .menu).mood == .spaceCenter)
        #expect(mood(FlightTelemetry(situation: .prelaunch)) == .countdown)
        #expect(mood(FlightTelemetry(verticalSpeed: 200, thrust: 900, maxThrust: 1_000, atmosphereDensity: 0.5,
                                     situation: .flying)) == .ascent)
        #expect(mood(FlightTelemetry(situation: .orbiting)) == .orbit)
        #expect(mood(FlightTelemetry(body: .sol, situation: .orbiting)) == .voyage)
        #expect(mood(FlightTelemetry(body: .terra, situation: .escaping)) == .voyage)
        #expect(mood(FlightTelemetry(body: .luna, situation: .orbiting)) == .alienOrbit)
        #expect(mood(FlightTelemetry(heightAboveTerrain: 3_000, verticalSpeed: -40, body: .luna,
                                     situation: .suborbital)) == .descent)
        #expect(mood(FlightTelemetry(body: .luna, situation: .landed)) == .surface)
        #expect(mood(FlightTelemetry(situation: .crashed)) == .crash)
    }

    @Test func homecomingOnlyAfterRealFlight() {
        let hop = FlightTelemetry(situation: .landed, mission: MissionRecord(launched: true, maxAltitude: 300))
        let back = FlightTelemetry(situation: .splashed, mission: MissionRecord(launched: true, maxAltitude: 80_000))
        #expect(mood(hop) == .countdown)
        #expect(mood(back) == .homecoming)
    }

    @Test func reentryHasHysteresis() {
        let warm = FlightTelemetry(heating: 0.2, situation: .suborbital)
        #expect(mood(warm) == .orbit)
        #expect(mood(warm, previous: .reentry) == .reentry)
        #expect(mood(FlightTelemetry(heating: 0.5, situation: .suborbital)) == .reentry)
    }

    @Test func moodChangeWaitsForHoldButUrgentIsImmediate() {
        let director = MusicDirector()
        #expect(director.update(.flight(FlightTelemetry(situation: .orbiting)), now: 0)?.mood == .orbit)
        let luna = MusicPlace.flight(FlightTelemetry(body: .luna, situation: .orbiting))
        #expect(director.update(luna, now: 1) == nil)
        #expect(director.update(luna, now: 1 + MusicDirector.hold - 0.1) == nil)
        #expect(director.update(luna, now: 1 + MusicDirector.hold)?.mood == .alienOrbit)
        // Авария и выход в меню — без ожидания.
        #expect(director.update(.flight(FlightTelemetry(body: .luna, situation: .crashed)), now: 6)?.mood == .crash)
        #expect(director.update(.menu, now: 6.1)?.mood == .spaceCenter)
    }

    @Test func intensityJitterDoesNotSpamCues() {
        let director = MusicDirector()
        func ascent(_ thrust: Double) -> MusicPlace {
            .flight(FlightTelemetry(verticalSpeed: 100, thrust: thrust, maxThrust: 1_000, atmosphereDensity: 1,
                                    situation: .flying))
        }
        #expect(director.update(ascent(1_000), now: 0) != nil)
        #expect(director.update(ascent(995), now: 0.1) == nil)
        #expect(director.update(ascent(300), now: 0.2)?.mood == .ascent)
    }
}
