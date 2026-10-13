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
        #expect(p.research(.rocketry) && p.science == 95)
        #expect(p.research(.liquid) && p.isUnlocked(.vikhr))
        #expect(!p.research(.liquid))               // уже открыта
        var poor = GameProgress(mode: .science, science: 4)
        #expect(!poor.research(.rocketry) && poor.science == 4)
    }

    @Test func milestonesAwardOnceThenQuarter() {
        var p = GameProgress(mode: .science)
        let m = MissionRecord(launched: true, maxAltitude: 90_000, reachedSpace: true, reachedOrbit: true)
        let first = p.award(m)
        #expect(Set(first.fresh) == [.launch, .above10km, .space, .orbit])
        #expect(first.science == 2 + 4 + 8 + 12 && p.science == 26)
        let again = p.award(m)
        #expect(again.fresh.isEmpty && again.science == 1 + 1 + 2 + 3)
    }

    @Test func progressRoundTripsJSON() throws {
        var p = GameProgress(mode: .science, science: 7)
        p.research(.rocketry)
        p.award(MissionRecord(launched: true))
        let back = try JSONDecoder().decode(GameProgress.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }
}
