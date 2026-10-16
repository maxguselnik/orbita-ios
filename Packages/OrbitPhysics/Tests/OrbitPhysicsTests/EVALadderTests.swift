import Foundation
import Testing
@testable import OrbitPhysics

// Этап 6.2: лестница, поручни, корпус, выбор космонавта, погибшие, ЛК-2 (docs/CONTRACTS.md «EVA 6.2»).

@Suite("EVA 6.2: лестница, поручни, корпус")
struct EVALadderTests {
    /// Посадочная ступень «Луны» (что остаётся после отделения нижних ступеней).
    static let lunaLander = VesselDesign(name: "Луна · посадка",
                                         parts: [.chute, .podK1, .heatShield, .decoupler, .t800, .legs, .shtil])
    static let lk2Lander = VesselDesign(name: "ЛК-2 · посадка", parts: [.lk2, .t800, .legs, .shtil])
    static let noLegs = VesselDesign(name: "Без опор", parts: [.podK1, .t800, .shtil])
    static let lunaUp = Vec3(0.3, 0.9, 0.1).normalized

    private func landed(_ design: VesselDesign = lunaLander) -> FlightSim {
        let up = Self.lunaUp
        let ground = Bodies.luna.radius + Terrain.surfaceHeight(body: .luna, direction: up)
        let sim = FlightSim(design: design, body: .luna, position: up * (ground + 2), velocity: up * -0.5,
                            attitude: Quat.looking(nose: up, zHint: .unitZ))
        for _ in 0..<600 where sim.activeSituation != .landed { _ = sim.advance(realDelta: 1.0 / 60) }
        return sim
    }

    private func orbit(_ design: VesselDesign = noLegs) -> FlightSim {
        let sv = circularOrbit(altitude: 30_000, body: Bodies.luna)
        return FlightSim(design: design, body: .luna, position: sv.position, velocity: sv.velocity)
    }

    private func exit(_ sim: FlightSim) {
        sim.send(.evaExit)
        _ = sim.advance(realDelta: 1.0 / 60)
    }

    private func controlled(_ sim: FlightSim) throws -> CosmonautState {
        try #require(sim.snapshot.controlled)
    }

    private func groundGap(_ c: CosmonautState) -> Double {
        let fixed = World.toBodyFixed(c.position.normalized, body: c.body, time: 0)
        return c.position.length - Bodies.luna.radius - Terrain.surfaceHeight(body: c.body, direction: fixed)
    }

    private func world(_ v: VesselState, _ local: Vec3) -> Vec3 { v.position + v.attitude.rotate(local) }

    /// Спуститься по лестнице до грунта; события спуска.
    @discardableResult
    private func climbDown(_ sim: FlightSim) -> [SimEvent] {
        sim.setEVAInput(EVAInput(vertical: -1))
        let ev = run(sim, limit: 20) { s, _ in s.snapshot.controlled?.onGround ?? true }
        sim.setEVAInput(.neutral)
        return ev
    }

    // MARK: Лестница

    @Test func lunaLanderHasLadderUnderHatch() throws {
        let sim = landed()
        #expect(sim.activeSituation == .landed)
        let v = try #require(sim.snapshot.vessels.first)
        #expect(v.ladders.count == 1)
        let l = try #require(v.ladders.first)
        let h = v.hatches[l.hatch]
        #expect(abs(l.bottom.y) < 1e-9)
        #expect(abs(l.top.y - (h.y - Ship.hatchHalfHeight)) < 1e-9)
        // По центру под люком, снаружи корпуса (радиус 0.625 + отступ).
        #expect(abs(l.top.x - h.x) < 1e-9 && abs(l.bottom.x - h.x) < 1e-9)
        #expect(abs(l.top.z - l.bottom.z) < 1e-9)
        #expect(abs(l.top.z - (0.625 + EVABalance.ladderStandoff)) < 1e-9)
        #expect(l.top.z > h.z)
        // Без опор лестницы нет.
        #expect(Ship(design: Self.noLegs).ladders.isEmpty)
        #expect(Ship(design: .luna).ladders.count == 1)
    }

    @Test func exitHoldsLadderTopAndClimbsDownSafely() throws {
        let sim = landed()
        exit(sim)
        var c = try controlled(sim)
        let v = sim.snapshot.vessels[0]
        let l = try #require(v.ladders.first)
        let g = try #require(c.grip)
        #expect(g.vessel == v.id && g.hatch == l.hatch)
        #expect(abs((g.along ?? -1) - l.length) < 1e-9)
        #expect(!c.onGround && c.canBoard && !c.canGrip)
        let n = Vec3(0, 0, 1)
        #expect((c.position - world(v, l.top + n * EVABalance.ladderStandoff)).length < 1e-6)
        // Лицом к кораблю.
        #expect(c.attitude.rotate(-.unitZ).dot(v.attitude.rotate(-n)) > 0.99)
        #expect(c.fuel == EVABalance.jetpackFuel)

        let t0 = sim.time
        let ev = climbDown(sim)
        c = try controlled(sim)
        #expect(c.onGround && c.grip == nil && c.health == .ok)
        #expect(abs(groundGap(c)) < 1e-6)
        #expect(abs(sim.time - t0 - l.length / EVABalance.climbSpeed) < 0.3)
        #expect(!ev.contains { if case .evaInjured = $0 { true } else { false } })
        #expect(!ev.contains { if case .evaDied = $0 { true } else { false } })
        // Снизу лестницы, далеко от люка по 3D — войти нельзя.
        #expect((c.hatchDistance ?? 0) > EVABalance.boardRadius)
        #expect(!c.canBoard)
        sim.send(.evaBoard)
        #expect(sim.snapshot.cosmonauts.count == 1)
        #expect(sim.active.ship.parts.allSatisfy { $0.crew.isEmpty })
    }

    @Test func climbUpAndBoardFromLadderTop() throws {
        let sim = landed()
        exit(sim)
        climbDown(sim)
        sim.send(.evaCollectSample)
        var c = try controlled(sim)
        #expect(c.carried.count == 1)
        #expect(c.canGrip)
        sim.send(.evaGrab)
        c = try controlled(sim)
        let g = try #require(c.grip)
        #expect((g.along ?? -1) < 0.1)
        #expect(!c.canBoard)
        sim.send(.evaBoard)
        #expect(sim.snapshot.cosmonauts.count == 1)
        // Подъём: «Вверх» удерживается, пока не станет можно войти.
        let l = try #require(sim.snapshot.vessels[0].ladders.first)
        sim.setEVAInput(EVAInput(vertical: 1))
        _ = run(sim, limit: 20, frame: 1.0 / 60) { s, _ in s.snapshot.controlled?.canBoard ?? true }
        sim.setEVAInput(.neutral)
        c = try controlled(sim)
        #expect(c.canBoard)
        #expect((c.grip?.along ?? 0) >= l.length - EVABalance.ladderTopReach)
        sim.send(.evaBoard)
        let ev = sim.advance(realDelta: 1.0 / 60)
        #expect(ev.contains(.evaBoarded(memberID: "lera")))
        let pod = try #require(sim.active.ship.parts.first { $0.spec.crew > 0 })
        #expect(pod.crew == ["lera"] && pod.science.count == 1)
    }

    @Test func releaseOnLadderFallsToGround() throws {
        let sim = landed()
        exit(sim)
        sim.send(.evaRelease)
        var c = try controlled(sim)
        #expect(c.grip == nil && !c.onGround)
        _ = run(sim, limit: 10) { s, _ in s.snapshot.controlled?.onGround ?? true }
        c = try controlled(sim)
        // ~5 м на Луне — без травмы, рядом с кораблём.
        #expect(c.onGround && c.health == .ok)
    }

    // MARK: Поручни на орбите

    @Test func orbitExitHoldsHandrails() throws {
        let sim = orbit()
        exit(sim)
        var c = try controlled(sim)
        let g = try #require(c.grip)
        #expect(g.along == nil)
        #expect(c.canBoard)
        let d0 = try #require(c.hatchDistance)
        sim.setEVAInput(EVAInput(move: Vec3(1, 0, 0), vertical: 1))
        _ = run(sim, limit: 120)
        c = try controlled(sim)
        #expect(c.grip == g)
        let d1 = try #require(c.hatchDistance)
        #expect(d1 - d0 <= 0.5)
        #expect(c.fuel == EVABalance.jetpackFuel && c.jetpackFiring == .zero)
        // Скорость — скорость точки корабля.
        let v = sim.snapshot.vessels[0]
        let vp = v.velocity + v.angularVelocity.cross(c.position - v.position)
        #expect((c.velocity - vp).length < 1e-6)
    }

    @Test func releaseOnOrbitKeepsShipVelocity() throws {
        let sim = orbit()
        exit(sim)
        sim.send(.evaRelease)
        let c = try controlled(sim)
        #expect(c.grip == nil && c.canGrip)
        let v = sim.snapshot.vessels[0]
        let vp = v.velocity + v.angularVelocity.cross(c.position - v.position)
        #expect((c.velocity - vp).length < 1e-6)
        #expect(c.jetpackOn && c.fuel == EVABalance.jetpackFuel)
    }

    /// Поставить свободного космонавта так, чтобы его центр был в `d` м от люка по нормали люка.
    private func placeOffHatch(_ sim: FlightSim, _ d: Double) {
        let v = sim.snapshot.vessels[0]
        let hatch = world(v, v.hatches[0])
        let n = v.attitude.rotate(.unitZ)
        let center = hatch + n * d
        sim.cosmonauts[0].r = center - center.normalized * EVABalance.centerHeight
        sim.cosmonauts[0].v = v.velocity
    }

    @Test func grabWithinGripRadiusOnly() throws {
        let sim = orbit()
        exit(sim)
        sim.send(.evaRelease)
        placeOffHatch(sim, 3)
        sim.send(.evaSelect(memberID: "lera"))
        #expect(try !controlled(sim).canGrip)
        sim.send(.evaGrab)
        #expect(try controlled(sim).grip == nil)
        placeOffHatch(sim, 1.5)
        sim.send(.evaSelect(memberID: "lera"))
        #expect(try controlled(sim).canGrip)
        sim.send(.evaGrab)
        let c = try controlled(sim)
        #expect(c.grip == EVAGrip(vessel: sim.snapshot.vessels[0].id, hatch: 0, along: nil))
        #expect((c.hatchDistance ?? 9) < 1.5)
    }

    // MARK: Корпус

    @Test func jetpackIntoHullDoesNotPenetrate() throws {
        let sim = orbit()
        exit(sim)
        sim.send(.evaRelease)
        let v = sim.snapshot.vessels[0]
        let tank = v.layout[1]
        // Центр — в 3 м от оси на середине бака, ранец толкает к оси.
        let n = v.attitude.rotate(.unitZ)
        let center = world(v, Vec3(0, tank.center.y, 3))
        sim.cosmonauts[0].r = center - center.normalized * EVABalance.centerHeight
        sim.cosmonauts[0].v = v.velocity
        sim.setEVAInput(EVAInput(move: -n))
        var minRho = Double.infinity
        _ = run(sim, limit: 8, frame: 1.0 / 30) { s, _ in
            guard let c = s.snapshot.controlled else { return true }
            let vs = s.snapshot.vessels[0]
            // Точки тела: низ, центр, голова (по местной вертикали).
            let br = EVABalance.bodyRadius
            for hgt in [br, EVABalance.centerHeight, 2 * EVABalance.centerHeight - br] {
                let local = vs.attitude.conjugate.rotate(c.position + c.position.normalized * hgt - vs.position)
                if abs(local.y - tank.center.y) < tank.height / 2 {
                    minRho = min(minRho, Vec3(local.x, 0, local.z).length)
                }
            }
            return false
        }
        #expect(minRho >= tank.diameter / 2 + EVABalance.bodyRadius - 1e-6)
        #expect(minRho < tank.diameter / 2 + EVABalance.bodyRadius + 0.05)
        // Скорость внутрь гасится: относительно корабля не растёт к оси.
        let c = try controlled(sim)
        let rel = c.velocity - sim.snapshot.vessels[0].velocity
        #expect(rel.dot(n) > -0.05)
    }

    // MARK: Выбор, погибшие

    @Test func selectCosmonautOrShip() throws {
        let sim = landed(Self.lk2Lander)
        #expect(sim.active.ship.parts[0].crew.count == 2)
        exit(sim)
        exit(sim)
        #expect(sim.snapshot.cosmonauts.map(\.memberID) == ["lera", "anton"])
        #expect(sim.snapshot.controlledCosmonaut == "anton")
        sim.send(.evaSelect(memberID: nil))
        #expect(sim.snapshot.controlledCosmonaut == nil)
        sim.send(.evaSelect(memberID: "lera"))
        #expect(sim.snapshot.controlledCosmonaut == "lera")
        sim.send(.evaSelect(memberID: "mira"))
        #expect(sim.snapshot.controlledCosmonaut == "lera")
    }

    @Test func deathGoesToDeadCrew() throws {
        let sim = FlightSim(design: .jump)
        exit(sim)
        let up = sim.cosmonauts[0].r.normalized
        sim.cosmonauts[0].r += up * 20
        sim.cosmonauts[0].v = World.surfaceVelocity(body: .terra, position: sim.cosmonauts[0].r)
        sim.cosmonauts[0].onGround = false
        let cp = sim.checkpoint()
        _ = run(sim, limit: 5) { s, _ in s.snapshot.cosmonauts.isEmpty }
        #expect(sim.snapshot.deadCrew == ["lera"])
        sim.restore(cp)
        #expect(sim.snapshot.deadCrew.isEmpty)
        _ = run(sim, limit: 5) { s, _ in s.snapshot.cosmonauts.isEmpty }
        let after = sim.checkpoint()
        sim.restore(after)
        #expect(sim.snapshot.deadCrew == ["lera"])
    }

    @Test func checkpointKeepsGrip() throws {
        let sim = landed()
        exit(sim)
        let cp = sim.checkpoint()
        let before = try controlled(sim)
        climbDown(sim)
        sim.restore(cp)
        let after = try controlled(sim)
        #expect(after.grip == before.grip && after.position == before.position)
    }

    // MARK: ЛК-2 и «Луна-2»

    @Test func lk2CabinAndLuna2Preset() throws {
        let s = PartCatalog.spec(.lk2)
        #expect(s.kind == .pod && s.crew == 2)
        #expect(s.height == 1.4 && s.diameter == 1.25)
        #expect(abs(s.wetMass - 1_300) < 1e-6)
        #expect(TechTree.nodes.first { $0.parts.contains(.lk2) }?.id == .crew)
        // Люк — на 35 % высоты кабины.
        let ship = Ship(design: Self.lk2Lander)
        let pod = try #require(ship.parts.first { $0.id == .lk2 })
        let h = try #require(ship.hatches.first)
        #expect(abs(h.point.y - (pod.placement.bottom + 0.35 * 1.4)) < 1e-9)
        #expect(abs(h.point.z - 0.625) < 1e-9)

        let d = VesselDesign.luna2
        #expect(d.name == "Луна-2")
        #expect(VesselDesign.presets.contains(d))
        var expected = VesselDesign.luna.parts
        expected[1] = .lk2
        #expect(d.parts == expected)
        #expect(!d.issues().contains { $0.isBlocking }, "\(d.issues())")
        let sim = FlightSim(design: d)
        #expect(sim.active.ship.parts[1].crew.count == 2)
        #expect(sim.snapshot.vessels[0].ladders.count == 1)
    }

    @Test func lk2LanderLadderFromLowHatch() throws {
        let sim = landed(Self.lk2Lander)
        #expect(sim.activeSituation == .landed)
        exit(sim)
        let v = sim.snapshot.vessels[0]
        let l = try #require(v.ladders.first)
        #expect(abs(l.top.y - (v.hatches[0].y - Ship.hatchHalfHeight)) < 1e-9)
        #expect(try controlled(sim).grip?.along == l.length)
        climbDown(sim)
        let c = try controlled(sim)
        #expect(c.onGround && c.health == .ok)
    }
}
