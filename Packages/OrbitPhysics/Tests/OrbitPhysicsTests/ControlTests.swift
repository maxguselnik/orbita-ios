import Foundation
import Testing
@testable import OrbitPhysics

@Suite("SAS, навбол, телеметрия")
struct ControlTests {
    func orbiter() -> FlightSim {
        let s = circularOrbit(altitude: 100_000)
        // Нос смотрит радиально наружу.
        return FlightSim(design: .orbit, body: .terra, position: s.position, velocity: s.velocity,
                         attitude: Quat.looking(nose: s.position, zHint: .unitZ))
    }

    @Test(arguments: [SASMode.prograde, .retrograde, .normal, .antiNormal, .radialOut, .radialIn])
    func sasModesAlignNose(mode: SASMode) {
        let sim = orbiter()
        sim.send(.setSAS(mode))
        run(sim, limit: 30)
        let st = sim.activeStateVector
        let b = TrajectoryPredictor.maneuverBasis(position: st.position, velocity: st.velocity)
        let target: Vec3 = switch mode {
        case .prograde: b.prograde
        case .retrograde: -b.prograde
        case .normal: b.normal
        case .antiNormal: -b.normal
        case .radialOut: b.radial
        default: -b.radial
        }
        let nose = sim.snapshot.vessels[0].attitude.nose
        #expect(nose.dot(target) > 0.999, "\(mode): \(nose.dot(target))")
        // Маркер навбола соответствующего направления — по носу (+Y в осях корабля).
        let nb = sim.snapshot.telemetry.navball
        let marker: Vec3? = switch mode {
        case .prograde: nb.prograde
        case .retrograde: nb.prograde.map { -$0 }
        case .normal: nb.normal
        case .antiNormal: nb.normal.map { -$0 }
        case .radialOut: nb.radialOut
        default: nb.radialOut.map { -$0 }
        }
        #expect((marker?.y ?? 0) > 0.999)
    }

    @Test func holdKeepsAttitude() {
        let sim = orbiter()
        sim.send(.setSAS(.hold))
        let q0 = sim.snapshot.vessels[0].attitude
        sim.setInput(ControlInput(pitch: 1))
        run(sim, limit: 1)
        sim.setInput(.neutral)
        run(sim, limit: 10)
        let q1 = sim.snapshot.vessels[0].attitude
        run(sim, limit: 20)
        let q2 = sim.snapshot.vessels[0].attitude
        #expect(q0.nose.dot(q1.nose) < 0.99)        // повернули
        #expect(q1.nose.dot(q2.nose) > 0.9999)      // и держим
        #expect(sim.snapshot.vessels[0].angularVelocity.length < 0.01)
    }

    @Test func telemetryOnPadAndAscent() {
        let sim = FlightSim(design: .orbit)
        var t = sim.snapshot.telemetry
        #expect(abs(t.staticPressure - exp(-Terrain.padHeight / 5_600)) < 1e-9)
        #expect(t.chute == .stowed && t.chuteSafe)
        #expect(t.orbit == nil && t.warpIndex == 0 && t.warpBlocked == nil)
        _ = sim.advance(realDelta: 0.1)
        #expect(abs(sim.snapshot.telemetry.gForce - 1) < 0.01)
        sim.setInput(ControlInput(throttle: 1))
        sim.send(.stage)
        let ev = run(sim, limit: 30)
        #expect(ev.contains(.ignition(stage: 2, solid: false)))
        t = sim.snapshot.telemetry
        #expect(t.missionTime > 29 && t.missionTime < 31)
        #expect(t.thrust > 0 && t.thrust <= t.maxThrust + 1e-6)
        #expect(!t.solidBurning)
        #expect(t.mach > 0.3 && t.dynamicPressure > 1_000 && t.atmosphereDensity > 0)
        #expect(t.gForce > 1)
        #expect(t.stages[0].fuelFraction < 1 && t.stages[1].fuelFraction == 1)
        #expect(t.orbit?.body == .terra)
        #expect(sim.snapshot.lunaVelocity.length > 500)
        #expect(t.heating == 0)
    }

    @Test func burnTimeMatchesActualBurn() {
        // Прогноз времени прожига совпадает с реальным прожигом 300 м/с «Штилем» в вакууме.
        let s = circularOrbit(altitude: 200_000)
        let design = VesselDesign(name: "", parts: [.chute, .podK1, .t400, .shtil])
        let sim = FlightSim(design: design, body: .terra, position: s.position, velocity: s.velocity)
        sim.send(.stage)
        let p = sim.currentStagePerformance
        #expect(abs(p.thrust - 60_000) < 1e-6 && abs(p.isp - 345) < 1e-9)
        let pred = try! #require(sim.predictManeuver(ManeuverNode(time: sim.time, prograde: 300)))
        let m0 = sim.activeMass
        sim.send(.setSAS(.prograde))
        sim.setInput(ControlInput(throttle: 1))
        var burned = 0.0
        while true {
            let m = sim.activeMass
            let dv = 345 * standardGravity * log(m0 / m)
            if dv >= 300 { break }
            _ = sim.advance(realDelta: 0.02)
            burned += 0.02
        }
        #expect(abs(burned - pred.burnTime) < 0.1)
    }
}

@Suite("Контрольная точка")
struct CheckpointTests {
    @Test func restoreReplaysIdentically() {
        let sim = FlightSim(design: .orbit)
        sim.setInput(ControlInput(throttle: 1))
        sim.send(.stage)
        for _ in 0..<300 { _ = sim.advance(realDelta: 0.02) }
        let cp = sim.checkpoint()
        for _ in 0..<300 { _ = sim.advance(realDelta: 0.02) }
        let first = sim.snapshot.vessels[0].position
        let alt = sim.snapshot.telemetry.altitude
        sim.restore(cp)
        #expect(sim.snapshot.telemetry.altitude < alt)
        for _ in 0..<300 { _ = sim.advance(realDelta: 0.02) }
        let second = sim.snapshot.vessels[0].position
        #expect((first - second).length < 1e-6)
    }
}
