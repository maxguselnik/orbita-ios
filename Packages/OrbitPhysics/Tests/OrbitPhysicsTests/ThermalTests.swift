import Foundation
import Testing
@testable import OrbitPhysics

/// Состояние на радиусе `r0` (спуск к перицентру) для орбиты с апоцентром `ra` и перицентром `rp`, м.
func entryState(ra: Double, rp: Double, r0: Double) -> StateVector {
    let mu = Bodies.terra.mu
    let energy = -mu / (ra + rp)
    let vp = (2 * (energy + mu / rp)).squareRoot()
    let h = rp * vp
    let v0 = (2 * (energy + mu / r0)).squareRoot()
    let vt = h / r0
    let vr = -max(0, v0 * v0 - vt * vt).squareRoot()
    return StateVector(position: Vec3(r0, 0, 0), velocity: Vec3(vr, vt, 0))
}

/// Итог спуска: максимум нагрева, события, финал.
struct EntryResult {
    var maxHeat = 0.0
    var hottestPart: PartID?
    var events: [SimEvent] = []
    var situation: VesselSituation = .flying
    var ablatorLeft = 0.0
    var ablatorCapacity = 0.0
    var shieldFaced = false
    var podHeat = 0.0
}

/// Спуск `design` с состояния `s`: SAS по `sas`, нос — против скорости (или по ней), парашют взведён.
func fly(_ design: VesselDesign, _ s: StateVector, sas: SASMode = .retrograde, noseForward: Bool = false,
         untilLanded: Bool = false) -> EntryResult {
    let att = Quat.looking(nose: noseForward ? s.velocity : -s.velocity, zHint: s.position)
    let sim = FlightSim(design: design, body: .terra, position: s.position, velocity: s.velocity, attitude: att)
    sim.send(.setSAS(sas))
    sim.send(.deployChute)
    var r = EntryResult()
    var t = 0.0
    var inside = false
    while t < 3_000 {
        let ev = sim.advance(realDelta: 0.1)
        t += 0.1
        r.events += ev
        let th = sim.snapshot.telemetry.thermal
        if th.hottest > r.maxHeat { r.maxHeat = th.hottest; r.hottestPart = th.hottestPart }
        if th.shieldFacingFlow { r.shieldFaced = true }
        if let v = sim.snapshot.vessels.first(where: { $0.isActive }), let k = v.parts.firstIndex(of: .podK1),
           k < v.partHeat.count {
            r.podHeat = max(r.podHeat, v.partHeat[k])
        }
        let sit = sim.activeSituation
        if sit == .landed || sit == .splashed || sit == .crashed { break }
        // Только первый проход атмосферы, если не нужна посадка: ниже 25 км нагрев уже позади.
        let alt = sim.snapshot.telemetry.altitude
        if alt < 69_000 { inside = true }
        if !untilLanded && inside && (alt < 25_000 || alt > 70_000) { break }
    }
    r.situation = sim.activeSituation
    r.ablatorLeft = sim.snapshot.telemetry.thermal.ablator
    r.ablatorCapacity = sim.snapshot.telemetry.thermal.ablatorCapacity
    return r
}

let terraR = Bodies.terra.radius
/// Спуск с низкой орбиты: апоцентр 80 км, перицентр 30 км.
let leoEntry = entryState(ra: terraR + 80_000, rp: terraR + 30_000, r0: terraR + 79_000)
/// Возврат от Луны: апоцентр на орбите Луны, перицентр 35 км (вход ≈ 3.2 км/с).
let lunarEntry = entryState(ra: Bodies.luna.orbitRadius, rp: terraR + 35_000, r0: terraR + 79_000)

@Suite("Нагрев при входе")
struct ThermalTests {
    func destroyed(_ r: EntryResult) -> [PartID] {
        r.events.compactMap { if case .partDestroyed(let p) = $0 { return p }; return nil }
    }

    @Test func lowOrbitEntryWithoutShieldSurvivesHot() {
        // (а) К-1 с парашютом, спуск с 80 км (перицентр 30 км): горячо, но цела, садится.
        let r = fly(stack2([.chute, .podK1]), leoEntry, untilLanded: true)
        print("Нагрев: спуск с НОО — v0 \(Int(leoEntry.velocity.length)) м/с, макс. \(r.maxHeat) (\(String(describing: r.hottestPart)))")
        #expect(destroyed(r).isEmpty)
        #expect(r.situation == .landed || r.situation == .splashed, "\(r.situation)")
        #expect(r.maxHeat > 0.6 && r.maxHeat < 0.95, "нагрев \(r.maxHeat)")
        #expect(r.hottestPart == .podK1)
    }

    @Test func lunarReturnWithoutShieldBurnsCapsule() {
        // (б) Возврат от Луны (≈ 3.1 км/с у входа, перицентр 35 км): капсула без экрана сгорает — авария.
        let r = fly(stack2([.chute, .podK1]), lunarEntry)
        #expect(destroyed(r).contains(.podK1))
        #expect(r.situation == .crashed)
        #expect(r.events.contains { if case .crash = $0 { return true }; return false })
    }

    @Test func lunarReturnWithShieldSurvives() {
        // (в) То же с Э-1 под капсулой, щитом вперёд: цела, покрытие израсходовано частично.
        let r = fly(stack2([.chute, .podK1, .heatShield]), lunarEntry)
        print("Нагрев: возврат с Э-1 — v0 \(Int(lunarEntry.velocity.length)) м/с, капсула \(r.podHeat), макс. \(r.maxHeat) (\(String(describing: r.hottestPart))), покрытие \(r.ablatorLeft)/\(r.ablatorCapacity)")
        #expect(destroyed(r).isEmpty)
        #expect(r.situation != .crashed)
        #expect(r.shieldFaced)
        #expect(r.podHeat < 0.5, "капсула \(r.podHeat)")
        #expect(r.ablatorCapacity == PartID.heatShield.spec.fuelMass)
        #expect(r.ablatorLeft > 0 && r.ablatorLeft < r.ablatorCapacity * 0.98, "покрытие \(r.ablatorLeft)")
    }

    @Test func shieldNotFacingFlowDoesNotHelp() {
        // (г) Нос к потоку: экран заслонён капсулой, покрытие не тратится, капсула греется как без экрана.
        let flux = 2e7
        func heat(_ parts: [PartID], flow: Vec3) -> (pod: Double, ablator: Double, facing: Bool) {
            var ship = Ship(design: stack2(parts))
            var facing = false
            for _ in 0..<1_500 { facing = ship.thermalStep(flow: flow, flux: flux, dt: 0.02).shieldFacing || facing }
            let k = ship.parts.firstIndex { $0.id == .podK1 }!
            return (ship.parts[k].temperature, ship.ablator.mass, facing)
        }
        let noseFirst = heat([.chute, .podK1, .heatShield], flow: Vec3(0, 1, 0))
        let bare = heat([.chute, .podK1], flow: Vec3(0, 1, 0))
        let shieldFirst = heat([.chute, .podK1, .heatShield], flow: Vec3(0, -1, 0))
        #expect(!noseFirst.facing && noseFirst.ablator == PartID.heatShield.spec.fuelMass)
        #expect(abs(noseFirst.pod - bare.pod) / bare.pod < 0.05)
        #expect(shieldFirst.facing && shieldFirst.ablator < PartID.heatShield.spec.fuelMass)
        #expect(shieldFirst.pod < noseFirst.pod - 300)
        // Экран внизу стека — устойчивость щитом вперёд; без покрытия предел — 2000 К.
        #expect(Ship(design: stack2([.chute, .podK1, .heatShield])).retroStable)
        var spent = Ship(design: stack2([.podK1, .heatShield]))
        #expect(spent.temperatureLimit(1) == 3300)
        spent.parts[1].fuel = 0
        #expect(spent.temperatureLimit(1) == 2000)
    }

    @Test func telemetryAndBreakOff() {
        // (д) partHeat и thermal заполнены; перегретая деталь отрывается обломком с поддеревом.
        let s = lunarEntry
        let sim = FlightSim(design: stack2([.chute, .podK1, .heatShield]), body: .terra, position: s.position,
                            velocity: s.velocity, attitude: Quat.looking(nose: -s.velocity, zHint: s.position))
        sim.send(.setSAS(.retrograde))
        let v0 = sim.snapshot.vessels[0]
        #expect(v0.partHeat.count == 3 && v0.partHeat.allSatisfy { $0 > 0 && $0 < 0.3 })
        #expect(sim.snapshot.telemetry.thermal.ablatorCapacity == 200)
        run(sim, limit: 400) { s, _ in s.snapshot.telemetry.thermal.hottest > 0.3 }
        let t = sim.snapshot.telemetry.thermal
        #expect(t.hottest > 0.3 && t.hottestPart != nil && t.shieldFacingFlow)
        #expect(t.ablator < t.ablatorCapacity)
        // Разрушение некомандной детали: Т-200 под капсулой перегрет — он исчезает, «Штиль» под ним — обломок.
        var ship = Ship(design: stack2([.chute, .podK1, .t200, .shtil]))
        ship.parts[2].temperature = 5_000
        let res = ship.destroy(ship.parts[2].uid)
        #expect(ship.parts.map(\.id) == [.chute, .podK1])
        #expect(res.pieces.count == 1 && res.pieces[0].debris.parts.map(\.id) == [.shtil])
        #expect(abs(ship.parts.map(\.placement.bottom).min()!) < 1e-12)
        #expect(res.shift.y > 0)
    }
}

func stack2(_ p: [PartID]) -> VesselDesign { VesselDesign(name: "t", parts: p) }
