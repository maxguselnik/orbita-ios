import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Прогресс: технологии и наука")
struct ProgressTests {
    @Test func everyPartIsInExactlyOneTech() {
        for p in PartID.allCases {
            let n = TechTree.nodes.filter { $0.parts.contains(p) }.count
            #expect(n == 1, "\(p): в \(n) технологиях")
        }
    }

    @Test func treeIsConnectedAndAcyclic() {
        let ids = Set(TechTree.nodes.map(\.id))
        #expect(ids.count == TechTree.nodes.count && ids == Set(TechID.allCases))
        for n in TechTree.nodes {
            for r in n.requires {
                #expect(TechTree.node(r).column < n.column, "\(n.id) ← \(r)")
            }
        }
        #expect(TechTree.nodes.filter { $0.requires.isEmpty }.map(\.id) == [.basics])
    }

    @Test func sandboxUnlocksEverything() {
        let p = GameProgress(mode: .sandbox)
        #expect(PartID.allCases.allSatisfy { p.isUnlocked($0) })
        #expect(p.lockedParts(in: .luna).isEmpty)
    }

    @Test func scienceModeStartsWithBasics() {
        let p = GameProgress(mode: .science)
        #expect(p.isUnlocked(.podK1) && p.isUnlocked(.molot))
        #expect(!p.isUnlocked(.vikhr) && !p.isUnlocked(.fin))
        #expect(p.lockedParts(in: .jump).isEmpty)
        #expect(Set(p.lockedParts(in: .orbit)) == [.t400, .shtil, .t800, .vikhr])
    }

    @Test func researchNeedsScienceAndPrerequisite() {
        var p = GameProgress(mode: .science, science: 100)
        #expect(!p.canResearch(.liquid))            // нужна «Ракетостроение»
        let r1 = p.research(.rocketry)
        #expect(r1 && p.science == 95)
        let r2 = p.research(.liquid)
        #expect(r2 && p.isUnlocked(.vikhr))
        let r3 = p.research(.liquid)                // уже открыта
        #expect(!r3)
        var poor = GameProgress(mode: .science, science: 4)
        let r4 = poor.research(.rocketry)
        #expect(!r4 && poor.science == 4)
    }

    @Test func milestonesAwardOnlyOnce() {
        var p = GameProgress(mode: .science)
        let m = MissionRecord(launched: true, maxAltitude: 90_000, reachedSpace: true, reachedOrbit: true)
        let first = p.award(m)
        #expect(Set(first.fresh) == [.launch, .above10km, .space, .orbit])
        #expect(first.science == 2 + 4 + 8 + 12 && p.science == 26)
        let again = p.award(m)
        #expect(again.fresh.isEmpty && again.science == 0 && p.science == 26)
    }

    @Test func flightAwardCountsEachMilestoneOncePerFlight() {
        var p = GameProgress(mode: .science)
        var flight = FlightAward()
        let space = MissionRecord(launched: true, maxAltitude: 90_000, reachedSpace: true)
        let first = flight.credit(space, to: &p)
        #expect(first.science == 2 + 4 + 8 && p.science == 14)
        // Итоги открыты повторно (пауза, выход в ангар): ничего не добавляется, итог тот же.
        let again = flight.credit(space, to: &p)
        #expect(again.science == 14 && p.science == 14 && again.fresh == first.fresh)
        // «Продолжить»: новая веха в том же полёте начисляется.
        var orbit = space
        orbit.reachedOrbit = true
        let more = flight.credit(orbit, to: &p)
        #expect(more.science == 14 + 12 && p.science == 26 && more.fresh.last == .orbit)
        // Перезапуск: новый счёт, но уже полученные вехи науки не дают.
        flight.reset()
        var reached = MissionRecord(launched: true)
        reached.enteredLunaSOI = true
        let retry = flight.credit(reached, to: &p)
        #expect(retry.fresh == [.lunaSOI] && retry.science == 15 && p.science == 41)
    }

    @Test func flightAwardSkipsLessonPart() {
        var p = GameProgress(mode: .science)
        var flight = FlightAward()
        let lesson = MissionRecord(launched: true, maxAltitude: 90_000, reachedSpace: true)
        flight.skip(lesson)
        var after = lesson
        after.reachedOrbit = true
        let r = flight.credit(after, to: &p)
        #expect(r.fresh == [.orbit] && r.science == 12 && p.science == 12)
    }

    @Test func progressRoundTripsJSON() throws {
        var p = GameProgress(mode: .science, science: 7)
        p.research(.rocketry)
        p.award(MissionRecord(launched: true))
        p.deliver([ScienceData(subject: ScienceSubjectID(experiment: .crewReport, body: .terra, situation: .nearSpace),
                               collectedAt: 0)])
        let back = try JSONDecoder().decode(GameProgress.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    @Test func oldProgressWithoutArchiveLoads() throws {
        let json = #"{"mode":"science","science":12,"researched":["basics","rocketry"],"milestones":["launch"]}"#
        let p = try JSONDecoder().decode(GameProgress.self, from: Data(json.utf8))
        #expect(p.science == 12 && p.isResearched(.rocketry) && p.milestones == [.launch] && p.archive.total == 0)
    }
}
