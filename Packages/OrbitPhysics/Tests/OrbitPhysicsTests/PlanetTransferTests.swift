import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Перелёт к планете (простая карта)")
struct PlanetTransferTests {
    static let terra = Bodies.terra
    /// Круговая орбита Терры 100 км.
    static let parking = conicState(body: terra, periapsisRadius: terra.radius + 100_000,
                                    apoapsisRadius: terra.radius + 100_000)

    /// Мгновенный импульс узла по прогнозу карты: тело и состояние сразу после узла.
    static func apply(_ node: ManeuverNode, body: BodyID, state: StateVector,
                      time: Double) throws -> (body: BodyID, state: StateVector, time: Double) {
        let p = try #require(TrajectoryPredictor.predict(node: node, body: body, state: state, time: time,
                                                         mass: 1, thrust: 0, isp: 1,
                                                         maxPatches: TrajectoryPredictor.defaultMapPatches))
        let first = try #require(p.trajectory.patches.first)
        return (first.body, first.start, first.startTime)
    }

    @Test("Окно: следующее в пределах синодического периода, фаза в окне — гомановская")
    func window() {
        for id in PlanetTransfer.planets {
            let s = PlanetTransfer.synodicPeriod(id)
            let dt = PlanetTransfer.timeToWindow(id, time: 1_000)
            #expect(dt >= 0 && dt < s)
            let phase = PlanetTransfer.angle(id, at: 1_000 + dt) - PlanetTransfer.angle(.terra, at: 1_000 + dt)
            #expect(abs(remainder(phase - PlanetTransfer.requiredPhase(id), 2 * .pi)) < 1e-6)
            // Сразу после окна — следующее через синодический период, с допуском — «только что прошло».
            #expect(PlanetTransfer.timeToWindow(id, time: 1_000 + dt + 10) > s - 20)
            #expect(PlanetTransfer.timeToWindow(id, time: 1_000 + dt + 10, grace: 100) < 0)
        }
    }

    @Test("Цели «К планете» на орбите Терры и на гелиоцентрической дуге")
    func goals() {
        let goals = ManeuverPlanner.availableGoals(body: .terra, state: Self.parking, time: 0)
        for g in ManeuverGoal.planetGoals { #expect(goals.contains(g)) }
        #expect(ManeuverGoal.toArda.planet == .arda)
        #expect(ManeuverGoal.toPlanet(.taros) == .toTaros)
    }

    @Test("Вехи за планеты: SOI и орбита, по каждой отдельно")
    func planetMilestones() {
        let m = MissionRecord(launched: true, visitedPlanets: [.arda], orbitedPlanets: [.arda])
        let reached = Milestone.reached(in: m)
        #expect(reached.contains(.ardaSOI) && reached.contains(.ardaOrbit))
        #expect(!reached.contains(.vellaSOI) && !reached.contains(.tarosOrbit))
    }

    /// Полный путь мгновенными импульсами: отлёт → коррекции → Пе у планеты в годном диапазоне.
    @Test("Отлёт и коррекции доводят до Пе у планеты", arguments: PlanetTransfer.planets, [0.0, 1])
    func fullTransfer(_ id: BodyID, noise: Double) throws {
        let goal = try #require(ManeuverGoal.toPlanet(id))
        let t0 = noise == 0 ? 5_000.0 : 4_000_000
        let node = try #require(ManeuverPlanner.plan(goal, body: .terra, state: Self.parking, time: t0))
        #expect(node.time >= t0 + 30)
        #expect(node.time - t0 <= PlanetTransfer.synodicPeriod(id) + 10_000)
        var total = node.deltaV
        // Неточный прожиг: +1 м/с по прогрейду и 0.5 м/с по нормали.
        var burned = node
        burned.prograde += noise
        burned.normal += 0.5 * noise
        var cur = try Self.apply(burned, body: .terra, state: Self.parking, time: t0)
        let pre = TrajectoryPredictor.predict(body: cur.body, state: cur.state, time: cur.time,
                                              maxPatches: TrajectoryPredictor.defaultMapPatches)
        let firstOutcome = ManeuverPlanner.outcome(goal, trajectory: pre)
        if noise == 0 { #expect(firstOutcome.isGood, "после отлёта: \(firstOutcome.kind)") }
        var corrections = 0
        while let c = ManeuverPlanner.correction(goal, body: cur.body, state: cur.state, time: cur.time + 1) {
            corrections += 1
            total += c.deltaV
            var c2 = c
            c2.prograde += 0.1 * noise
            c2.radial += 0.1 * noise
            cur = try Self.apply(c2, body: cur.body, state: cur.state, time: cur.time + 1)
            if corrections >= ManeuverPlanner.maxCorrections(goal) { break }
        }
        let final = TrajectoryPredictor.predict(body: cur.body, state: cur.state, time: cur.time,
                                                maxPatches: TrajectoryPredictor.defaultMapPatches)
        let outcome = ManeuverPlanner.outcome(goal, trajectory: final)
        #expect(outcome.isGood, "итог \(outcome.kind)")
        if case .planetPeriapsis(let b, _) = outcome.kind { #expect(b == id) } else { Issue.record("нет встречи") }
        #expect(total - node.deltaV < 600, "коррекции \(total - node.deltaV) м/с")
    }
}
