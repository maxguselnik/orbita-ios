import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Типы топлива и газовая РСУ")
struct FuelTypesTests {
    func sim(_ design: VesselDesign, nose: Vec3? = nil) -> FlightSim {
        let s = circularOrbit(altitude: 100_000)
        let q = nose.map { Quat.looking(nose: $0, zHint: .unitZ) }
        return FlightSim(design: design, body: .terra, position: s.position, velocity: s.velocity, attitude: q)
    }

    /// Остаток топлива во всех деталях данного типа на активном корабле.
    func fuel(_ s: FlightSim, _ id: PartID) -> Double {
        s.active.ship.parts.filter { $0.spec.id == id }.reduce(0) { $0 + $1.fuel }
    }

    func burnEngines(_ s: FlightSim, seconds: Double) {
        s.setInput(ControlInput(throttle: 1))
        s.send(.stage)
        _ = run(s, limit: seconds, frame: 0.05)
        s.setInput(.neutral)
    }

    func rcsBurn(_ s: FlightSim, translation: Vec3 = Vec3(0, 1, 0), seconds: Double) {
        s.setInput(ControlInput(translation: translation))
        _ = run(s, limit: seconds, frame: 0.05)
        s.setInput(.neutral)
    }

    static let gasShip = VesselDesign(name: "", parts: [.probe, .n50, .gasJet])
    static let monoShip = VesselDesign(name: "", parts: [.probe, .m100, .rcsBlock])
    /// Тяжёлые варианты: угловая скорость не упирается в предел, видна добавка от сопел.
    static let heavyGas = VesselDesign(name: "", parts: [.probe, .t800, .t800, .n50, .gasJet])
    static let heavyMono = VesselDesign(name: "", parts: [.probe, .t800, .t800, .m100, .rcsBlock])

    // 1
    @Test func catalogFuelTypes() {
        for id in PartID.allCases {
            let s = id.spec
            let expected: FuelType?
            switch id {
            case .t100, .t200, .t400, .t800, .j64: expected = .kerolox
            case .mk200, .mk400: expected = .methalox
            case .molot: expected = .solid
            case .spolokh: expected = .methalox
            case .shtil, .vikhr, .titan: expected = .kerolox
            case .rcsBlock, .m100: expected = .mono
            case .gasJet, .n50: expected = .gas
            default: expected = nil
            }
            #expect(s.fuelType == expected, "\(id): \(String(describing: s.fuelType))")
        }
    }

    // 2
    @Test func methaneEngineOnKeroseneTanksDoesNotBurn() {
        let d = VesselDesign(name: "", parts: [.probe, .t400, .spolokh])
        #expect(d.issues().contains(.wrongFuel(stage: 0, fuel: .methalox)))
        let s = sim(d)
        let f0 = fuel(s, .t400)
        burnEngines(s, seconds: 3)
        #expect(s.snapshot.telemetry.thrust == 0)
        #expect(fuel(s, .t400) == f0)
    }

    @Test func methaneEngineBurnsMethaneTanks() {
        let d = VesselDesign(name: "", parts: [.probe, .mk400, .spolokh])
        #expect(!d.issues().contains { if case .wrongFuel = $0 { true } else { false } })
        let s = sim(d)
        let f0 = fuel(s, .mk400)
        burnEngines(s, seconds: 5)
        let used = f0 - fuel(s, .mk400)
        let expected = PartID.spolokh.spec.massFlow * 5
        #expect(abs(used - expected) / expected < 0.02, "\(used) vs \(expected)")
    }

    @Test func mixedSectionEachEngineBurnsOwnFuel() {
        let d = VesselDesign(name: "", parts: [.probe, .mk400, .t400, .spolokh, .vikhr])
        #expect(!d.issues().contains { if case .wrongFuel = $0 { true } else { false } })
        let s = sim(d)
        let m0 = fuel(s, .mk400), k0 = fuel(s, .t400)
        burnEngines(s, seconds: 5)
        let usedM = m0 - fuel(s, .mk400), usedK = k0 - fuel(s, .t400)
        let eM = PartID.spolokh.spec.massFlow * 5, eK = PartID.vikhr.spec.massFlow * 5
        #expect(abs(usedM - eM) / eM < 0.03, "метан \(usedM) vs \(eM)")
        #expect(abs(usedK - eK) / eK < 0.03, "керосин \(usedK) vs \(eK)")
    }

    // 3
    @Test func deltaVByFuelSingleType() {
        let d = VesselDesign(name: "", parts: [.probe, .t200, .shtil])
        let i = d.stageInfos(pressure: 0)[0]
        #expect(i.deltaVByFuel.count == 1)
        #expect(abs((i.deltaVByFuel[.kerolox] ?? -1) - i.deltaV) < 1e-6 * max(1, i.deltaV))
    }

    @Test func deltaVByFuelMixedSection() {
        let d = VesselDesign(name: "", parts: [.probe, .mk400, .t400, .spolokh, .vikhr])
        let i = d.stageInfos(pressure: 0)[0]
        #expect(i.deltaVByFuel.count == 2)
        let sum = i.deltaVByFuel.values.reduce(0, +)
        #expect(abs(sum - i.deltaV) <= 1e-6 * i.deltaV, "\(sum) vs \(i.deltaV)")
    }

    @Test func methaneStageDeltaVMatchesRocketEquation() {
        let d = VesselDesign(name: "", parts: [.probe, .mk400, .spolokh])
        let i = d.stageInfos(pressure: 0)[0]
        let m0 = d.mass, m1 = m0 - PartID.mk400.spec.fuelMass
        let expected = PartID.spolokh.spec.ispVacuum * standardGravity * log(m0 / m1)
        #expect(abs(i.deltaV - expected) / expected < 1e-3, "\(i.deltaV) vs \(expected)")
        #expect(i.deltaVByFuel.count == 1 && i.deltaVByFuel[.methalox] != nil)
    }

    // 4
    @Test func gasTranslationUsesOnlyNitrogen() {
        let s = sim(Self.gasShip)
        s.send(.setRCS(true))
        let t0 = s.snapshot.telemetry.rcs
        #expect(t0.available && t0.gasCapacity > 0)
        #expect(t0.monoCapacity == 0)
        let m0 = s.activeMass
        let nose = s.snapshot.vessels[0].attitude.nose
        let ref = sim(Self.gasShip)
        s.setInput(ControlInput(translation: Vec3(0, 1, 0)))
        _ = s.advance(realDelta: 0.05)
        #expect(s.snapshot.telemetry.rcs.firing)
        s.setInput(.neutral)
        let s2 = sim(Self.gasShip)
        s2.send(.setRCS(true))
        rcsBurn(s2, seconds: 3)
        _ = run(ref, limit: 3, frame: 0.05)
        let dv = (s2.activeStateVector.velocity - ref.activeStateVector.velocity).dot(nose)
        let spec = PartID.gasJet.spec
        let expected = spec.thrustVacuum / m0 * 3
        #expect(abs(dv - expected) / expected < 0.05, "dv \(dv) vs \(expected)")
        let r = s2.snapshot.telemetry.rcs
        let used = t0.gasMass - r.gasMass
        #expect(abs(used - spec.massFlow * 3) / (spec.massFlow * 3) < 0.05, "\(used)")
        #expect(r.monoMass == 0)
    }

    // 5
    @Test func gasRotationHelpsAndSpendsNitrogen() {
        func spin(rcs: Bool, _ d: VesselDesign) -> (w: Double, s: FlightSim) {
            let s = sim(d)
            s.send(.setRCS(rcs))
            s.setInput(ControlInput(pitch: 1))
            _ = run(s, limit: 2, frame: 0.05)
            return (s.snapshot.vessels[0].angularVelocity.length, s)
        }
        let on = spin(rcs: true, Self.heavyGas), off = spin(rcs: false, Self.heavyGas)
        #expect(on.w > off.w, "с РСУ \(on.w), без \(off.w)")
        let r = on.s.snapshot.telemetry.rcs
        #expect(r.gasMass < r.gasCapacity)
        // Бриз слабее Роя: добавка к угловой скорости меньше.
        let monoOn = spin(rcs: true, Self.heavyMono), monoOff = spin(rcs: false, Self.heavyMono)
        let gasGain = on.w - off.w, monoGain = monoOn.w - monoOff.w
        #expect(gasGain < monoGain, "Бриз \(gasGain), Рой \(monoGain)")
    }

    @Test func gasJetWeakerThanMonoTranslation() {
        func dv(_ d: VesselDesign) -> Double {
            let s = sim(d), ref = sim(d)
            s.send(.setRCS(true))
            let nose = s.snapshot.vessels[0].attitude.nose
            rcsBurn(s, seconds: 2)
            _ = run(ref, limit: 2, frame: 0.05)
            return (s.activeStateVector.velocity - ref.activeStateVector.velocity).dot(nose)
        }
        #expect(dv(Self.gasShip) < dv(Self.monoShip))
    }

    // 6
    @Test func typesDoNotMix() {
        let d = VesselDesign(name: "", parts: [.probe, .n50, .rcsBlock])
        #expect(d.issues().contains(.gasWithoutJets))
        let s = sim(d)
        s.send(.setRCS(true))
        let g0 = s.snapshot.telemetry.rcs.gasMass
        let mono0 = s.snapshot.telemetry.rcs.monoMass
        rcsBurn(s, seconds: 3)
        let r = s.snapshot.telemetry.rcs
        #expect(r.gasMass == g0)
        #expect(r.monoMass < mono0)

        let d2 = VesselDesign(name: "", parts: [.probe, .m100, .gasJet])
        #expect(d2.issues().contains(.monoWithoutRCS))
        let s2 = sim(d2)
        s2.send(.setRCS(true))
        let m0 = s2.snapshot.telemetry.rcs.monoMass
        rcsBurn(s2, seconds: 3)
        #expect(s2.snapshot.telemetry.rcs.monoMass == m0)
        #expect(s2.snapshot.telemetry.rcs.gasMass < s2.snapshot.telemetry.rcs.gasCapacity)
    }

    // 7
    @Test func rcsDeltaVByType() {
        let d = Self.gasShip
        let gas = PartID.n50.spec.fuelMass + PartID.gasJet.spec.fuelMass
        let m = d.mass
        let expected = PartID.gasJet.spec.ispVacuum * standardGravity * log(m / (m - gas))
        let dv = d.rcsDeltaV()
        #expect(PartID.gasJet.spec.ispVacuum == 65)
        #expect(abs((dv[.gas] ?? 0) - expected) / expected < 1e-3, "\(String(describing: dv[.gas])) vs \(expected)")
        #expect(dv[.mono] == nil)
        for p in VesselDesign.presets { #expect(p.rcsDeltaV().isEmpty, "\(p.name)") }
    }

    // 8
    @Test func techTree() {
        let gas = TechTree.node(.gasControl), control = TechTree.node(.control)
        #expect(gas.cost == 5)
        #expect(gas.column < control.column)
        #expect(control.parts.contains(.rcsBlock))
        #expect(TechTree.node(.methane).requires.contains(.heavy))
        for p in [PartID.gasJet, .n50, .mk200, .mk400, .spolokh] {
            #expect(TechTree.nodes.filter { $0.parts.contains(p) }.count == 1, "\(p)")
        }
    }

    // Ревью F: замечания P2.

    @Test func presetsHaveNoNewIssues() {
        for d in VesselDesign.presets {
            let issues = d.issues()
            #expect(!issues.contains { if case .wrongFuel = $0 { true } else { false } }, "\(d.name)")
            #expect(!issues.contains(.gasWithoutJets), "\(d.name)")
        }
    }

    @Test func rcsDeltaVKeepsDroppedRCSAndBurnsEngineFuel() {
        // РСУ под разделителем уходит с нижней ступенью — Δv РСУ всё равно показывается.
        let dropped = VesselDesign(name: "", parts: [.probe, .decoupler, .rcsBlock, .m100, .t400, .shtil])
        #expect((dropped.rcsDeltaV()[.mono] ?? 0) > 0)
        // Посадочник: Δv РСУ — после выработки баков двигателя (масса меньше, Δv больше, чем с полными).
        let lander = VesselDesign(name: "", parts: [.probe, .rcsBlock, .m100, .t200, .shtil])
        var ship = Ship(design: lander)
        let full = ship.rcsDeltaV(.mono)
        for k in ship.pendingStages { ship.simulateActivation(k) }
        _ = ship.simulateBurn(pressure: 0, gravity: Bodies.terra.surfaceGravity, dropped: [])
        let dry = ship.rcsDeltaV(.mono)
        let shown = lander.rcsDeltaV()[.mono] ?? 0
        #expect(dry > full * 1.5)
        #expect(abs(shown - dry) / dry < 1e-9)
    }

    @Test func twoTypesOneEmptyStillWorks() {
        // «Рой» без монотоплива + «Бриз» с азотом: сдвиг и поворот идут на азоте, доля «Роя» выпадает.
        let d = VesselDesign(name: "", parts: [.probe, .n50, .gasJet, .rcsBlock])
        let s = sim(d)
        let ai = s.activeIndex
        s.vessels[ai].ship.drawRCS(.mono, s.vessels[ai].ship.rcsMass(.mono))
        #expect(s.active.ship.rcsMass(.mono) < 1e-9)
        s.send(.setRCS(true))
        let gas0 = s.snapshot.telemetry.rcs.gasMass
        s.setInput(ControlInput(translation: Vec3(0, 1, 0)))
        _ = run(s, limit: 1, frame: 0.05)
        let cmd = s.active.rcsTranslation
        s.setInput(.neutral)
        #expect(s.snapshot.telemetry.rcs.gasMass < gas0)
        let jets = s.active.ship
        let share = jets.rcsJets(.gas).thrust / (jets.rcsJets(.gas).thrust + jets.rcsJets(.mono).thrust)
        #expect(abs(cmd.y - share) < 1e-6, "команда \(cmd.y), доля \(share)")
    }

    @Test func rcsFuelsListsOnlyFiringTypes() {
        // В снимке — только типы, чьи сопла реально работали: «Рой» без монотоплива молчит.
        let d = VesselDesign(name: "", parts: [.probe, .n50, .gasJet, .m100, .rcsBlock])
        let s = sim(d)
        s.send(.setRCS(true))
        func fuels(translation: Vec3 = .zero, pitch: Double = 0) -> Set<FuelType> {
            s.setInput(ControlInput(pitch: pitch, translation: translation))
            _ = run(s, limit: 0.2, frame: 0.05)
            return s.snapshot.vessels[s.activeIndex].rcsFuels
        }
        #expect(fuels(translation: Vec3(0, 1, 0)) == [.mono, .gas])
        #expect(fuels(pitch: 1) == [.mono, .gas])
        let ai = s.activeIndex
        s.vessels[ai].ship.drawRCS(.mono, s.vessels[ai].ship.rcsMass(.mono))
        #expect(fuels(translation: Vec3(0, 1, 0)) == [.gas])
        #expect(fuels(pitch: 1) == [.gas])
        s.send(.setRCS(false))
        #expect(fuels(translation: Vec3(0, 1, 0)).isEmpty)
        #expect(fuels().isEmpty)
    }
}
