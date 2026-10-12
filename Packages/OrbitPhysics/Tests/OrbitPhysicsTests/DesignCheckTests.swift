import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Проверка проекта")
struct DesignCheckTests {
    func issues(_ parts: [PartID]) -> [DesignIssue] { VesselDesign(name: "t", parts: parts).issues() }

    @Test func presetsAreClean() {
        for d in VesselDesign.presets { #expect(d.issues().isEmpty, "\(d.name): \(d.issues())") }
    }

    @Test func emptyIsBlocking() {
        let i = issues([])
        #expect(i == [.empty] && i[0].isBlocking)
    }

    @Test func noCommandIsBlocking() {
        let i = issues([.t400, .shtil])
        #expect(i.first == .noCommand && i[0].isBlocking)
    }

    @Test func tooManyPartsIsBlocking() {
        let parts = [PartID.chute, .podK1] + Array(repeating: PartID.t100, count: 29) + [.shtil]
        let i = issues(parts)
        #expect(i.contains(.tooManyParts(limit: 30)))
        #expect(i.first?.isBlocking == true)
        #expect(issues(Array(parts.prefix(30))).contains(.tooManyParts(limit: 30)) == false)
    }

    @Test func blockingFirst() {
        let i = issues([.decoupler, .t400])
        #expect(i.first == .noCommand)
        let flags = i.map(\.isBlocking)
        #expect(flags == flags.sorted { $0 && !$1 })
    }

    @Test func noEngine() {
        let i = issues([.chute, .podK1, .t200])
        #expect(i == [.noEngine])
        #expect(!i[0].isBlocking)
    }

    @Test func lowTWR() {
        // Один «Штиль» на тяжёлом ярусе: тяга 60 кН при ~ 10 т.
        let i = issues([.chute, .podK1, .t800, .t800, .shtil])
        guard case .lowTWR(let stage, let twr)? = i.first(where: { if case .lowTWR = $0 { return true }; return false }) else {
            Issue.record("нет lowTWR: \(i)"); return
        }
        #expect(stage == 0 && twr > 0 && twr < 1)
        #expect(i.first { if case .lowTWR = $0 { return true }; return false }?.text.hasPrefix("TWR первой ступени") == true)
    }

    @Test func lowTWRUsesFirstEngineStage() {
        // Нижняя ступень тянет (вихрь), верхняя слабая — предупреждения нет: верхняя не стартовая.
        #expect(!issues([.chute, .podK1, .t800, .t800, .shtil, .decoupler, .t200, .vikhr]).contains {
            if case .lowTWR = $0 { return true }; return false
        })
    }

    @Test func noFuel() {
        #expect(issues([.chute, .podK1, .vikhr]) == [.noFuel(stage: 0)])
        // Бак в другой секции не считается.
        #expect(issues([.chute, .podK1, .t200, .decoupler, .vikhr]).contains(.noFuel(stage: 0)))
        // РДТТ топливо несёт сам.
        #expect(!issues([.chute, .podK1, .molot]).contains(.noFuel(stage: 0)))
    }

    @Test func emptyStageBelowCommand() {
        let i = issues([.chute, .podK1, .t200, .vikhr, .decoupler, .t100, .decoupler, .t100])
        #expect(i.contains(.emptyStage(stage: 0)))
        #expect(i.contains(.emptyStage(stage: 1)))
        #expect(i.contains(.decouplerAtBottom) == false)
        // Секция выше капсулы — не лишняя.
        #expect(!issues([.t100, .decoupler, .chute, .podK1, .t200, .vikhr]).contains { if case .emptyStage = $0 { return true }; return false })
    }

    @Test func decouplerAtBottom() {
        let i = issues([.chute, .podK1, .t200, .vikhr, .decoupler])
        #expect(i.contains(.decouplerAtBottom))
        #expect(i.contains(.emptyStage(stage: 0)))
    }

    @Test func noChute() {
        #expect(issues([.podK1, .t200, .vikhr]) == [.noChute])
        #expect(issues([.probe, .t200, .vikhr]).isEmpty)
    }

    @Test func textsAreRussianAndStageNumbered() {
        #expect(DesignIssue.lowTWR(stage: 0, twr: 0.82).text == "TWR первой ступени 0.82 — ракета не оторвётся")
        #expect(DesignIssue.noFuel(stage: 1).text.contains("2"))
        #expect(DesignIssue.emptyStage(stage: 2).text.contains("3"))
        for t in [DesignIssue.empty, .noCommand, .tooManyParts(limit: 30), .noEngine, .decouplerAtBottom, .noChute] {
            #expect(!t.text.isEmpty)
        }
    }
}
