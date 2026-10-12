import Foundation
import Testing
@testable import OrbitPhysics

/// Детерминированный ГПСЧ (SplitMix64).
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

@Suite("Устойчивость к произвольным проектам")
struct RobustnessTests {
    func finite(_ v: Vec3) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    func check(_ sim: FlightSim, _ name: String) {
        let s = sim.snapshot
        let t = s.telemetry
        let nums: [Double] = [s.time, s.terraRotation, t.altitude, t.heightAboveTerrain, t.speed, t.surfaceSpeed,
                              t.verticalSpeed, t.dynamicPressure, t.mach, t.warpFactor, t.missionTime, t.thrust,
                              t.maxThrust, t.atmosphereDensity, t.heating, t.gForce, t.staticPressure, t.pitch,
                              t.heading, t.roll, t.mission.maxAltitude, t.mission.maxSpeed, t.mission.maxGForce]
        #expect(nums.allSatisfy { $0.isFinite }, "\(name): телеметрия \(nums)")
        for v in s.vessels {
            let q = v.attitude
            #expect(finite(v.position) && finite(v.velocity) && finite(v.angularVelocity) && v.mass.isFinite,
                    "\(name): состояние корабля \(v.id)")
            #expect([q.w, q.x, q.y, q.z].allSatisfy { $0.isFinite }, "\(name): ориентация")
        }
        for i in t.stages {
            #expect([i.deltaV, i.twr, i.twrVacuum, i.fuelFraction, i.burnTime].allSatisfy { $0.isFinite }, "\(name): stageInfos")
        }
        if let o = t.orbit {
            #expect(!o.eccentricity.isNaN && !o.periapsisAltitude.isNaN && !o.apoapsisAltitude.isNaN, "\(name): орбита")
        }
    }

    @Test func randomDesignsDoNotBreakPhysics() {
        var rng = SplitMix64(state: 0xC0FFEE)
        let all = PartID.allCases
        for n in 0..<200 {
            let count = 1 + rng.int(15)
            let parts = (0..<count).map { _ in all[rng.int(all.count)] }
            let design = VesselDesign(name: "fuzz\(n)", parts: parts)
            let name = "#\(n) \(parts.map(\.rawValue))"
            _ = design.issues()
            _ = design.stageInfos()
            let sim = FlightSim(design: design)
            check(sim, name)
            sim.setInput(ControlInput(throttle: 1, yaw: 0.3))
            let stagings = 1 + rng.int(4)
            for k in 0..<stagings {
                sim.send(.stage)
                _ = sim.advance(realDelta: 1.0 / 60)
                if k == 0 { sim.send(.deployChute) }
            }
            for f in 0..<3_600 {
                if f % 600 == 599 { sim.send(.stage) }
                _ = sim.advance(realDelta: 1.0 / 60)
                if f % 120 == 0 { check(sim, name) }
            }
            check(sim, name)
        }
    }

    @Test func degenerateDesigns() {
        let cases: [[PartID]] = [
            [.decoupler, .podK1], [.shtil, .podK1], [.t800], [.decoupler], [.shtil], [.molot],
            [.chute, .podK1, .decoupler, .decoupler, .decoupler, .shtil],
            [.podK1, .molot, .vikhr, .t200], [.decoupler, .decoupler], [.legs, .chute],
        ]
        for parts in cases {
            let sim = FlightSim(design: VesselDesign(name: "d", parts: parts))
            sim.setInput(ControlInput(throttle: 1, pitch: 1, yaw: 1, roll: 1))
            for _ in 0..<5 { sim.send(.stage) }
            for _ in 0..<1_800 { _ = sim.advance(realDelta: 1.0 / 60) }
            check(sim, "\(parts)")
        }
    }
}
