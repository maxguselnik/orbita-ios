import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Перелёты и автопилот")
struct MissionTests {
    /// Круговая орбита 78 км, Луна впереди на `phase` рад.
    func parkingOrbit(phase: Double, time: Double = 0) -> StateVector {
        let lunaAngle = World.lunaInitialPhase + World.lunaAngularRate * time
        return circularOrbit(altitude: 78_000, phase: lunaAngle - phase)
    }

    @Test func hohmannPhaseIsAbout110() {
        let r = Bodies.terra.radius + 78_000
        let phi = TrajectoryPredictor.hohmannLunaPhase(radius: r) * 180 / .pi
        #expect(abs(phi - 110) < 2, "фаза \(phi)")
        let dv = TrajectoryPredictor.hohmannLunaDeltaV(radius: r)
        #expect(abs(dv - 858) < 5)
        let s = parkingOrbit(phase: 110 * .pi / 180)
        let measured = TrajectoryPredictor.lunaPhase(position: s.position, velocity: s.velocity, time: 0)
        #expect(abs(measured - 110 * .pi / 180) < 1e-9)
    }

    @Test func phase110PlusHohmannGivesEncounter() {
        let r = Bodies.terra.radius + 78_000
        let s = parkingOrbit(phase: 110 * .pi / 180)
        let dv = TrajectoryPredictor.hohmannLunaDeltaV(radius: r)
        // Прогноз узлом манёвра.
        let node = ManeuverNode(time: 0, prograde: dv)
        let pred = TrajectoryPredictor.predict(node: node, body: .terra, state: s, time: 0,
                                               mass: 6_090, thrust: 60_000, isp: 345)
        let enc = try! #require(pred?.trajectory.encounter)
        #expect(enc.body == .luna)
        #expect(enc.time > 15_000 && enc.time < 30_000)
        #expect(abs((pred?.burnTime ?? 0) - TrajectoryPredictor.burnTime(deltaV: dv, mass: 6_090, thrust: 60_000, isp: 345)) < 1e-9)
        #expect((pred?.burnTime ?? 0) > 70 && (pred?.burnTime ?? 0) < 90)
        // То же в симуляции: на рельсах до входа в SOI Луны.
        let v1 = s.velocity + s.velocity.normalized * dv
        let sim = FlightSim(design: .luna, body: .terra, position: s.position, velocity: v1)
        sim.send(.setWarp(index: 8))
        let all = run(sim, limit: 40_000, frame: 0.5) { s, _ in s.activeBody == .luna }
        #expect(all.contains(.soiChanged(from: .terra, to: .luna)))
        #expect(all.contains(.warpReset(.soiChange)))
        #expect(abs(sim.time - enc.time) < 120, "вход \(sim.time) прогноз \(enc.time)")
        // Без фазы (Луна позади) встречи нет.
        let miss = TrajectoryPredictor.predict(node: node, body: .terra, state: parkingOrbit(phase: -60 * .pi / 180), time: 0,
                                               mass: 6_090, thrust: 60_000, isp: 345, maxPatches: 2)
        #expect(miss?.trajectory.encounter == nil)
    }

    @Test func futureNodeAndManeuverBasis() {
        let s = circularOrbit(altitude: 100_000)
        let b = TrajectoryPredictor.maneuverBasis(position: s.position, velocity: s.velocity)
        #expect((b.radial - s.position.normalized).length < 1e-12)
        #expect((b.normal - .unitZ).length < 1e-12)
        let el = OrbitElements(position: s.position, velocity: s.velocity, mu: Bodies.terra.mu)
        // Прогрейд 100 м/с через полвитка: апоцентр — в противоположной точке.
        let node = ManeuverNode(time: el.period / 2, prograde: 100)
        let pred = try! #require(TrajectoryPredictor.predict(node: node, body: .terra, state: s, time: 0, mass: 1, thrust: 0, isp: 0))
        let after = pred.trajectory.patches[0].elements
        #expect(abs(after.periapsisRadius - s.position.length) < 1)
        #expect(after.apoapsisRadius > s.position.length + 50_000)
        #expect(pred.burnTime == .infinity)
        // Нормаль меняет наклонение.
        let n = try! #require(TrajectoryPredictor.predict(node: ManeuverNode(time: 0, normal: 200), body: .terra, state: s, time: 0, mass: 1, thrust: 1, isp: 300))
        #expect(n.trajectory.patches[0].elements.inclination > 0.05)
    }

    @Test func soiTransitionIsContinuous() {
        // Траектория к Луне; сравниваем положение относительно Терры по обе стороны перехода.
        let r = Bodies.terra.radius + 78_000
        let s = parkingOrbit(phase: 110 * .pi / 180)
        let v1 = s.velocity + s.velocity.normalized * TrajectoryPredictor.hohmannLunaDeltaV(radius: r)
        let sim = FlightSim(design: VesselDesign(name: "", parts: [.chute, .podK1]), body: .terra, position: s.position, velocity: v1)
        // На рельсах подлетаем близко к границе, дальше — физически.
        let enc = try! #require(sim.predictTrajectory().encounter)
        while sim.time < enc.time - 200 && sim.activeBody == .terra {
            let left = enc.time - 200 - sim.time
            let idx = TimeWarp.levels.lastIndex { $0 * 0.1 <= left / 2 } ?? 0
            if idx != sim.warpIndex { sim.send(.setWarp(index: idx)) }
            _ = sim.advance(realDelta: 0.1)
        }
        #expect(sim.activeBody == .terra)
        sim.send(.setWarp(index: 0))
        var prevT = sim.time
        var prev = World.convert(sim.activeStateVector, from: sim.activeBody, to: .terra, time: sim.time)
        var crossed = false
        while sim.time < enc.time + 200 && !crossed {
            let ev = sim.advance(realDelta: 0.02)
            let cur = World.convert(sim.activeStateVector, from: sim.activeBody, to: .terra, time: sim.time)
            if ev.contains(.soiChanged(from: .terra, to: .luna)) {
                crossed = true
                let dt = sim.time - prevT
                // Разрыв в положении/скорости относительно Терры — только движение за шаг.
                let predicted = prev.position + (prev.velocity + cur.velocity) * (dt / 2)
                #expect((cur.position - predicted).length < 0.01)
                #expect((cur.velocity - prev.velocity).length < 0.01)
                // Положение относительно Луны: ровно на границе SOI (± шаг).
                #expect(abs(sim.activeStateVector.position.length - Bodies.luna.soiRadius) < 30)
            }
            prev = cur
            prevT = sim.time
        }
        #expect(crossed)
    }

    func ascend(_ design: VesselDesign) -> (FlightSim, Autopilot, [SimEvent]) {
        let sim = FlightSim(design: design)
        let ap = Autopilot(goal: .orbit)
        var all: [SimEvent] = []
        while !ap.isFinished && sim.time < 5_000 {
            ap.update(sim)
            all += sim.advance(realDelta: ap.frameDelta)
        }
        return (sim, ap, all)
    }

    @Test(arguments: [VesselDesign.orbit, VesselDesign.luna])
    func autopilotReachesOrbit(design: VesselDesign) {
        let (sim, ap, all) = ascend(design)
        #expect(ap.phase == .done)
        let o = try! #require(sim.snapshot.telemetry.orbit)
        // Допуск: Ап 80 ± 4 км, Пе ≥ 70 км.
        #expect(abs(o.apoapsisAltitude - 80_000) < 4_000, "Ап \(o.apoapsisAltitude)")
        #expect(o.periapsisAltitude >= 70_000, "Пе \(o.periapsisAltitude)")
        #expect(o.inclination < 0.01)
        #expect(sim.activeSituation == .orbiting)
        #expect(all.contains { if case .maxQ = $0 { return true }; return false })
        #expect(all.contains { if case .separation = $0 { return true }; return false })
        print("\(design.name): Ап \(Int(o.apoapsisAltitude)) Пе \(Int(o.periapsisAltitude)) t=\(Int(sim.time)) Δv ост. \(Int(sim.snapshot.telemetry.stages.reduce(0) { $0 + $1.deltaV }))")
    }

    @Test func autopilotFullLunaMission() {
        // Старт → орбита → фаза → перелёт → коррекция → захват → посадка → взлёт → возврат → парашют.
        let sim = FlightSim(design: .luna)
        let ap = Autopilot(goal: .lunaReturn)
        var all: [SimEvent] = []
        var phases: [Autopilot.Phase] = []
        var lunaTouchdown: Double?
        while !ap.isFinished && sim.time < 400_000 {
            ap.update(sim)
            let ev = sim.advance(realDelta: ap.frameDelta)
            all += ev
            if phases.last != ap.phase { phases.append(ap.phase) }
            for case .touchdown(let v) in ev where sim.activeBody == .luna { lunaTouchdown = v }
        }
        print("Миссия «Луна»: \(phases.map(\.rawValue).joined(separator: " → ")); t = \(Int(sim.time)) с; \(sim.activeSituation)")
        #expect(ap.phase == .done)
        #expect(all.contains(.soiChanged(from: .terra, to: .luna)))
        #expect(all.contains(.soiChanged(from: .luna, to: .terra)))
        #expect((lunaTouchdown ?? 99) < 12)
        #expect(sim.activeBody == .terra)
        #expect(sim.activeSituation == .landed || sim.activeSituation == .splashed)
        #expect(all.contains(.chuteOpened))
        #expect(!all.contains { if case .crash = $0 { return true }; return false })
    }
}
