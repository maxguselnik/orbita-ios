import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Узлы манёвров и отметки карты")
struct ManeuverTests {
    static let frame: Double = 1.0 / 60
    static let maxWarp = TimeWarp.levels.count - 1
    /// Капсула с Т-800 и «Штилем»: ≈ 10 м/с² в вакууме.
    static let ship = VesselDesign(name: "", parts: [.chute, .podK1, .t800, .shtil])

    static func orbitSim(altitude: Double = 80_000) -> FlightSim {
        let s = circularOrbit(altitude: altitude)
        return FlightSim(design: ship, body: .terra, position: s.position, velocity: s.velocity)
    }

    // MARK: Прожиг по узлу

    @Test func progradeBurnMatchesPrediction() throws {
        let sim = Self.orbitSim()
        sim.send(.stage)
        let node = ManeuverNode(time: sim.time + 120, prograde: 400)
        sim.send(.setManeuver(node))
        let prediction = try #require(sim.predictManeuver(node))
        let predictedAp = prediction.trajectory.patches[0].elements.apoapsisRadius - Bodies.terra.radius
        let m0 = try #require(sim.snapshot.telemetry.maneuver)
        #expect(abs(m0.deltaV - 400) < 1e-9)
        #expect(abs(m0.remainingDeltaV - 400) < 1e-6)
        #expect(abs(m0.timeToNode - 120) < 1e-9)
        #expect(m0.burnTime > 30 && m0.burnTime < 50)
        #expect(abs(m0.timeToBurn - (120 - m0.burnTime / 2)) < 1e-9)
        #expect(!m0.isDone)
        // Маркер навбола — по оставшемуся импульсу.
        let nb = try #require(sim.snapshot.telemetry.navball.maneuver)
        #expect(abs(nb.length - 1) < 1e-9)

        sim.send(.setSAS(.maneuver))
        var burning = false
        var lastRemaining = m0.remainingDeltaV
        var monotonic = true
        while sim.time < node.time + 200 {
            let t = sim.snapshot.telemetry
            let m = try #require(t.maneuver)
            var throttle = 0.0
            if m.timeToBurn <= 0 && !m.isDone {
                burning = true
                let amax = t.maxThrust / sim.activeMass
                throttle = clamp(m.remainingDeltaV / amax, 0.02, 1)
            }
            if burning {
                if m.remainingDeltaV > lastRemaining + 1e-6 { monotonic = false }
                lastRemaining = m.remainingDeltaV
            }
            sim.setInput(ControlInput(throttle: throttle))
            _ = sim.advance(realDelta: 0.1)
            if burning && m.isDone { break }
        }
        sim.setInput(ControlInput(throttle: 0))
        _ = sim.advance(realDelta: 1)
        let m = try #require(sim.snapshot.telemetry.maneuver)
        #expect(burning)
        #expect(monotonic)
        #expect(m.isDone)
        #expect(m.remainingDeltaV < 1, "остаток \(m.remainingDeltaV)")
        let ap = sim.activeElements.apoapsisRadius - Bodies.terra.radius
        #expect(abs(ap - predictedAp) / predictedAp < 0.03, "Ап \(ap) прогноз \(predictedAp)")
        print("Прожиг 400 м/с: Ап \(Int(ap)) м, прогноз \(Int(predictedAp)) м, остаток \(m.remainingDeltaV) м/с")
    }

    @Test func zeroNodeIsNotDone() throws {
        let sim = Self.orbitSim()
        sim.send(.setManeuver(ManeuverNode(time: sim.time + 100)))
        let m = try #require(sim.snapshot.telemetry.maneuver)
        #expect(!m.isDone)
        sim.send(.setSAS(.maneuver))
        _ = sim.advance(realDelta: 0.5)
        // SAS .maneuver для пустого узла — hold, без падения и без цели.
        #expect(!(try #require(sim.snapshot.telemetry.maneuver)).isDone)
    }

    @Test func editMidBurnKeepsBurned() throws {
        let sim = Self.orbitSim()
        sim.send(.stage)
        sim.send(.setManeuver(ManeuverNode(time: sim.time + 1, prograde: 300)))
        _ = sim.advance(realDelta: 2)
        var guardCount = 0
        while (try #require(sim.snapshot.telemetry.maneuver)).remainingDeltaV > 250, guardCount < 200 {
            sim.setInput(ControlInput(throttle: 1))
            _ = sim.advance(realDelta: 0.1)
            guardCount += 1
        }
        sim.setInput(ControlInput(throttle: 0))
        _ = sim.advance(realDelta: 0.1)
        let before = try #require(sim.snapshot.telemetry.maneuver)
        let burned = 300 - before.remainingDeltaV
        #expect(burned > 45 && burned < 60, "сожжено \(burned)")
        sim.send(.setManeuver(ManeuverNode(time: sim.time - 1, prograde: 301)))
        let after = try #require(sim.snapshot.telemetry.maneuver)
        #expect(abs(after.remainingDeltaV - (301 - burned)) < 1, "остаток \(after.remainingDeltaV)")
        #expect(!after.isDone)
        // Направление остатка — прогрейд.
        let nb = try #require(sim.snapshot.telemetry.navball.maneuver)
        let pro = sim.activeStateVector.velocity.normalized
        let v = sim.activeStateVector
        let local = nb  // локальные оси; проверяем через мировой остаток
        _ = (local, v)
        #expect(sim.maneuverRemaining.normalized.dot(pro) > 0.99)
        // Удаление узла обнуляет burned.
        sim.send(.setManeuver(nil))
        #expect(sim.maneuverBurned.length == 0)
    }

    @Test func predictWithPreTrajectoryMatches() throws {
        let sim = Self.orbitSim()
        let node = ManeuverNode(time: sim.time + 600, prograde: 200, normal: 30)
        let a = try #require(sim.predictManeuver(node))
        let pre = sim.predictTrajectory(maxPatches: 3)
        let b = try #require(sim.predictManeuver(node, using: pre, maxPatches: 3))
        #expect(a.deltaVVector == b.deltaVVector)
        #expect(a.burnTime == b.burnTime)
        #expect(a.trajectory.patches.count == b.trajectory.patches.count)
        #expect(a.trajectory.patches[0].elements.apoapsisRadius == b.trajectory.patches[0].elements.apoapsisRadius)
    }

    @Test func noNodeAndPastNode() throws {
        let sim = Self.orbitSim()
        #expect(sim.snapshot.telemetry.maneuver == nil)
        #expect(sim.snapshot.telemetry.navball.maneuver == nil)
        sim.send(.setManeuver(nil))
        // SAS по узлу без узла — как hold: нос не уходит.
        sim.send(.setSAS(.maneuver))
        let nose0 = sim.snapshot.vessels[0].attitude.nose
        _ = sim.advance(realDelta: 5)
        let nose1 = sim.snapshot.vessels[0].attitude.nose
        #expect(nose0.dot(nose1) > 0.9999)
        // Узел в прошлом: импульс от текущего состояния.
        let node = ManeuverNode(time: sim.time - 10, normal: 50)
        sim.send(.setManeuver(node))
        let m = try #require(sim.snapshot.telemetry.maneuver)
        #expect(abs(m.remainingDeltaV - 50) < 1e-6)
        #expect(m.timeToNode < 0)
        let n = sim.activeStateVector.position.cross(sim.activeStateVector.velocity).normalized
        #expect(abs(sim.maneuverRemaining.normalized.dot(n) - 1) < 1e-9)
        // Без топлива/двигателя время прожига бесконечно, начало прожига — момент узла.
        let pod = FlightSim(design: VesselDesign(name: "", parts: [.chute, .podK1]), body: .terra,
                            position: circularOrbit(altitude: 90_000).position,
                            velocity: circularOrbit(altitude: 90_000).velocity)
        pod.send(.setManeuver(ManeuverNode(time: 100, prograde: 10)))
        let pm = try #require(pod.snapshot.telemetry.maneuver)
        #expect(pm.burnTime == .infinity)
        #expect(pm.timeToBurn == pm.timeToNode)
        pod.send(.setManeuver(nil))
        #expect(pod.snapshot.telemetry.maneuver == nil)
    }

    // MARK: Ускорение до узла

    @Test func warpToManeuverStopsBeforeBurn() throws {
        let sim = Self.orbitSim()
        let node = ManeuverNode(time: sim.time + 30_000, prograde: 400)
        sim.send(.setManeuver(node))
        sim.send(.warpToManeuver)
        #expect(sim.warpIndex == Self.maxWarp)
        var frames = 0
        var stopped = false
        while !stopped && frames < 2_000 {
            frames += 1
            let ev = sim.advance(realDelta: Self.frame)
            if ev.contains(.warpReset(.maneuver)) {
                stopped = true
                let m = try #require(sim.snapshot.telemetry.maneuver)
                #expect(abs(m.timeToBurn - ManeuverStatus.warpLead) < 1, "до прожига \(m.timeToBurn)")
                #expect(sim.warpIndex == 0)
            } else {
                #expect(ev.isEmpty, "\(ev)")
            }
        }
        #expect(stopped)
        // Узел уже ближе warpLead — ничего.
        sim.send(.warpToManeuver)
        _ = sim.advance(realDelta: Self.frame)
        #expect(sim.warpIndex == 0)
    }

    /// Долгое ожидание (окно к планете): «до узла» быстрее верхнего уровня, но остановка такая же точная.
    @Test func warpToManeuverBoostsLongWait() throws {
        let sim = Self.orbitSim()
        let wait = 5_000_000.0
        sim.send(.setManeuver(ManeuverNode(time: sim.time + wait, prograde: 400)))
        sim.send(.warpToManeuver)
        _ = sim.advance(realDelta: Self.frame)
        #expect(sim.snapshot.telemetry.warpFactor == TimeWarp.maneuverBoostMax)
        var frames = 1
        var stopped = false
        while !stopped && frames < 2_000 {
            frames += 1
            if sim.advance(realDelta: Self.frame).contains(.warpReset(.maneuver)) {
                stopped = true
                let m = try #require(sim.snapshot.telemetry.maneuver)
                #expect(abs(m.timeToBurn - ManeuverStatus.warpLead) < 1, "до прожига \(m.timeToBurn)")
            }
        }
        #expect(stopped)
        // Без ускорения ×100 000 это было бы ~50 с; теперь — несколько секунд.
        #expect(Double(frames) * Self.frame < 10, "\(frames) кадров")
        #expect(TimeWarp.maneuverRate(remaining: 1_000) == TimeWarp.levels.last)
    }

    @Test func warpToManeuverCancelAndBlock() throws {
        let sim = Self.orbitSim()
        sim.send(.setManeuver(ManeuverNode(time: sim.time + 3_000, prograde: 100)))
        sim.send(.warpToManeuver)
        sim.send(.setWarp(index: 7))
        for _ in 0..<30 {
            let ev = sim.advance(realDelta: Self.frame)
            #expect(!ev.contains(.warpReset(.maneuver)))
        }
        #expect(sim.warpIndex == 7)
        #expect(sim.time > 3_000)
        sim.send(.setWarp(index: 0))
        // Тяга блокирует рельсы.
        sim.send(.setManeuver(ManeuverNode(time: sim.time + 3_000, prograde: 100)))
        sim.send(.stage)
        sim.setInput(ControlInput(throttle: 1))
        _ = sim.advance(realDelta: Self.frame)
        sim.send(.warpToManeuver)
        let ev = sim.advance(realDelta: Self.frame)
        #expect(ev.contains(.warpReset(.thrust)))
        #expect(sim.warpIndex == 0)
        // Узел без запаса — ничего.
        sim.setInput(ControlInput(throttle: 0))
        sim.send(.setManeuver(ManeuverNode(time: sim.time + 5, prograde: 100)))
        sim.send(.warpToManeuver)
        #expect(sim.advance(realDelta: Self.frame).isEmpty)
        #expect(sim.warpIndex == 0)
    }

    // MARK: Ускорение до момента

    /// «Промотать до встречи»: рельсы с разгоном, остановка точно в заданный момент, узел не нужен.
    @Test func warpUntilStopsAtTarget() throws {
        let sim = Self.orbitSim()
        let target = sim.time + 200_000
        sim.send(.warpUntil(time: target))
        #expect(sim.warpIndex == Self.maxWarp)
        var frames = 0
        var stopped = false
        while !stopped && frames < 2_000 {
            frames += 1
            let ev = sim.advance(realDelta: Self.frame)
            if ev.contains(.warpReset(.target)) {
                stopped = true
                #expect(abs(sim.time - target) < 1, "остановка в \(sim.time), цель \(target)")
                #expect(sim.warpIndex == 0)
            } else {
                #expect(ev.isEmpty, "\(ev)")
            }
        }
        #expect(stopped)
        #expect(Double(frames) * Self.frame < 10, "\(frames) кадров")
        // Момент в прошлом — ничего.
        sim.send(.warpUntil(time: sim.time - 10))
        #expect(sim.advance(realDelta: Self.frame).isEmpty)
        #expect(sim.warpIndex == 0)
    }

    @Test func warpUntilCancelBlockAndCheckpoint() throws {
        let sim = Self.orbitSim()
        sim.send(.warpUntil(time: sim.time + 3_000))
        let point = sim.checkpoint()
        // Ручной выбор уровня отменяет цель.
        sim.send(.setWarp(index: 7))
        for _ in 0..<30 {
            #expect(!sim.advance(realDelta: Self.frame).contains(.warpReset(.target)))
        }
        #expect(sim.warpIndex == 7)
        // Контрольная точка хранит цель: после отката остановка снова наступает.
        sim.restore(point)
        var stopped = false
        for _ in 0..<2_000 where !stopped {
            stopped = sim.advance(realDelta: Self.frame).contains(.warpReset(.target))
        }
        #expect(stopped)
        // Тяга блокирует рельсы.
        sim.send(.stage)
        sim.setInput(ControlInput(throttle: 1))
        _ = sim.advance(realDelta: Self.frame)
        sim.send(.warpUntil(time: sim.time + 3_000))
        #expect(sim.advance(realDelta: Self.frame).contains(.warpReset(.thrust)))
        #expect(sim.warpIndex == 0)
    }

    // MARK: Отметки карты

    /// Эллипс Пе 100 км × Ап 3000 км, наклонение 30°, аргумент перицентра 40°.
    static func inclinedEllipse(trueAnomaly nu: Double) -> StateVector {
        let mu = Bodies.terra.mu
        let rp = Bodies.terra.radius + 100_000, ra = Bodies.terra.radius + 3_000_000
        let e = (ra - rp) / (ra + rp)
        let p = rp * (1 + e)
        let w = 40 * Double.pi / 180, inc = 30 * Double.pi / 180
        func tilt(_ v: Vec3) -> Vec3 { Vec3(v.x, v.y * cos(inc), v.y * sin(inc)) }
        let pAxis = tilt(Vec3(cos(w), sin(w), 0)), qAxis = tilt(Vec3(-sin(w), cos(w), 0))
        let r = (pAxis * cos(nu) + qAxis * sin(nu)) * (p / (1 + e * cos(nu)))
        let v = (pAxis * -sin(nu) + qAxis * (e + cos(nu))) * (mu / p).squareRoot()
        return StateVector(position: r, velocity: v)
    }

    @Test func markersOnInclinedEllipse() throws {
        let s = Self.inclinedEllipse(trueAnomaly: 100 * Double.pi / 180)
        let traj = TrajectoryPredictor.predict(body: .terra, state: s, time: 500)
        #expect(traj.patches.count == 1)
        let patch = traj.patches[0]
        let el = patch.elements
        let marks = MapMarkers.compute(traj, afterManeuver: true)
        func one(_ k: MapMarker.Kind) throws -> MapMarker {
            let m = marks.filter { $0.kind == k }
            #expect(m.count == 1, "\(k): \(m.count)")
            return try #require(m.first)
        }
        #expect(marks.count == 4)
        let ap = try one(.apoapsis), pe = try one(.periapsis)
        let an = try one(.ascendingNode), dn = try one(.descendingNode)
        #expect(abs(ap.altitude - (el.apoapsisRadius - Bodies.terra.radius)) < 1)
        #expect(abs(pe.altitude - (el.periapsisRadius - Bodies.terra.radius)) < 1)
        #expect(abs(pe.time - 500 - (el.timeToPeriapsis ?? -1)) < 1e-3)
        #expect(abs(ap.time - 500 - (el.timeToApoapsis ?? -1)) < 1e-3)
        #expect(abs(an.position.z) < 1 && abs(dn.position.z) < 1, "AN z \(an.position.z), DN z \(dn.position.z)")
        #expect(patch.state(at: an.time).velocity.z > 0)
        #expect(patch.state(at: dn.time).velocity.z < 0)
        for m in marks {
            #expect(m.body == .terra && m.patchIndex == 0 && m.afterManeuver)
            #expect(m.time >= 500 && m.time <= 500 + el.period)
            #expect(abs(m.altitude - (m.position.length - Bodies.terra.radius)) < 1e-6)
        }
    }

    @Test func markersLunaEncounter() throws {
        let r = Bodies.terra.radius + 78_000
        let s = circularOrbit(altitude: 78_000, phase: World.lunaInitialPhase - 110 * Double.pi / 180)
        let v1 = s.velocity + s.velocity.normalized * TrajectoryPredictor.hohmannLunaDeltaV(radius: r)
        let traj = TrajectoryPredictor.predict(body: .terra, state: StateVector(position: s.position, velocity: v1), time: 0)
        let enc = try #require(traj.encounter)
        let marks = MapMarkers.compute(traj, afterManeuver: false)
        let entry = try #require(marks.first { $0.kind == .soiEnter(.luna) })
        #expect(entry.body == .terra && entry.patchIndex == 0)
        #expect(abs(entry.time - enc.time) < 1e-6)
        #expect(abs((entry.position - World.lunaPosition(at: entry.time)).length - Bodies.luna.soiRadius) < 1_000)
        // Эта траектория бьёт в Луну: на участке у Луны — падение, Пе (под поверхностью, после падения) не ставится.
        #expect(enc.periapsisAltitude < 0)
        #expect(marks.contains { $0.kind == .impact && $0.body == .luna && $0.patchIndex == 1 })
        #expect(!marks.contains { $0.kind == .periapsis && $0.patchIndex == 1 })
        // Пролёт (фаза 98°): Пе у Луны, выход из SOI Луны, затем участок у Терры.
        let s2 = circularOrbit(altitude: 78_000, phase: World.lunaInitialPhase - 98 * Double.pi / 180)
        let v2 = s2.velocity + s2.velocity.normalized * TrajectoryPredictor.hohmannLunaDeltaV(radius: r)
        let t2 = TrajectoryPredictor.predict(body: .terra, state: StateVector(position: s2.position, velocity: v2), time: 0)
        let enc2 = try #require(t2.encounter)
        #expect(enc2.periapsisAltitude > 0)
        let m2 = MapMarkers.compute(t2, afterManeuver: false)
        let lpe = try #require(m2.first { $0.kind == .periapsis && $0.patchIndex == 1 })
        #expect(lpe.body == .luna && abs(lpe.altitude - enc2.periapsisAltitude) < 1)
        let exit = try #require(m2.first { $0.kind == .soiExit(.luna) })
        #expect(exit.body == .luna && exit.patchIndex == 1)
        #expect(abs(exit.position.length - Bodies.luna.soiRadius) < 1_000)
        #expect(m2.contains { $0.patchIndex == 2 && $0.body == .terra })
        for m in m2 {
            #expect(m.position.x.isFinite && m.position.y.isFinite && m.position.z.isFinite && m.altitude.isFinite)
        }
        #expect(marks.filter { $0.kind == .soiEnter(.luna) }.count == 1)
        for m in marks {
            #expect(m.position.x.isFinite && m.position.y.isFinite && m.position.z.isFinite && m.altitude.isFinite)
        }
    }

    @Test func markersEdgeCases() throws {
        #expect(MapMarkers.compute(Trajectory(patches: []), afterManeuver: false).isEmpty)
        // Круговая экваториальная: ни Ап/Пе, ни узлов.
        let c = circularOrbit(altitude: 80_000)
        #expect(MapMarkers.compute(TrajectoryPredictor.predict(body: .terra, state: c, time: 0), afterManeuver: false).isEmpty)
        // Круговая наклонённая: только узлы.
        let inc = 0.3
        let tilted = StateVector(position: c.position,
                                 velocity: Vec3(c.velocity.x, c.velocity.y * cos(inc), c.velocity.y * sin(inc)))
        let tm = MapMarkers.compute(TrajectoryPredictor.predict(body: .terra, state: tilted, time: 0), afterManeuver: false)
        #expect(tm.count == 2)
        #expect(tm.allSatisfy { abs($0.position.z) < 1 })
        // Суборбитальная: Ап и падение, Пе (под землёй) после падения не ставится.
        let sub = StateVector(position: Vec3(Bodies.terra.radius + 100_000, 0, 0), velocity: Vec3(300, 1_200, 0))
        let sm = MapMarkers.compute(TrajectoryPredictor.predict(body: .terra, state: sub, time: 0), afterManeuver: false)
        let impact = try #require(sm.first { $0.kind == .impact })
        #expect(abs(impact.altitude) < 10)
        #expect(sm.contains { $0.kind == .apoapsis })
        #expect(!sm.contains { $0.kind == .periapsis })
        // Гипербола у Луны: Пе и выход из SOI Луны.
        let lr = Bodies.luna.radius + 50_000
        let hv = (2 * Bodies.luna.mu / lr).squareRoot() * 1.2
        let hyp = StateVector(position: Vec3(-lr * 3, lr * 2, 0), velocity: Vec3(hv * 0.5, 0, 0))
        let ht = TrajectoryPredictor.predict(body: .luna, state: hyp, time: 0, maxPatches: 1)
        let hm = MapMarkers.compute(ht, afterManeuver: false)
        #expect(hm.contains { $0.kind == .periapsis })
        #expect(hm.contains { $0.kind == .soiExit(.luna) })
        #expect(!hm.contains { $0.kind == .apoapsis })
        for m in sm + hm + tm {
            #expect(m.position.x.isFinite && m.position.y.isFinite && m.position.z.isFinite && m.altitude.isFinite)
        }
    }
}

@Suite("Подбор узла перелёта к Луне")
struct LunaTransferTuneTests {
    /// С орбиты 80 км у гомановской фазы (±3°): Гоман даёт Пе у Луны далеко от 30 км, подбор — 25–35 км.
    @Test(arguments: [-3.0, 0, 3])
    func tunedPeriapsisNearThirtyKilometers(phaseOffset: Double) throws {
        let r = Bodies.terra.radius + 80_000
        let phase = TrajectoryPredictor.hohmannLunaPhase(radius: r) + phaseOffset * Double.pi / 180
        let s = circularOrbit(altitude: 80_000, phase: World.lunaInitialPhase - phase)
        let node = ManeuverNode(time: 0, prograde: TrajectoryPredictor.hohmannLunaDeltaV(radius: r))
        let start = Date()
        let tuned = try #require(TrajectoryPredictor.tuneLunaPeriapsis(node: node, body: .terra, state: s, time: 0))
        #expect(Date().timeIntervalSince(start) < 0.5)
        #expect(abs(tuned.prograde - node.prograde) < 10)
        let p = try #require(TrajectoryPredictor.predict(node: tuned, body: .terra, state: s, time: 0,
                                                         mass: 1, thrust: 0, isp: 1,
                                                         maxPatches: TrajectoryPredictor.defaultMapPatches))
        let enc = try #require(p.trajectory.encounter)
        #expect(enc.body == .luna)
        #expect((25_000...35_000).contains(enc.periapsisAltitude), "Пе \(enc.periapsisAltitude)")
    }

    /// Встречи нет (импульс мал) — nil, вызывающий оставляет прежний узел.
    @Test func noEncounterReturnsNil() {
        let s = circularOrbit(altitude: 80_000)
        #expect(TrajectoryPredictor.tuneLunaPeriapsis(node: ManeuverNode(time: 0, prograde: 100),
                                                      body: .terra, state: s, time: 0) == nil)
    }
}
