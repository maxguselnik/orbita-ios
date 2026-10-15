import Foundation
import Testing
@testable import OrbitPhysics

// Этап 5.4: экипаж в проекте и реакции.

private func ids(_ seats: [CrewSeat]) -> [String?] { seats.map(\.memberID) }

/// К-3 (id 0) над К-1 (id 1).
private func twoPods() -> VesselDesign { VesselDesign(name: "t", parts: [.podK3, .podK1]) }

private func mood(_ r: CrewReactor, _ id: String) -> CrewMood {
    r.reactions.first { $0.memberID == id }!.mood
}

private func ground() -> FlightTelemetry { FlightTelemetry() }

private func flying(_ edit: (inout FlightTelemetry) -> Void) -> FlightTelemetry {
    var t = FlightTelemetry(atmosphereDensity: 1, situation: .flying)
    edit(&t)
    return t
}

@Test func crewAutoFill() {
    let d = twoPods()
    let s = d.seating()
    #expect(ids(s) == ["lera", "anton", "mira", "gosha"])
    #expect(s.map(\.partID) == [0, 0, 0, 1])
    #expect(s.map(\.index) == [0, 1, 2, 0])
    #expect(d.crew().count == 4)
}

@Test func crewExplicitPlusAuto() {
    var d = twoPods()
    d.crewSeats[1] = ["anton"]
    #expect(ids(d.seating()) == ["lera", "mira", "gosha", "anton"])
    d.crewSeats[0] = ["ghost", "lera", "lera"]
    let s = ids(d.seating())
    #expect(s == [nil, "lera", nil, "anton"])
    d.crewSeats[0] = ["mira"]  // короткий массив — недостающее nil
    #expect(ids(d.seating()) == ["mira", nil, nil, "anton"])
    d.crewSeats[99] = ["gosha"]  // удалённая деталь игнорируется
    #expect(ids(d.seating()) == ["mira", nil, nil, "anton"])
}

@Test func crewSetSeat() {
    var d = twoPods()
    d.setSeat(partID: 1, index: 0, memberID: "lera")
    #expect(ids(d.seating()) == [nil, "anton", "mira", "lera"])
    #expect(d.crewSeats[0] != nil && d.crewSeats[1] != nil)
    d.setSeat(partID: 1, index: 0, memberID: nil)
    #expect(ids(d.seating()) == [nil, "anton", "mira", nil])
    let before = d
    d.setSeat(partID: 0, index: 3, memberID: "gosha")
    d.setSeat(partID: 42, index: 0, memberID: "gosha")
    #expect(d == before)
}

@Test func crewJSONRoundTrip() throws {
    var d = twoPods()
    d.setSeat(partID: 0, index: 0, memberID: "gosha")
    let back = try JSONDecoder().decode(VesselDesign.self, from: JSONEncoder().encode(d))
    #expect(back.crewSeats == d.crewSeats)
    #expect(ids(back.seating()) == ids(d.seating()))
    let old = try JSONDecoder().decode(VesselDesign.self, from: JSONEncoder().encode(twoPods()))
    #expect(old.crewSeats.isEmpty)
}

@Test func reactorPadCalm() {
    var r = CrewReactor(crew: CrewRoster.standard)
    let cues = r.update(telemetry: ground(), events: [], dt: 0.1)
    #expect(cues.isEmpty)
    #expect(r.reactions.allSatisfy { $0.mood == .calm })
}

@Test func reactorStrainOnG() {
    var r = CrewReactor(crew: CrewRoster.standard)
    let cues = r.update(telemetry: flying { $0.gForce = 4 }, events: [], dt: 0.1)
    #expect(r.reactions.allSatisfy { $0.mood == .strain })
    #expect(cues.count == 4)
}

@Test func reactorPanicOnHeatByBravery() {
    var r = CrewReactor(crew: CrewRoster.standard)
    var t = flying { _ in }
    t.thermal = ThermalStatus(hottest: 0.55)
    _ = r.update(telemetry: t, events: [], dt: 0.1)
    #expect(mood(r, "mira") == .panic)
    #expect(mood(r, "lera") != .panic)
}

@Test func reactorPanicOnFall() {
    var r = CrewReactor(crew: CrewRoster.standard)
    let t = flying { $0.verticalSpeed = -60; $0.heightAboveTerrain = 200 }
    _ = r.update(telemetry: t, events: [], dt: 0.1)
    #expect(r.reactions.allSatisfy { $0.mood == .panic })
    var r2 = CrewReactor(crew: CrewRoster.standard)
    let t2 = flying { $0.verticalSpeed = -60; $0.heightAboveTerrain = 200; $0.chute = .open }
    _ = r2.update(telemetry: t2, events: [], dt: 0.1)
    #expect(r2.reactions.allSatisfy { $0.mood != .panic })
}

@Test func reactorTouchdownJoyThenCalm() {
    var r = CrewReactor(crew: CrewRoster.standard)
    var t = ground()
    t.situation = .landed
    _ = r.update(telemetry: t, events: [.touchdown(speed: 2)], dt: 0.1)
    #expect(mood(r, "lera") == .joy)
    for _ in 0..<70 { _ = r.update(telemetry: t, events: [], dt: 0.1) }
    #expect(mood(r, "lera") == .calm)
}

@Test func reactorCrashSticks() {
    var r = CrewReactor(crew: CrewRoster.standard)
    var t = ground()
    t.situation = .crashed
    _ = r.update(telemetry: t, events: [.crash(speed: 50)], dt: 0.1)
    for _ in 0..<100 { _ = r.update(telemetry: ground(), events: [], dt: 0.1) }
    #expect(r.reactions.allSatisfy { $0.mood == .crash && $0.intensity == 1 })
}

@Test func reactorHoldsMoodForMinimumTime() {
    var r = CrewReactor(crew: CrewRoster.standard)
    _ = r.update(telemetry: flying { $0.gForce = 4 }, events: [], dt: 0.1)
    _ = r.update(telemetry: flying { $0.gForce = 1 }, events: [], dt: 0.5)
    #expect(mood(r, "gosha") == .strain)
    _ = r.update(telemetry: flying { $0.gForce = 1 }, events: [], dt: 0.5)
    #expect(mood(r, "gosha") == .strain)
    _ = r.update(telemetry: flying { $0.gForce = 1 }, events: [], dt: 0.6)
    #expect(mood(r, "gosha") != .strain)
}

@Test func reactorCueRateLimit() {
    var r = CrewReactor(crew: [CrewRoster.standard[0]])
    var total = 0
    // strain включается/выключается раз в ~1.6 с: сигнал не чаще раза в 3 с.
    for step in 0..<40 {
        let g = (step / 8) % 2 == 0 ? 4.0 : 1.0
        total += r.update(telemetry: flying { $0.gForce = g }, events: [], dt: 0.2).count
    }
    // 8 с: входы в strain на 0 и 3.2 с (второй — уже ≥ 3 с), не больше 3.
    #expect(total >= 1 && total <= 3)
    var r2 = CrewReactor(crew: [CrewRoster.standard[0]])
    var cues = r2.update(telemetry: flying { $0.gForce = 4 }, events: [], dt: 0.1)
    #expect(cues.count == 1)
    cues = r2.update(telemetry: flying { $0.gForce = 4 }, events: [], dt: 0.1)
    #expect(cues.isEmpty)
}
