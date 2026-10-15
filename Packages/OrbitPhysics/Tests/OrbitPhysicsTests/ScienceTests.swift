import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Наука: данные, места и архив")
struct ScienceTests {
    private func subject(_ body: BodyID, _ s: ScienceSituation) -> ScienceSubjectID {
        ScienceSubjectID(experiment: .crewReport, body: body, situation: s)
    }

    @Test func situationsByBodyAndAltitude() {
        func sit(_ b: BodyID, _ v: VesselSituation, _ alt: Double = 0) -> ScienceSituation? {
            ScienceContext.situation(body: b, vessel: v, altitude: alt)
        }
        #expect(sit(.terra, .prelaunch) == .launchPad)
        #expect(sit(.terra, .landed) == .landed)
        #expect(sit(.terra, .splashed) == .splashed)
        #expect(sit(.terra, .flying, 17_999) == .lowAtmosphere)
        #expect(sit(.terra, .flying, 18_000) == .highAtmosphere)
        #expect(sit(.terra, .suborbital, 70_000) == .nearSpace)
        #expect(sit(.terra, .orbiting, 249_000) == .nearSpace)
        #expect(sit(.terra, .orbiting, 250_000) == .highSpace)
        #expect(sit(.luna, .landed) == .landed)
        #expect(sit(.luna, .orbiting, 59_000) == .nearSpace)
        #expect(sit(.luna, .orbiting, 61_000) == .highSpace)
        #expect(sit(.arda, .flying, 10_000) == .lowAtmosphere)
        #expect(sit(.taros, .landed) == nil)          // газовый гигант: поверхности нет
        #expect(sit(.terra, .crashed) == nil)
    }

    @Test func subjectValues() {
        #expect(subject(.terra, .launchPad).cap == 2.4)
        #expect(subject(.terra, .lowAtmosphere).cap == 5.6)
        #expect(subject(.terra, .nearSpace).cap == 8)
        #expect(subject(.terra, .highSpace).cap == 12)
        #expect(subject(.luna, .landed).cap == 32)
        #expect(subject(.luna, .lowAtmosphere).cap == 0)   // у Луны нет атмосферы
        #expect(subject(.terra, .nearSpace).key == "crewReport@terra:nearSpace")
    }

    @Test func archiveCreditsEachSubjectOnce() {
        var a = ScienceArchive()
        let first = ScienceData(subject: subject(.terra, .nearSpace), collectedAt: 0)
        let copy = ScienceData(subject: subject(.terra, .nearSpace), collectedAt: 5)
        #expect(a.preview([first, copy]) == [8, 0])
        #expect(a.valueOfNew(subject(.terra, .nearSpace), stored: [first]) == 0)
        #expect(a.valueOfNew(subject(.terra, .highSpace), stored: [first]) == 12)
        #expect(a.deliver(first) == 8)
        #expect(a.deliver(first) == 0)              // тот же результат второй раз
        #expect(a.deliver(copy) == 0)               // тот же предмет — предел исчерпан
        #expect(a.total == 8 && a.remaining(subject(.terra, .nearSpace)) == 0)
    }

    @Test func fractionalScienceIsNotLostToRounding() {
        var p = GameProgress(mode: .science)
        let surface = [ScienceSituation.launchPad, .landed, .splashed].map {
            ScienceData(subject: subject(.terra, $0), collectedAt: 0)
        }
        #expect(p.deliver(surface) == 7)            // 3 × 2.4 = 7.2
        #expect(p.deliver([ScienceData(subject: subject(.terra, .nearSpace), collectedAt: 0)]) == 8)  // 15.2
        #expect(p.deliver(surface) == 0)            // повторная доставка
        #expect(p.science == 15)
    }

    @Test func flightAwardDeliversDataOnce() {
        var p = GameProgress(mode: .science)
        var flight = FlightAward()
        let data = [ScienceData(subject: subject(.terra, .nearSpace), collectedAt: 0)]
        let m = MissionRecord(launched: true)
        let r = flight.credit(m, recovered: data, to: &p)
        #expect(r.science == 2 + 8 && flight.dataScience == 8 && p.science == 10)
        let again = flight.credit(m, recovered: data, to: &p)
        #expect(again.science == 10 && p.science == 10)
    }

    @Test func crewReportIsStoredInCrewedPod() {
        let sim = FlightSim(design: .jump)
        #expect(sim.snapshot.telemetry.science.situation == .launchPad)
        #expect(sim.snapshot.telemetry.science.crewAboard)
        #expect(sim.snapshot.telemetry.science.recoverable)
        sim.send(.collectScience(.crewReport))
        let stored = sim.snapshot.telemetry.science.stored
        #expect(stored.count == 1 && stored.first?.part == .podK1)
        #expect(stored.first?.data.subject == subject(.terra, .launchPad))
        sim.send(.discardScience(id: stored[0].data.id))
        #expect(sim.snapshot.telemetry.science.stored.isEmpty)
    }

    @Test func probeWithoutCrewCannotReport() {
        let sim = FlightSim(design: VesselDesign(name: "Зонд", parts: [.probe, .t100, .molot]))
        #expect(!sim.snapshot.telemetry.science.crewAboard)
        sim.send(.collectScience(.crewReport))
        #expect(sim.snapshot.telemetry.science.stored.isEmpty)
    }

    @Test func reportStaysWithPodAfterSeparation() {
        let r = Bodies.terra.radius + 100_000
        let v = (Bodies.terra.mu / r).squareRoot()
        let sim = FlightSim(design: .orbit, body: .terra, position: Vec3(r, 0, 0), velocity: Vec3(0, v, 0))
        #expect(sim.snapshot.telemetry.science.situation == .nearSpace)
        #expect(!sim.snapshot.telemetry.science.recoverable)
        sim.send(.collectScience(.crewReport))
        let parts = sim.activeParts.count
        for _ in 0..<6 where sim.activeParts.count == parts { sim.send(.stage) }
        #expect(sim.activeParts.count < parts)
        #expect(sim.snapshot.telemetry.science.stored.map(\.data.subject) == [subject(.terra, .nearSpace)])
    }
}

@Suite("Наука: приборы")
struct InstrumentTests {
    @Test func instrumentsWorkOnlyWhereTheyShould() {
        #expect(ExperimentID.temperature.works(.nearSpace, body: .terra))
        #expect(!ExperimentID.temperature.works(.highSpace, body: .terra))
        #expect(ExperimentID.pressure.works(.lowAtmosphere, body: .terra))
        #expect(ExperimentID.pressure.works(.launchPad, body: .terra))
        #expect(!ExperimentID.pressure.works(.nearSpace, body: .terra))
        #expect(!ExperimentID.pressure.works(.landed, body: .luna))       // на Луне нет воздуха
        #expect(ExperimentID.gravity.works(.landed, body: .luna))
        #expect(!ExperimentID.gravity.works(.lowAtmosphere, body: .terra))
        #expect(ScienceSubjectID(experiment: .gravity, body: .luna, situation: .landed).cap == 80)
    }

    @Test func instrumentsAreRadialAndInTechTree() {
        for p in [PartID.thermometer, .barometer, .gravimeter] {
            #expect(p.spec.kind == .instrument && p.spec.mount == .radial)
            #expect(!p.spec.acceptsAxial && !p.spec.acceptsRadial)
        }
        #expect(TechTree.tech(for: .thermometer) == .instruments)
        #expect(TechTree.tech(for: .gravimeter) == .gravimetry)
    }

    private var probeWithInstruments: VesselDesign {
        var d = VesselDesign(name: "Зонд", parts: [.probe, .t100, .molot])
        let tank = d.nodes[1].id
        for (k, p) in [PartID.thermometer, .barometer].enumerated() {
            _ = VesselEditing.attach(p, to: AttachTarget(parent: tank, node: .radial, angle: Double(k) * 90, height: 0.5, position: .zero),
                                     symmetry: 1, in: &d)
        }
        return d
    }

    @Test func probeStoresOneResultPerInstrument() {
        let sim = FlightSim(design: probeWithInstruments)
        let st = sim.snapshot.telemetry.science
        #expect(st.instruments == [.temperature, .pressure] && !st.crewAboard)
        #expect(st.experiments == [.temperature, .pressure])
        #expect(st.blocker(.gravity) == .noInstrument && st.blocker(.crewReport) == .noCrew)
        sim.send(.collectScience(.temperature))
        let after = sim.snapshot.telemetry.science
        #expect(after.stored.map(\.part) == [.thermometer])
        #expect(after.blocker(.temperature) == .instrumentFull)
        sim.send(.collectScience(.temperature))
        #expect(sim.snapshot.telemetry.science.stored.count == 1)
    }

    @Test func crewedShipKeepsInstrumentResultsInPod() {
        var d = VesselDesign.jump
        let pod = d.nodes.first { $0.part == .podK1 }!.id
        _ = VesselEditing.attach(.thermometer, to: AttachTarget(parent: pod, node: .radial, angle: 0, height: 0.5, position: .zero),
                                 symmetry: 1, in: &d)
        let sim = FlightSim(design: d)
        sim.send(.collectScience(.temperature))
        sim.send(.collectScience(.temperature))     // в кабине места хватает; повтор предмета ценности не даст
        #expect(sim.snapshot.telemetry.science.stored.map(\.part) == [.podK1, .podK1])
        #expect(ScienceArchive().preview(sim.snapshot.telemetry.science.data) == [2.4, 0])
    }
}
