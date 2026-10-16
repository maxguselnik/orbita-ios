import Foundation
import Testing
@testable import OrbitPhysics

// Этап 6, часть 1: EVA (docs/CONTRACTS.md «EVA»).

@Suite("EVA: выход, движение, наука, флаг")
struct EVATests {
    static let lander = VesselDesign(name: "Лунник", parts: [.podK1, .t800, .legs, .shtil])
    static let lunaUp = Vec3(0.3, 0.9, 0.1).normalized

    /// Посадочный корабль на грунте Луны (Луна не вращается: система тела = инерциальная).
    func landedOnLuna(_ design: VesselDesign = lander) -> FlightSim {
        let up = Self.lunaUp
        let ground = Bodies.luna.radius + Terrain.surfaceHeight(body: .luna, direction: up)
        let sim = FlightSim(design: design, body: .luna, position: up * (ground + 2), velocity: up * -0.5,
                            attitude: Quat.looking(nose: up, zHint: .unitZ))
        for _ in 0..<600 where sim.activeSituation != .landed { _ = sim.advance(realDelta: 1.0 / 60) }
        return sim
    }

    /// Посадочный корабль без опор (без лестницы): правила выхода/входа части 1.
    static let noLegs = VesselDesign(name: "Без опор", parts: [.podK1, .t800, .shtil])

    /// Выйти на лестницу и спуститься на грунт (6.2).
    private func exitToGround(_ sim: FlightSim) {
        exit(sim)
        sim.setEVAInput(EVAInput(vertical: -1))
        _ = run(sim, limit: 20) { s, _ in s.snapshot.controlled?.onGround ?? true }
        sim.setEVAInput(.neutral)
    }

    private func lunaOrbit() -> FlightSim {
        let sv = circularOrbit(altitude: 30_000, body: Bodies.luna)
        return FlightSim(design: Self.lander, body: .luna, position: sv.position, velocity: sv.velocity)
    }

    /// Выйти и вернуть события выхода.
    @discardableResult
    private func exit(_ sim: FlightSim) -> [SimEvent] {
        sim.send(.evaExit)
        return sim.advance(realDelta: 1.0 / 60)
    }

    private func controlled(_ sim: FlightSim) throws -> CosmonautState {
        try #require(sim.snapshot.controlled)
    }

    private func groundGap(_ c: CosmonautState) -> Double {
        let b = Bodies.body(c.body)
        let fixed = World.toBodyFixed(c.position.normalized, body: c.body, time: 0)
        return c.position.length - b.radius - Terrain.surfaceHeight(body: c.body, direction: fixed)
    }

    @Test func hatchesInVesselState() throws {
        let sim = landedOnLuna()
        let v = try #require(sim.snapshot.vessels.first)
        #expect(v.hatches.count == 1)
        let h = try #require(v.hatches.first)
        #expect(h.z > 0.3 && h.z < 0.63)
        #expect(abs(h.x) < 1e-9)
    }

    /// Корабль без опор — лестницы нет, выход на грунт под люком (правило части 1).
    @Test func exitWithoutLadderStandsNearHatch() throws {
        let sim = landedOnLuna(Self.noLegs)
        #expect(sim.snapshot.vessels[0].ladders.isEmpty)
        #expect(sim.activeSituation == .landed)
        #expect(sim.snapshot.evaExitBlocker == nil)
        #expect(sim.snapshot.telemetry.science.crewAboard)
        let ev = exit(sim)
        #expect(ev.contains(.evaExited(memberID: "lera")))
        let c = try controlled(sim)
        #expect(c.name == "Лера" && c.body == .luna)
        #expect(c.onGround && !c.jetpackOn)
        #expect(abs(groundGap(c)) < 1e-6)
        let d = try #require(c.hatchDistance)
        #expect(abs(d - EVABalance.exitGroundOffset) < 0.05)
        #expect(c.canBoard)
        #expect(c.situation == .landed)
        #expect(!sim.snapshot.telemetry.science.crewAboard)
        #expect(sim.active.ship.parts.allSatisfy { $0.crew.isEmpty })
        #expect(sim.snapshot.evaExitBlocker == .noCrew)
    }

    @Test func exitBlockedInAtmosphereAndUnderThrust() {
        let r = Bodies.terra.radius + 5_000
        let air = FlightSim(design: .jump, body: .terra, position: Vec3(r, 0, 0), velocity: Vec3(0, 300, 0))
        #expect(air.snapshot.evaExitBlocker == .inAtmosphere)
        air.send(.evaExit)
        #expect(air.snapshot.cosmonauts.isEmpty && air.snapshot.controlledCosmonaut == nil)

        let burn = lunaOrbit()
        #expect(burn.snapshot.evaExitBlocker == nil)
        burn.send(.stage)
        burn.setInput(ControlInput(throttle: 1))
        #expect(burn.evaExitBlocker() == .thrusting)
        burn.send(.evaExit)
        #expect(burn.snapshot.cosmonauts.isEmpty)
    }

    @Test func walkOnLunaKeepsToGround() throws {
        let sim = landedOnLuna()
        exitToGround(sim)
        let east = Self.lunaUp.cross(.unitZ).normalized
        sim.setEVAInput(EVAInput(move: east))
        let start = try controlled(sim).position
        _ = run(sim, limit: 5)
        let c = try controlled(sim)
        #expect(c.onGround)
        #expect(abs(c.surfaceSpeed - EVABalance.walkSpeed) < 0.02)
        #expect(abs(groundGap(c)) < 1e-6)
        let walked = (c.position - start).length
        #expect(walked > 7.5 && walked < 9.2)
        // Лицо (−Z) — по направлению шага, +Y — по вертикали.
        #expect(c.attitude.rotate(-.unitZ).dot(east) > 0.95)
        #expect(c.attitude.rotate(.unitY).dot(c.position.normalized) > 0.999)
        // Отпустил — останавливается.
        sim.setEVAInput(.neutral)
        _ = run(sim, limit: 2)
        #expect(try controlled(sim).surfaceSpeed < 1e-6)
    }

    @Test func jumpOnLunaLandsSafely() throws {
        let sim = landedOnLuna()
        exitToGround(sim)
        sim.send(.evaJump)
        var peak = 0.0
        var all: [SimEvent] = []
        all += run(sim, limit: 6) { s, _ in
            peak = max(peak, s.snapshot.controlled?.heightAboveTerrain ?? 0)
            return s.snapshot.controlled?.onGround ?? true
        }
        let c = try controlled(sim)
        #expect(c.onGround && c.health == .ok)
        let g = Bodies.luna.mu / pow(Bodies.luna.radius, 2)
        #expect(abs(peak - EVABalance.jumpSpeed * EVABalance.jumpSpeed / (2 * g)) < 0.25)
        #expect(all.contains { if case .evaLanded = $0 { true } else { false } })
        #expect(!all.contains { if case .evaInjured = $0 { true } else { false } })
    }

    /// Космонавт на площадке Терры, поднятый на `height` м над грунтом.
    private func dropOnTerra(_ height: Double) -> FlightSim {
        let sim = FlightSim(design: .jump)
        exit(sim)
        let up = sim.cosmonauts[0].r.normalized
        sim.cosmonauts[0].r += up * height
        sim.cosmonauts[0].v = World.surfaceVelocity(body: .terra, position: sim.cosmonauts[0].r)
        sim.cosmonauts[0].onGround = false
        return sim
    }

    @Test func fallOnTerraKills() {
        let sim = dropOnTerra(20)
        let all = run(sim, limit: 5) { s, _ in s.snapshot.cosmonauts.isEmpty }
        let speed = all.compactMap { if case .evaDied(_, let v) = $0 { v } else { nil } }.first
        #expect(speed.map { $0 >= EVABalance.deathSpeed } ?? false)
        #expect(sim.snapshot.cosmonauts.isEmpty && sim.snapshot.controlledCosmonaut == nil)
        // Член экипажа не вернулся.
        #expect(!sim.snapshot.telemetry.science.crewAboard)
    }

    @Test func fallOnTerraInjures() throws {
        let sim = dropOnTerra(8)
        let all = run(sim, limit: 5) { s, _ in s.snapshot.controlled?.onGround ?? true }
        let speed = all.compactMap { if case .evaInjured(_, let v) = $0 { v } else { nil } }.first
        let v = try #require(speed)
        #expect(v >= EVABalance.injurySpeed && v < EVABalance.deathSpeed)
        let c = try controlled(sim)
        #expect(c.health == .injured)
        #expect(c.situation == .launchPad)
        // Травмированный не прыгает и ходит медленнее.
        sim.send(.evaJump)
        #expect(try controlled(sim).onGround)
        let up = c.position.normalized
        // От корабля (корпус не пускает внутрь — 6.2).
        sim.setEVAInput(EVAInput(move: Cosmonaut.horizontal(c.position - sim.snapshot.vessels[0].position, up: up)))
        _ = run(sim, limit: 3)
        #expect(abs(try controlled(sim).surfaceSpeed - EVABalance.injuredWalkSpeed) < 0.02)
    }

    @Test func jetpackBurnsFuelUntilEmpty() throws {
        let sim = lunaOrbit()
        exit(sim)
        #expect(try controlled(sim).grip != nil)
        sim.send(.evaRelease)
        var c = try controlled(sim)
        #expect(c.grip == nil)
        #expect(c.jetpackOn && !c.onGround && c.fuel == EVABalance.jetpackFuel)
        let v0 = c.velocity - sim.snapshot.vessels[0].velocity
        sim.setEVAInput(EVAInput(move: Vec3(1, 0, 0)))
        let t0 = sim.time
        _ = run(sim, limit: 10)
        c = try controlled(sim)
        #expect(abs(c.fuel - (EVABalance.jetpackFuel - (sim.time - t0))) < 0.01)
        #expect(c.jetpackFiring.length > 0.99)
        var all = run(sim, limit: 20)
        c = try controlled(sim)
        #expect(c.fuel == 0 && c.fuelFraction == 0)
        #expect(c.jetpackFiring == .zero)
        all += run(sim, limit: 1)
        #expect(all.filter { $0 == .jetpackEmpty(memberID: "lera") }.count == 1)
        // Δv ранца = 2.5 × 24 = 60 м/с по +X относительно корабля (гравитация у обоих почти одна).
        let gained = (c.velocity - sim.snapshot.vessels[0].velocity - v0).dot(Vec3(1, 0, 0))
        #expect(abs(gained - EVABalance.jetpackAccel * EVABalance.jetpackFuel) < 1.5)
    }

    /// Отпустил поручни на орбите — дрейфует рядом с кораблём (скорость — скорость корабля).
    @Test func orbitCosmonautStaysNearShip() throws {
        let sim = lunaOrbit()
        exit(sim)
        sim.send(.evaRelease)
        // Расстояние от центра космонавта до люка.
        func gap() throws -> Double { try #require(try controlled(sim).hatchDistance) }
        let d0 = try gap()
        _ = run(sim, limit: 60)
        let d1 = try gap()
        #expect(d0 < 1.5)
        #expect(abs(d1 - d0) < 1)
        #expect(try controlled(sim).orbit != nil)
        #expect(try controlled(sim).situation == .nearSpace)
    }

    /// Без лестницы — вход с грунта по горизонтали (часть 1).
    @Test func boardWithinRadiusDeliversData() throws {
        let sim = landedOnLuna(Self.noLegs)
        exit(sim)
        sim.send(.evaReport)
        sim.send(.evaCollectSample)
        var ev = sim.advance(realDelta: 1.0 / 60)
        #expect(ev.contains(.evaScienceCollected(ScienceSubjectID(experiment: .surfaceSample, body: .luna, situation: .landed))))
        #expect(try controlled(sim).carried.count == 2)
        sim.send(.evaBoard)
        ev = sim.advance(realDelta: 1.0 / 60)
        #expect(ev.contains(.evaBoarded(memberID: "lera")))
        #expect(sim.snapshot.cosmonauts.isEmpty && sim.snapshot.controlledCosmonaut == nil)
        let pod = try #require(sim.active.ship.parts.first { $0.spec.crew > 0 })
        #expect(pod.crew == ["lera"])
        #expect(pod.science.count == 2)
        #expect(sim.snapshot.telemetry.science.crewAboard)
        #expect(sim.snapshot.telemetry.science.stored.count == 2)
        // Корабельные эксперименты без EVA.
        #expect(!sim.snapshot.telemetry.science.experiments.contains(.evaReport))
        #expect(sim.railsBlockReason() == nil)
    }

    @Test func boardTooFarIsRefused() throws {
        let sim = landedOnLuna()
        exitToGround(sim)
        let c0 = try controlled(sim)
        let up = c0.position.normalized
        let away = Cosmonaut.horizontal(c0.position - sim.snapshot.vessels[0].position, up: up)
        sim.setEVAInput(EVAInput(move: away))
        _ = run(sim, limit: 3)
        sim.setEVAInput(.neutral)
        let c = try controlled(sim)
        #expect((c.hatchDistance ?? 0) > EVABalance.boardRadius)
        #expect(!c.canBoard)
        sim.send(.evaBoard)
        #expect(sim.snapshot.cosmonauts.count == 1)
        #expect(sim.active.ship.parts.allSatisfy { $0.crew.isEmpty })
    }

    @Test func sampleOnlyOnGroundAndOnce() throws {
        let orbit = lunaOrbit()
        exit(orbit)
        var c = try controlled(orbit)
        #expect(c.sampleBlocker == .notOnGround && c.flagBlocker == .notOnGround)
        #expect(c.reportBlocker == nil)
        orbit.send(.evaCollectSample)
        orbit.send(.evaPlantFlag)
        #expect(try controlled(orbit).carried.isEmpty && orbit.snapshot.flags.isEmpty)
        orbit.send(.evaReport)
        c = try controlled(orbit)
        #expect(c.carried.map(\.subject.situation) == [.nearSpace])
        #expect(c.reportBlocker == .duplicate)

        let ground = landedOnLuna()
        exitToGround(ground)
        #expect(try controlled(ground).sampleBlocker == nil)
        ground.send(.evaCollectSample)
        ground.send(.evaCollectSample)
        c = try controlled(ground)
        #expect(c.carried.count == 1)
        #expect(c.sampleBlocker == .duplicate)
    }

    @Test func flagPlantedOnce() throws {
        let sim = landedOnLuna()
        exitToGround(sim)
        sim.send(.evaPlantFlag)
        let ev = sim.advance(realDelta: 1.0 / 60)
        #expect(ev.contains(.flagPlanted(body: .luna)))
        let f = try #require(sim.snapshot.flags.first)
        #expect(f.text == "Лера · Луна" && f.memberID == "lera" && f.body == .luna)
        let c = try controlled(sim)
        let base = World.fromBodyFixed(f.fixedPosition, body: .luna, time: sim.time)
        #expect(abs((base - c.position).length - 0.8) < 0.1)
        #expect(c.flagBlocker == .duplicate)
        sim.send(.evaPlantFlag)
        #expect(sim.snapshot.flags.count == 1)
    }

    @Test func railsBlockedWhileOutside() throws {
        let sim = landedOnLuna()
        sim.send(.setWarp(index: 2))
        #expect(sim.warpIndex == 2)
        exit(sim)
        #expect(sim.warpIndex == 0)
        #expect(sim.snapshot.telemetry.warpBlocked == .eva)
        sim.send(.setWarp(index: TimeWarp.levels.count - 1))
        #expect(sim.warpIndex == TimeWarp.physicalCount - 1)
        let t0 = sim.time
        let ev = sim.advance(realDelta: 0.1)
        #expect(ev.contains(.warpReset(.eva)))
        #expect(abs(sim.time - t0 - 0.1 * TimeWarp.levels[TimeWarp.physicalCount - 1]) < 1e-9)
    }

    @Test func switchCyclesShipAndCosmonaut() throws {
        let sim = landedOnLuna()
        exitToGround(sim)
        sim.send(.evaSwitch)
        #expect(sim.snapshot.controlledCosmonaut == nil && sim.snapshot.cosmonauts.count == 1)
        // Ввод без управляемого космонавта игнорируется.
        sim.setEVAInput(EVAInput(move: Self.lunaUp.cross(.unitZ).normalized))
        _ = run(sim, limit: 1)
        #expect(sim.snapshot.cosmonauts[0].surfaceSpeed < 1e-6)
        sim.send(.evaSwitch)
        #expect(sim.snapshot.controlledCosmonaut == "lera")
    }

    @Test func checkpointKeepsCosmonaut() throws {
        let sim = landedOnLuna()
        exitToGround(sim)
        sim.send(.evaPlantFlag)
        let cp = sim.checkpoint()
        let before = try controlled(sim)
        sim.setEVAInput(EVAInput(move: Self.lunaUp.cross(.unitZ).normalized))
        _ = run(sim, limit: 3)
        sim.send(.evaBoard)
        sim.restore(cp)
        let after = try controlled(sim)
        #expect(after.position == before.position && after.memberID == "lera")
        #expect(sim.snapshot.flags.count == 1)
        #expect(sim.active.ship.parts.allSatisfy { $0.crew.isEmpty })
    }
}
