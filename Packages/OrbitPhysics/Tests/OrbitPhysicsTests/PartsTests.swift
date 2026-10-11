import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Детали и ступени")
struct PartsTests {
    @Test func catalogMatchesSpec() {
        #expect(PartID.podK1.spec.dryMass == 840)
        #expect(PartID.t800.spec.fuelMass == 4_000)
        #expect(PartID.j64.spec.wetMass == 36_000)
        #expect(PartID.titan.spec.thrustVacuum == 1_630_000)
        #expect(PartID.molot.spec.isSolid && PartID.molot.spec.fuelMass == 2_810)
        // Тяга у земли ∝ Isp.
        let v = PartID.vikhr.spec
        #expect(abs(v.thrust(pressure: 1) - 215_000 * 250 / 320) < 1e-6)
        #expect(abs(v.thrust(pressure: 0) - 215_000) < 1e-6)
        #expect(PartCatalog.all.count == PartID.allCases.count)
    }

    @Test func presetsStrictlyBySpec() {
        #expect(VesselDesign.jump.parts == [.chute, .podK1, .decoupler, .molot])
        #expect(VesselDesign.orbit.parts == [.chute, .podK1, .decoupler, .t400, .shtil, .decoupler, .t800, .t800, .vikhr])
        #expect(VesselDesign.luna.parts == [.chute, .podK1, .t800, .legs, .shtil, .decoupler, .t800, .t800, .vikhr,
                                            .decouplerXL, .j64, .titan])
        #expect(abs(VesselDesign.luna.mass - 58_840) < 1e-6)
    }

    @Test func lunaPresetDeltaVBudget() {
        let st = VesselDesign.luna.stageInfos()
        #expect(st.count == 3)
        // [0] — «Титан» у земли.
        #expect(st[0].twr > 2 && st[0].twr < 3)
        #expect(st[0].twrVacuum > st[0].twr)
        #expect(abs(st[0].deltaV - 2_194) < 10)
        #expect(abs(st[1].deltaV - 2_056) < 10)
        #expect(abs(st[2].deltaV - 3_618) < 10)
        let total = st.reduce(0) { $0 + $1.deltaV }
        // Бюджет: орбита ≈ 3 400, перелёт ≈ 860, захват у Луны ≈ 280, посадка ≈ 600, взлёт ≈ 600,
        // возврат ≈ 300 (торможение — атмосферой и парашютом).
        let needLunar = 280.0 + 600 + 600 + 300
        #expect(total > 3_400 + 860 + needLunar)
        #expect(st[2].deltaV > needLunar + 1_000)  // верхняя ступень покрывает всё у Луны с запасом
        // Посадочная ступень на Луне: TWR > 3.
        let upper = VesselDesign(name: "", parts: Array(VesselDesign.luna.parts.prefix(5)))
        #expect((upper.stageInfos(pressure: 0, gravity: Bodies.luna.surfaceGravity).first?.twr ?? 0) > 3)
        #expect(st.allSatisfy { !$0.hasSolid && $0.fuelFraction == 1 })
    }

    @Test func orbitAndJumpPresets() {
        let o = VesselDesign.orbit.stageInfos()
        #expect(o.count == 3)
        #expect(o[0].twr > 1.15)
        #expect(o[0].deltaV + o[1].deltaV > 4_000)
        #expect(o[2].deltaV == 0 && o[2].twr == 0)
        let j = VesselDesign.jump.stageInfos()
        #expect(j[0].hasSolid && j[0].twr > 3)
        #expect(abs(j[0].burnTime - 2_810 / PartID.molot.spec.massFlow) < 1e-6)
    }

    @Test func enginesUseOnlyOwnSection() {
        var ship = Ship(design: .orbit)
        for i in ship.bottomSection where ship.parts[i].spec.kind == .engine { ship.parts[i].ignited = true }
        let upperFuel = ship.parts[3].fuel
        for _ in 0..<10_000 { _ = ship.burn(throttle: 1, pressure: 0, dt: 0.02) }
        #expect(ship.parts[3].fuel == upperFuel)
        #expect(ship.liquidFuel(in: ship.bottomSection) == 0)
        #expect(!ship.ignitedEnginesHaveFuel().any)
        #expect(ship.crashTolerance == 6)
        #expect(Ship(design: VesselDesign(name: "", parts: [.chute, .podK1])).crashTolerance == 9)
        #expect(Ship(design: .luna).crashTolerance == 12)
    }
}
