import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Сборка и понятная телеметрия")
struct AssemblyTelemetryTests {
    @Test func buildFromNothingAndInsertAtEitherEnd() throws {
        var design = VesselAssembly.empty
        #expect(design.parts.isEmpty)
        #expect(design.issues().contains(.empty))
        #expect(VesselAssembly.insert(.podK1, into: &design.parts, at: 0) == 0)
        #expect(VesselAssembly.insert(.t400, into: &design.parts, at: 1) == 1)
        #expect(VesselAssembly.insert(.vikhr, into: &design.parts, at: 2) == 2)
        #expect(VesselAssembly.insert(.chute, into: &design.parts, at: 0) == 0)
        #expect(design.parts == [.chute, .podK1, .t400, .vikhr])
        #expect(!design.issues().contains(where: { $0.isBlocking }))
        #expect(design.stageInfos().first?.twr ?? 0 > 1)
        #expect(try JSONDecoder().decode(VesselDesign.self, from: JSONEncoder().encode(design)).parts == design.parts)
    }

    @Test func movingKeepsPartsAndStagingConsistent() {
        var parts: [PartID] = [.podK1, .decoupler, .t400, .vikhr, .chute]
        #expect(VesselAssembly.move(&parts, from: 4, to: 0) == 0)
        #expect(parts == [.chute, .podK1, .decoupler, .t400, .vikhr])
        #expect(VesselAssembly.move(&parts, from: 3, to: 4) == 3) // своё крепление — без изменения
        #expect(VesselAssembly.move(&parts, from: 2, to: 4) == 3)
        #expect(parts == [.chute, .podK1, .t400, .decoupler, .vikhr])
        #expect(VesselAssembly.move(&parts, from: 3, to: 2) == 2)
        #expect(VesselDesign(name: "", parts: parts).stageInfos().count == 2)
        let count = parts.count
        #expect(VesselAssembly.move(&parts, from: 0, to: count) == count - 1)
        #expect(parts.last == .chute && parts.count == count)
    }

    @Test func invalidDropsAndLimitLeaveProjectUntouched() {
        var parts: [PartID] = [.podK1]
        #expect(VesselAssembly.insert(.t400, into: &parts, at: -1) == nil)
        #expect(VesselAssembly.insert(.t400, into: &parts, at: 2) == nil)
        #expect(VesselAssembly.move(&parts, from: 1, to: 0) == nil)
        #expect(VesselAssembly.move(&parts, from: 0, to: 2) == nil)
        #expect(parts == [.podK1])
        parts = Array(repeating: .t100, count: VesselDesign.maxParts)
        #expect(VesselAssembly.insert(.podK1, into: &parts, at: 0) == nil)
        #expect(parts.count == VesselDesign.maxParts)
    }

    @Test func singleStageIgnitesBeforeOfferingChute() {
        let sim = FlightSim(design: VesselDesign(name: "Одна ступень", parts: [.chute, .podK1, .t400, .vikhr]))
        #expect(sim.snapshot.telemetry.nextStageAction == .ignite)
        sim.send(.stage)
        #expect(sim.snapshot.telemetry.nextStageAction == .armChute)
        #expect(sim.snapshot.telemetry.maxThrust > 0)
        sim.send(.stage)
        #expect(sim.snapshot.telemetry.chute == .armed)
        #expect(sim.snapshot.telemetry.nextStageAction == .none)
        let noChute = FlightSim(design: VesselDesign(name: "", parts: [.podK1, .t400, .vikhr]))
        noChute.send(.stage)
        #expect(noChute.snapshot.telemetry.nextStageAction == .none)
    }

    @Test func separationActionAndFuelReserve() {
        let sim = FlightSim(design: .orbit)
        let before = sim.snapshot.telemetry.stages
        #expect(before[0].fuelMass == 8_000 && before[0].fuelCapacity == 8_000)
        #expect(before[1].fuelMass == 2_000)
        #expect(before[2].fuelCapacity == 0)
        sim.send(.stage)
        #expect(sim.snapshot.telemetry.nextStageAction == .separate)
        sim.setInput(ControlInput(throttle: 1))
        run(sim, limit: 2)
        let during = sim.snapshot.telemetry.stages
        #expect(during[0].fuelMass < before[0].fuelMass)
        #expect(during[0].fuelFraction == during[0].fuelMass / during[0].fuelCapacity)
        #expect(during[1].fuelMass == before[1].fuelMass)
        sim.send(.stage)
        #expect(sim.snapshot.telemetry.stages[0].fuelMass == 2_000)
        #expect(sim.snapshot.telemetry.nextStageAction == .separate)
        sim.send(.stage)
        #expect(sim.snapshot.telemetry.nextStageAction == .armChute)
    }

    @Test func solidBoosterHasOwnFuelAndCrashHasNoAction() {
        let sim = FlightSim(design: .jump)
        #expect(sim.snapshot.telemetry.stages[0].fuelMass == PartID.molot.spec.fuelMass)
        sim.send(.stage)
        run(sim, limit: 1)
        #expect(sim.snapshot.telemetry.stages[0].fuelMass < PartID.molot.spec.fuelMass)
        #expect(sim.snapshot.telemetry.solidBurning)
        let crash = FlightSim(design: .orbit, body: .terra,
                              position: Vec3(0, 0, Bodies.terra.radius + 3_000), velocity: Vec3(0, 0, -200))
        run(crash, limit: 200) { s, _ in s.activeSituation == .crashed }
        #expect(crash.snapshot.telemetry.nextStageAction == .none)
    }
}
