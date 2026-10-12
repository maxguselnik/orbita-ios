import Foundation
import Testing
@testable import OrbitPhysics

@Suite("РСУ")
struct RCSTests {
    /// Лёгкий корабль: модуль управления, бак монотоплива, блок РСУ.
    static let light = VesselDesign(name: "", parts: [.probe, .m100, .rcsBlock])
    /// Тяжёлый: РСУ должно заметно помогать с поворотом.
    static let heavy = VesselDesign(name: "", parts: [.probe, .t800, .t800, .rcsBlock, .rcsBlock])

    func sim(_ design: VesselDesign, nose: Vec3? = nil) -> FlightSim {
        let s = circularOrbit(altitude: 100_000)
        let q = nose.map { Quat.looking(nose: $0, zHint: .unitZ) }
        return FlightSim(design: design, body: .terra, position: s.position, velocity: s.velocity, attitude: q)
    }

    func burn(_ sim: FlightSim, translation: Vec3, seconds: Double) {
        sim.setInput(ControlInput(translation: translation))
        _ = run(sim, limit: seconds, frame: 0.05)
        sim.setInput(.neutral)
    }

    @Test func translationGivesDeltaVAndUsesMono() {
        let a = sim(Self.light), b = sim(Self.light)
        a.send(.setRCS(true))
        let m0 = a.activeMass
        let mono0 = a.snapshot.telemetry.rcs.monoMass
        let noseDir = a.snapshot.vessels[0].attitude.nose
        burn(a, translation: Vec3(0, 1, 0), seconds: 3)
        _ = run(b, limit: 3, frame: 0.05)
        let dv = (a.activeStateVector.velocity - b.activeStateVector.velocity).dot(noseDir)
        // Масса падает по ходу расхода: считаем по Isp точно.
        let spec = PartID.rcsBlock.spec
        let used = mono0 - a.snapshot.telemetry.rcs.monoMass
        #expect(abs(used - spec.massFlow * 3) / (spec.massFlow * 3) < 0.02)
        let expected = spec.thrustVacuum / m0 * 3
        #expect(abs(dv - expected) / expected < 0.05, "dv \(dv) vs \(expected)")
        #expect(abs(dv - spec.ispVacuum * standardGravity * log(m0 / (m0 - used))) / dv < 0.05)
    }

    @Test func disabledRCSGivesNoThrust() {
        let a = sim(Self.light), b = sim(Self.light)
        burn(a, translation: Vec3(0, 1, 0), seconds: 2)
        _ = run(b, limit: 2, frame: 0.05)
        #expect((a.activeStateVector.velocity - b.activeStateVector.velocity).length < 1e-6)
        let r = a.snapshot.telemetry.rcs
        #expect(r.available && !r.enabled && !r.firing)
        #expect(r.monoMass == r.monoCapacity)
    }

    @Test func noBlocksNoThrust() {
        let design = VesselDesign(name: "", parts: [.probe, .m100])
        let a = sim(design), b = sim(design)
        a.send(.setRCS(true))
        burn(a, translation: Vec3(0, 1, 0), seconds: 2)
        _ = run(b, limit: 2, frame: 0.05)
        #expect((a.activeStateVector.velocity - b.activeStateVector.velocity).length < 1e-6)
        let r = a.snapshot.telemetry.rcs
        #expect(!r.available && r.enabled && !r.firing)
    }

    @Test func monoDepletionStopsThrust() {
        let design = VesselDesign(name: "", parts: [.probe, .rcsBlock])
        let a = sim(design)
        a.send(.setRCS(true))
        a.setInput(ControlInput(translation: Vec3(0, 1, 0)))
        _ = run(a, limit: 30, frame: 0.05)
        #expect(a.snapshot.telemetry.rcs.firing)
        _ = run(a, limit: 60, frame: 0.05)
        let r = a.snapshot.telemetry.rcs
        #expect(r.monoMass < 1e-6 && !r.firing)
        let m = a.activeMass
        _ = run(a, limit: 5, frame: 0.05)
        #expect(a.snapshot.vessels[0].rcsTranslation == .zero)
        // Дальше только свободный полёт: масса неизменна, тяги нет.
        #expect(a.activeMass == m)
        #expect(a.snapshot.telemetry.rcs.monoMass < 1e-6)
    }

    @Test func rcsSpeedsUpTurning() {
        func turnTime(rcs: Bool) -> Double {
            // Нос радиально, цель — по скорости (около 90°).
            let radial = circularOrbit(altitude: 100_000).position
            let s2 = sim(Self.heavy, nose: radial)
            s2.send(.setRCS(rcs))
            s2.send(.setSAS(.prograde))
            let pro = s2.activeStateVector.velocity.normalized
            var t = 0.0
            while t < 200 {
                _ = s2.advance(realDelta: 0.05)
                t += 0.05
                if s2.snapshot.vessels[0].attitude.nose.dot(pro) > 0.99 { return t }
            }
            return t
        }
        let with = turnTime(rcs: true), without = turnTime(rcs: false)
        #expect(with < without, "с РСУ \(with) с, без \(without) с")
    }

    @Test func rotationCommandReported() {
        let s = sim(Self.heavy)
        s.send(.setRCS(true))
        s.setInput(ControlInput(pitch: 1))
        _ = s.advance(realDelta: 0.1)
        let v = s.snapshot.vessels[0]
        #expect(v.rcsRotation.x > 0.3 && v.rcsRotation.length <= 1.74)
        #expect(s.snapshot.telemetry.rcs.firing)
        s.send(.setRCS(false))
        _ = s.advance(realDelta: 0.1)
        #expect(s.snapshot.vessels[0].rcsRotation == .zero)
    }

    @Test func maneuverRemainingDropsFromRCS() throws {
        let s = sim(Self.light)
        s.send(.setRCS(true))
        s.send(.setManeuver(ManeuverNode(time: s.time + 10, prograde: 20)))
        let r0 = try #require(s.snapshot.telemetry.maneuver).remainingDeltaV
        let m0 = s.activeMass
        burn(s, translation: Vec3(0, 1, 0), seconds: 3)
        let r1 = try #require(s.snapshot.telemetry.maneuver).remainingDeltaV
        let expected = PartID.rcsBlock.spec.thrustVacuum / m0 * 3
        #expect(abs((r0 - r1) - expected) / expected < 0.08, "\(r0 - r1) vs \(expected)")
    }

    @Test func firingNozzlesBlockRails() {
        let s = sim(Self.light)
        #expect(s.railsBlockReason() == nil)
        s.send(.setRCS(true))
        s.setInput(ControlInput(translation: Vec3(0, 1, 0)))
        #expect(s.railsBlockReason() == .thrust)
        s.setInput(ControlInput(translation: Vec3(0, 0, 0)))
        #expect(s.railsBlockReason() == nil)
        s.send(.setRCS(false))
        s.setInput(ControlInput(translation: Vec3(0, 1, 0)))
        #expect(s.railsBlockReason() == nil)
    }

    @Test func monoIsNotStageFuel() {
        let base = VesselDesign(name: "", parts: [.probe, .t200, .shtil])
        let withRCS = VesselDesign(name: "", parts: [.probe, .m100, .rcsBlock, .t200, .shtil])
        let a = base.stageInfos(pressure: 0)[0], b = withRCS.stageInfos(pressure: 0)[0]
        #expect(a.fuelMass == b.fuelMass && a.fuelCapacity == b.fuelCapacity)
        #expect(a.burnTime == b.burnTime && a.fuelFraction == b.fuelFraction)
        let m0 = withRCS.mass
        let isp = b.deltaV > 0 ? PartID.shtil.spec.ispVacuum : 0
        #expect(abs(b.deltaV - isp * standardGravity * log(m0 / (m0 - b.fuelMass))) < 1e-6)
        #expect(b.deltaV < a.deltaV)
        // Баки жидкого топлива не берут моно, и наоборот.
        let ship = Ship(design: withRCS)
        #expect(ship.liquidFuel(in: 0..<ship.parts.count) == PartID.t200.spec.fuelMass)
        #expect(ship.monoMass == PartID.m100.spec.fuelMass + PartID.rcsBlock.spec.fuelMass)
    }

    @Test func designCheckFlagsMonoWithoutRCS() {
        let bad = VesselDesign(name: "", parts: [.chute, .podK1, .m100, .t200, .shtil])
        #expect(bad.issues().contains(.monoWithoutRCS))
        #expect(!DesignIssue.monoWithoutRCS.isBlocking)
        #expect(DesignIssue.monoWithoutRCS.text == "Бак монотоплива без блока РСУ")
        let ok = VesselDesign(name: "", parts: [.chute, .podK1, .m100, .rcsBlock, .t200, .shtil])
        #expect(!ok.issues().contains(.monoWithoutRCS))
        let noMono = VesselDesign(name: "", parts: [.chute, .podK1, .rcsBlock, .t200, .shtil])
        #expect(!noMono.issues().contains(.monoWithoutRCS))
    }
}
