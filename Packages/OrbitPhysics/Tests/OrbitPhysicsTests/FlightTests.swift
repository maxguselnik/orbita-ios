import Foundation
import Testing
@testable import OrbitPhysics

/// Крутит симуляцию кадрами по `frame` с, пока `until` не вернёт true или не выйдет `limit` с времени симуляции.
@discardableResult
func run(_ sim: FlightSim, limit: Double, frame: Double = 0.1, until: (FlightSim, [SimEvent]) -> Bool = { _, _ in false }) -> [SimEvent] {
    var all: [SimEvent] = []
    let t0 = sim.time
    while sim.time - t0 < limit {
        let ev = sim.advance(realDelta: frame)
        all += ev
        if until(sim, ev) { break }
    }
    return all
}

func circularOrbit(altitude: Double, phase: Double = 0, body: CelestialBody = Bodies.terra) -> StateVector {
    let r = body.radius + altitude
    let vc = (body.mu / r).squareRoot()
    return StateVector(position: Vec3(cos(phase), sin(phase), 0) * r, velocity: Vec3(-sin(phase), cos(phase), 0) * vc)
}

@Suite("Полёт")
struct FlightTests {
    @Test func padRotatesWithTerra() {
        let sim = FlightSim(design: .orbit)
        #expect(sim.snapshot.telemetry.situation == .prelaunch)
        #expect(sim.snapshot.telemetry.stages.count == 3)
        let r0 = sim.activeStateVector.position.length
        run(sim, limit: 10)
        let s = sim.activeStateVector
        #expect(abs(s.position.length - r0) < 1e-6)
        #expect(abs(s.velocity.length - World.terraRotationRate * r0) < 1e-6)
        #expect(sim.snapshot.telemetry.situation == .prelaunch)
        #expect(abs(sim.snapshot.telemetry.pitch - .pi / 2) < 1e-6)
        #expect(abs(sim.snapshot.telemetry.heightAboveTerrain) < 1e-6)
        // Рельсы на площадке разрешены.
        sim.send(.setWarp(index: 6))
        #expect(sim.warpIndex == 6)
        run(sim, limit: 1_000)
        #expect(abs(sim.activeStateVector.position.length - r0) < 1e-6)
    }

    @Test func manualPitchDownTurnsEastAndYawRight() {
        let sim = FlightSim(design: .orbit)
        sim.send(.setSAS(.off))
        sim.setInput(ControlInput(pitch: -1))
        // На площадке ориентация заморожена — проверяем в полёте.
        let s = sim.activeStateVector
        let up = s.position.normalized
        let flying = FlightSim(design: .orbit, body: .terra, position: s.position + up * 5_000, velocity: s.velocity,
                               attitude: sim.snapshot.vessels[0].attitude)
        flying.send(.setSAS(.off))
        flying.setInput(ControlInput(pitch: -1))
        run(flying, limit: 0.5)
        let t = flying.snapshot.telemetry
        #expect(t.pitch < .pi / 2 - 0.01)
        #expect(abs(t.heading - .pi / 2) < 0.05, "курс \(t.heading)")
        // Горизонтально на восток, спина вверх: yaw > 0 — курс вправо (на юг).
        let east = Vec3.unitZ.cross(up).normalized
        let att = Quat(basisX: east.cross(up), y: east, z: up)
        let f2 = FlightSim(design: .orbit, body: .terra, position: s.position + up * 5_000, velocity: s.velocity, attitude: att)
        #expect(abs(f2.snapshot.telemetry.heading - .pi / 2) < 1e-6)
        #expect(abs(f2.snapshot.telemetry.roll) < 1e-6)
        f2.send(.setSAS(.off))
        f2.setInput(ControlInput(yaw: 1))
        run(f2, limit: 0.5)
        #expect(f2.snapshot.telemetry.heading > .pi / 2 + 0.01)
        f2.setInput(ControlInput(roll: 1))
        run(f2, limit: 0.5)
        #expect(f2.snapshot.telemetry.roll > 0.01)
    }

    @Test func stagingAndSeparation() {
        let sim = FlightSim(design: .orbit)
        sim.setInput(ControlInput(throttle: 1))
        sim.send(.stage)
        var ev = run(sim, limit: 0.1)
        #expect(sim.snapshot.telemetry.thrust > 0)
        // Ускорение «на рельсах» запрещено при работающем двигателе.
        sim.send(.setWarp(index: 7))
        ev = run(sim, limit: 0.1)
        #expect(sim.warpIndex == TimeWarp.physicalCount - 1)
        #expect(sim.snapshot.telemetry.warpBlocked == .thrust)
        _ = ev
        run(sim, limit: 20)
        #expect(sim.activeSituation == .flying)
        #expect(sim.snapshot.telemetry.verticalSpeed > 10)
        let m0 = sim.activeMass
        sim.send(.stage)
        ev = run(sim, limit: 0.5)
        #expect(sim.snapshot.vessels.count == 2)
        #expect(sim.snapshot.vessels.filter { !$0.isActive }.count == 1)
        #expect(sim.activeMass < m0 - 9_000)
        #expect(sim.stageCount == 2)
        // «Штиль» зажжён автоматически при разделении.
        #expect(sim.snapshot.telemetry.maxThrust > 0)
        #expect(sim.snapshot.telemetry.stages.count == 2)
        _ = ev
    }

    @Test func stageEventsAndJumpFlight() {
        let sim = FlightSim(design: .jump)
        sim.send(.setSAS(.hold))
        sim.send(.stage)
        var all = run(sim, limit: 0.1)
        all += run(sim, limit: 120) { s, _ in s.snapshot.telemetry.verticalSpeed < 0 }
        #expect(all.contains(.flameout(stage: 1, solid: true)))
        #expect(all.contains { if case .maxQ = $0 { return true }; return false })
        #expect(sim.snapshot.telemetry.altitude > 10_000)
        sim.send(.stage)   // разделение
        sim.send(.stage)   // взвести парашют
        #expect(sim.snapshot.telemetry.chute == .armed)
        all += run(sim, limit: 1_500) { s, _ in s.activeSituation == .landed || s.activeSituation == .splashed || s.activeSituation == .crashed }
        #expect(all.contains(.separation(stage: 1)))
        #expect(all.contains(.chuteDeployed) && all.contains(.chuteOpened))
        let landing = all.compactMap { e -> Double? in
            switch e { case .touchdown(let v), .splashdown(let v): return v; default: return nil }
        }
        #expect(landing.count == 1 && landing[0] < 9, "посадка: \(all.filter { if case .crash = $0 { return true }; return false })")
        #expect(sim.snapshot.telemetry.chute == .cut)
        // Отделённый РДТТ упал и удалён.
        #expect(sim.snapshot.vessels.count == 1)
    }

    @Test func parachuteLandingFromSuborbital() {
        // Капсула с парашютом на суборбитальной траектории: 60 км, 2 км/с, снижение.
        let r = Bodies.terra.radius + 60_000
        let pos = Vec3(0, r, 0) // экватор, 90° от площадки
        let vel = Vec3(-1_900, -300, 0)
        let sim = FlightSim(design: VesselDesign(name: "Спуск", parts: [.chute, .podK1]), body: .terra, position: pos, velocity: vel)
        sim.send(.setSAS(.off))
        sim.send(.deployChute)
        let all = run(sim, limit: 3_000, frame: 0.2) { s, _ in
            [.landed, .splashed, .crashed].contains(s.activeSituation)
        }
        #expect(all.contains(.chuteDeployed) && all.contains(.chuteOpened))
        let speeds = all.compactMap { e -> Double? in
            switch e { case .touchdown(let v), .splashdown(let v): return v; default: return nil }
        }
        #expect(sim.activeSituation == .landed || sim.activeSituation == .splashed)
        #expect(speeds.count == 1 && speeds[0] < 9)
        #expect(all.contains { if case .maxQ = $0 { return true }; return false })
    }

    @Test func crashOnHardImpact() {
        let r = Bodies.terra.radius + 3_000
        let sim = FlightSim(design: .orbit, body: .terra, position: Vec3(0, 0, r), velocity: Vec3(0, 0, -200))
        let all = run(sim, limit: 200) { s, _ in s.activeSituation == .crashed }
        #expect(sim.activeSituation == .crashed)
        #expect(all.contains { if case .crash = $0 { return true }; return false })
    }

    @Test func warpAutoResetBeforeAtmosphere() {
        // Орбита с Пе 30 км: на рельсах до входа в атмосферу.
        let ra = Bodies.terra.radius + 120_000, rp = Bodies.terra.radius + 30_000
        let a = (ra + rp) / 2
        let va = (Bodies.terra.mu * (2 / ra - 1 / a)).squareRoot()
        let sim = FlightSim(design: .orbit, body: .terra, position: Vec3(ra, 0, 0), velocity: Vec3(0, -va, 0))
        sim.send(.setWarp(index: 6))
        #expect(sim.warpIndex == 6)
        var reset: SimEvent?
        run(sim, limit: 10_000) { _, ev in
            reset = ev.first { if case .warpReset = $0 { return true }; return false }
            return reset != nil
        }
        #expect(reset == .warpReset(.atmosphere))
        #expect(sim.warpIndex == 0)
        let alt = sim.snapshot.telemetry.altitude
        #expect(alt < 70_000 && alt > 68_000, "высота сброса \(alt)")
        // В атмосфере выше ×4 нельзя.
        sim.send(.setWarp(index: 5))
        #expect(sim.warpIndex == TimeWarp.physicalCount - 1)
        #expect(sim.snapshot.telemetry.warpBlocked == .atmosphere)
        // Физическое ускорение ×4 работает.
        let t0 = sim.time
        _ = sim.advance(realDelta: 0.1)
        #expect(abs(sim.time - t0 - 0.4) < 1e-9)
    }

    @Test func lunaTerrainResetAndLanding() {
        // Низкая орбита Луны с Пе под поверхностью: сброс на 6 км и падение/посадка.
        let b = Bodies.luna
        let ra = b.radius + 30_000, rp = b.radius - 50_000
        let a = (ra + rp) / 2
        let va = (b.mu * (2 / ra - 1 / a)).squareRoot()
        let sim = FlightSim(design: .luna, body: .luna, position: Vec3(ra, 0, 0), velocity: Vec3(0, va, 0))
        sim.send(.setWarp(index: 5))
        var all: [SimEvent] = []
        all += run(sim, limit: 5_000) { s, _ in s.warpIndex == 0 }
        #expect(all.contains(.warpReset(.terrain)))
        #expect(sim.snapshot.telemetry.altitude < 6_000)
        #expect(sim.activeBody == .luna)
    }
}
