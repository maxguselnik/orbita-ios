import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Рельсы, парашют, производительность")
struct RailsTests {
    static let frame: Double = 1.0 / 60
    static let maxWarp = TimeWarp.levels.count - 1

    // MARK: Время до радиуса

    @Test func timeToRadiusMatchesPropagation() {
        let mu = Bodies.terra.mu
        // Эллипс: Пе 100 км, Ап 5000 км; старт сразу после перицентра.
        let rp = Bodies.terra.radius + 100_000, ra = 5_000_000.0
        let a = (rp + ra) / 2
        let vp = (mu * (2 / rp - 1 / a)).squareRoot()
        let p0 = Kepler.propagate(position: Vec3(rp, 0, 0), velocity: Vec3(0, vp, 0), mu: mu, dt: 100)
        for (radius, outbound) in [(2_000_000.0, true), (2_000_000.0, false), (Bodies.terra.radius + 150_000, false)] {
            let t = try! #require(Kepler.timeToRadius(radius, position: p0.position, velocity: p0.velocity, mu: mu, outbound: outbound))
            let s = Kepler.propagate(position: p0.position, velocity: p0.velocity, mu: mu, dt: t)
            #expect(abs(s.position.length - radius) < 1e-3, "r=\(radius) out=\(outbound)")
            let vr: Double = s.position.dot(s.velocity)
            #expect(outbound ? vr > 0 : vr < 0)
        }
        #expect(Kepler.timeToRadius(6_000_000, position: p0.position, velocity: p0.velocity, mu: mu, outbound: true) == nil)
        // Гипербола у Луны: выход из SOI.
        let lm = Bodies.luna.mu
        let r0 = Bodies.luna.radius + 50_000
        let v0 = (2 * lm / r0).squareRoot() * 1.2
        let t = try! #require(Kepler.timeToRadius(Bodies.luna.soiRadius, position: Vec3(r0, 0, 0), velocity: Vec3(0, v0, 0),
                                                  mu: lm, outbound: true))
        let s = Kepler.propagate(position: Vec3(r0, 0, 0), velocity: Vec3(0, v0, 0), mu: lm, dt: t)
        #expect(abs(s.position.length - Bodies.luna.soiRadius) < 1e-3)
        #expect(Kepler.timeToRadius(Bodies.luna.radius, position: Vec3(r0, 0, 0), velocity: Vec3(0, v0, 0), mu: lm, outbound: false) == nil)
    }

    // MARK: Рельсы у границы SOI

    /// Ап чуть внутри SOI Луны: раньше шаг падал до 0.5 с (до 2000 вызовов Кеплера за кадр).
    @Test func lunaApoapsisJustInsideSOI() {
        let b = Bodies.luna
        let ra = b.soiRadius - 500, rp = b.radius + 30_000
        let a = (ra + rp) / 2
        let vp = (b.mu * (2 / rp - 1 / a)).squareRoot()
        let sim = FlightSim(design: VesselDesign(name: "", parts: [.chute, .podK1]), body: .luna,
                            position: Vec3(rp, 0, 0), velocity: Vec3(0, vp, 0))
        sim.send(.setWarp(index: Self.maxWarp))
        #expect(sim.warpIndex == Self.maxWarp)
        let t0 = sim.time
        var maxCalls = 0
        let frames = 120   // ≈ 5 оборотов
        for _ in 0..<frames {
            let ev = sim.advance(realDelta: Self.frame)
            #expect(ev.isEmpty)
            maxCalls = max(maxCalls, sim.lastRailsKeplerCalls)
        }
        #expect(maxCalls <= 2, "вызовов Кеплера за кадр: \(maxCalls)")
        #expect(sim.activeBody == .luna)
        #expect(sim.railsBacklog == 0)
        // Время не теряется.
        let expected = Double(frames) * Self.frame * TimeWarp.levels[Self.maxWarp]
        #expect(abs(sim.time - t0 - expected) < 1e-6)
        // Орбита сохранилась (Кеплер точен).
        let el = sim.activeElements
        #expect(abs(el.apoapsisRadius - ra) < 1)
    }

    /// Орбита Терры, проходящая в ~1 км снаружи SOI Луны: поиск входа не мельчит шаг.
    @Test func terraOrbitGrazingLunaSOI() {
        let mu = Bodies.terra.mu
        let soi = Bodies.luna.soiRadius
        let rp = Bodies.terra.radius + 100_000
        // Апоцентр на 20 км глубже границы SOI; старт в перицентре, к апоцентру Луна смещена на угол δ.
        let ra = Bodies.luna.orbitRadius - soi + 20_000
        func start(_ delta: Double) -> (StateVector, Double) {
            let a = (rp + ra) / 2
            let half: Double = Double.pi * (a * a * a / mu).squareRoot()
            let vp = (mu * (2 / rp - 1 / a)).squareRoot()
            let theta0: Double = World.lunaInitialPhase + World.lunaAngularRate * half - Double.pi - delta
            let c: Double = cos(theta0)
            let sn: Double = sin(theta0)
            return (StateVector(position: Vec3(c, sn, 0) * rp, velocity: Vec3(-sn, c, 0) * vp), half)
        }
        // Наименьшее расстояние до Луны около апоцентра (плотная выборка).
        func closest(_ delta: Double) -> Double {
            let (s0, half) = start(delta)
            var best = Double.infinity
            for i in 0...4_000 {
                let t: Double = half * (0.5 + 1.0 * Double(i) / 4_000)
                let p = Kepler.propagate(position: s0.position, velocity: s0.velocity, mu: mu, dt: t).position
                best = min(best, (p - World.lunaPosition(at: t)).length)
            }
            return best
        }
        // δ, при котором орбита проходит в ~1 км снаружи SOI (δ = 0 — вход, δ = 0.5 — мимо).
        var lo = 0.0, hi = 0.5
        #expect(closest(lo) < soi && closest(hi) > soi + 1_000)
        for _ in 0..<40 {
            let mid = 0.5 * (lo + hi)
            if closest(mid) - soi > 1_000 { hi = mid } else { lo = mid }
        }
        let gap = closest(hi) - soi
        #expect(gap > 0 && gap < 1_100)
        let (s0, half) = start(hi)
        let sim = FlightSim(design: VesselDesign(name: "", parts: [.chute, .podK1]), body: .terra,
                            position: s0.position, velocity: s0.velocity)
        sim.send(.setWarp(index: Self.maxWarp))
        let t0 = sim.time
        var maxCalls = 0
        var minDist = Double.infinity
        var maxBacklog = 0.0
        let frames = Int((2 * half) / (Self.frame * TimeWarp.levels[Self.maxWarp])) + 1
        for _ in 0..<frames {
            _ = sim.advance(realDelta: Self.frame)
            maxCalls = max(maxCalls, sim.lastRailsKeplerCalls)
            maxBacklog = max(maxBacklog, sim.railsBacklog)
            minDist = min(minDist, (sim.activeStateVector.position - World.lunaPosition(at: sim.time)).length)
        }
        #expect(maxCalls <= 24, "вызовов Кеплера за кадр: \(maxCalls)")
        #expect(maxBacklog == 0)
        #expect(sim.activeBody == .terra)
        #expect(sim.warpIndex == Self.maxWarp)
        #expect(sim.railsBacklog == 0)
        let expected = Double(frames) * Self.frame * TimeWarp.levels[Self.maxWarp]
        #expect(abs(sim.time - t0 - expected) < 1e-6)
        print("Касание SOI (\(Int(gap)) м): вызовов Кеплера за кадр ≤ \(maxCalls), в кадрах \(Int(minDist - soi)) м над SOI")
    }

    /// Перелёт к Луне на ×100 000: вход в SOI точно по прогнозу, бюджет соблюдён.
    @Test func lunaTransferAtMaxWarp() {
        let r = Bodies.terra.radius + 78_000
        let s = circularOrbit(altitude: 78_000, phase: World.lunaInitialPhase - 110 * Double.pi / 180)
        let v1 = s.velocity + s.velocity.normalized * TrajectoryPredictor.hohmannLunaDeltaV(radius: r)
        let sim = FlightSim(design: VesselDesign(name: "", parts: [.chute, .podK1]), body: .terra, position: s.position, velocity: v1)
        let enc = try! #require(sim.predictTrajectory().encounter)
        sim.send(.setWarp(index: Self.maxWarp))
        var maxCalls = 0
        var entered = false
        var frames = 0
        while !entered && frames < 1_000 {
            frames += 1
            let ev = sim.advance(realDelta: Self.frame)
            if sim.warpIndex >= TimeWarp.physicalCount || ev.contains(.soiChanged(from: .terra, to: .luna)) {
                maxCalls = max(maxCalls, sim.lastRailsKeplerCalls)
            }
            if ev.contains(.soiChanged(from: .terra, to: .luna)) {
                entered = true
                #expect(ev.contains(.warpReset(.soiChange)))
                // Остаток кадра — физикой на ×1: долей секунды позже входа.
                #expect(sim.time > enc.time - 1 && sim.time < enc.time + 1, "вход \(sim.time) прогноз \(enc.time)")
                #expect(abs(sim.activeStateVector.position.length - Bodies.luna.soiRadius) < 1_000)
            }
        }
        #expect(entered)
        #expect(maxCalls <= 12, "вызовов Кеплера за кадр: \(maxCalls)")
        print("Перелёт ×100 000: вход в SOI за \(frames) кадров, вызовов Кеплера за кадр ≤ \(maxCalls)")
    }

    /// Авто-сброс перед атмосферой посреди кадра: время кадра не теряется.
    @Test func atmosphereResetKeepsFrameTime() {
        let ra = Bodies.terra.radius + 2_000_000, rp = Bodies.terra.radius + 30_000
        let a = (ra + rp) / 2
        let va = (Bodies.terra.mu * (2 / ra - 1 / a)).squareRoot()
        let sim = FlightSim(design: VesselDesign(name: "", parts: [.chute, .podK1]), body: .terra,
                            position: Vec3(ra, 0, 0), velocity: Vec3(0, va, 0))
        sim.send(.setWarp(index: Self.maxWarp - 1))
        var frames = 0
        var reset = false
        var maxCalls = 0
        while !reset && frames < 10_000 {
            frames += 1
            let t0 = sim.time
            let ev = sim.advance(realDelta: Self.frame)
            maxCalls = max(maxCalls, sim.lastRailsKeplerCalls)
            if ev.contains(.warpReset(.atmosphere)) {
                reset = true
                let alt = sim.snapshot.telemetry.altitude
                #expect(alt < 70_000 && alt > 69_000, "высота сброса \(alt)")
                #expect(sim.warpIndex == 0)
                #expect(sim.time - t0 <= Self.frame * TimeWarp.levels[Self.maxWarp - 1] + 1e-6)
            } else {
                #expect(abs(sim.time - t0 - Self.frame * TimeWarp.levels[Self.maxWarp - 1]) < 1e-6)
            }
        }
        #expect(reset)
        #expect(maxCalls <= 2)
    }

    // MARK: Двигатель на грунте

    @Test func noRailsWithEngineOnGround() {
        // «Штиль» у земли (Isp 85) не поднимает капсулу с Т-800: стоит на площадке с работающим двигателем.
        let sim = FlightSim(design: VesselDesign(name: "", parts: [.podK1, .t800, .shtil]))
        sim.setInput(ControlInput(throttle: 1))
        sim.send(.stage)
        _ = sim.advance(realDelta: 0.1)
        #expect(sim.snapshot.telemetry.thrust > 0)
        #expect(sim.activeSituation == .prelaunch)
        #expect(sim.railsBlockReason() == .thrust)
        sim.send(.setWarp(index: 6))
        #expect(sim.warpIndex == TimeWarp.physicalCount - 1)
        #expect(sim.snapshot.telemetry.warpBlocked == .thrust)
        // Без тяги на площадке рельсы снова можно.
        sim.setInput(ControlInput(throttle: 0))
        #expect(sim.railsBlockReason() == nil)
    }

    // MARK: Парашют

    /// Капсула падает вертикально (щитом вниз), парашют взведён заранее.
    func capsuleDescent(altitude: Double, speed: Double) -> (maxG: Double, landing: Double?, events: [SimEvent]) {
        let r = Bodies.terra.radius + altitude
        let pos = Vec3(0, r, 0)
        let up = pos.normalized
        let vel = World.surfaceVelocity(body: .terra, position: pos) - up * speed
        let east = Vec3.unitZ.cross(up).normalized
        let att = Quat(basisX: east, y: up, z: east.cross(up))
        let sim = FlightSim(design: VesselDesign(name: "Спуск", parts: [.chute, .podK1]), body: .terra,
                            position: pos, velocity: vel, attitude: att)
        sim.send(.setSAS(.off))
        sim.send(.deployChute)
        var maxG = 0.0
        var all: [SimEvent] = []
        while sim.time < 5_000 && ![.landed, .splashed, .crashed].contains(sim.activeSituation) {
            // Пока купол наполняется — по одному шагу физики, чтобы не пропустить пик.
            let frame = sim.snapshot.telemetry.chute == .open ? 0.5 : FlightSim.maxStep
            all += sim.advance(realDelta: frame)
            maxG = max(maxG, sim.snapshot.telemetry.gForce)
        }
        let landing = all.compactMap { e -> Double? in
            switch e { case .touchdown(let v), .splashdown(let v): return v; default: return nil }
        }.first
        return (maxG, landing, all)
    }

    @Test func chuteOpeningShockIsLimited() {
        let (maxG, landing, all) = capsuleDescent(altitude: 5_000, speed: 300)
        #expect(all.first == .chuteDeployed)
        #expect(all.contains(.chuteOpened))
        #expect(maxG <= 12, "пик \(maxG) g")
        #expect((landing ?? 99) < 9, "посадка \(landing ?? -1) м/с")
        print("Парашют 5 км / 300 м/с: пик \(String(format: "%.1f", maxG)) g, посадка \(String(format: "%.1f", landing ?? -1)) м/с")
    }

    @Test func chuteHighFastDeployment() {
        // Граница допуска SPEC: 33 км и 440 м/с — раскрывается, пик умеренный.
        let (maxG, landing, all) = capsuleDescent(altitude: 33_000, speed: 440)
        #expect(all.first == .chuteDeployed)
        #expect(all.contains(.chuteOpened))
        #expect(maxG <= 12, "пик \(maxG) g")
        #expect((landing ?? 99) < 9)
    }

    // MARK: Производительность

    func measure(_ frames: Int, _ body: () -> Void) -> (avg: Double, max: Double) {
        let clock = ContinuousClock()
        var total = 0.0, worst = 0.0
        for _ in 0..<frames {
            let d = clock.measure(body)
            let ms: Double = Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) * 1e-15
            total += ms
            worst = max(worst, ms)
        }
        return (total / Double(frames), worst)
    }

    /// Время `advance` за кадр 1/60 с (Debug): активный полёт ×1 и ×4, рельсы ×100 000.
    /// Пределы с большим запасом — ловят только регрессию на порядок.
    @Test func advanceFrameCost() {
        let sim = FlightSim(design: .orbit)
        sim.send(.setSAS(.hold))
        sim.setInput(ControlInput(throttle: 1))
        sim.send(.stage)
        let x1 = measure(300) { _ = sim.advance(realDelta: Self.frame) }
        sim.send(.setWarp(index: 3))
        let x4 = measure(300) { _ = sim.advance(realDelta: Self.frame) }
        #expect(sim.activeSituation == .flying)

        let o = circularOrbit(altitude: 100_000)
        let orb = FlightSim(design: .luna, body: .terra, position: o.position, velocity: o.velocity)
        orb.send(.setWarp(index: Self.maxWarp))
        let rails = measure(300) { _ = orb.advance(realDelta: Self.frame) }
        #expect(orb.warpIndex == Self.maxWarp)

        // Перелёт к Луне на ×100 000 — поиск входа в SOI.
        let r = Bodies.terra.radius + 78_000
        let s = circularOrbit(altitude: 78_000, phase: World.lunaInitialPhase - 110 * Double.pi / 180)
        let v1 = s.velocity + s.velocity.normalized * TrajectoryPredictor.hohmannLunaDeltaV(radius: r)
        let tr = FlightSim(design: .luna, body: .terra, position: s.position, velocity: v1)
        tr.send(.setWarp(index: Self.maxWarp))
        let transfer = measure(15) { _ = tr.advance(realDelta: Self.frame) }

        func f(_ x: Double) -> String { String(format: "%.3f", x) }
        print("advance, мс за кадр (среднее/макс): ×1 \(f(x1.avg))/\(f(x1.max)), ×4 \(f(x4.avg))/\(f(x4.max)), "
              + "рельсы ×100000 \(f(rails.avg))/\(f(rails.max)), перелёт \(f(transfer.avg))/\(f(transfer.max))")
        // Замер в Debug на Linux: ×1 ≈ 0.15 мс, ×4 ≈ 0.35 мс, рельсы ≈ 0.13 мс, перелёт ≈ 0.14 мс.
        #expect(x1.avg < 3, "×1: \(x1.avg) мс")
        #expect(x4.avg < 8, "×4: \(x4.avg) мс")
        #expect(rails.avg < 2, "рельсы: \(rails.avg) мс")
        #expect(transfer.avg < 3, "перелёт: \(transfer.avg) мс")
    }
}
