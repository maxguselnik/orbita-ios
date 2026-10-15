import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Планетная система: исправления")
struct PlanetSystemTests {
    /// На границе SOI Терры излучение одинаково в обеих системах отсчёта; у Сол не горячее фотосферы.
    @Test func radiationContinuousAtTerraSOI() {
        let t = 1_000.0
        let sunDir = World.position(of: .sol, relativeTo: .terra, at: t).normalized
        let rT = sunDir * (Bodies.terra.soiRadius * 0.999)
        let inTerra = World.thermalEnvironment(body: .terra, position: rT, time: t).radiationTemperature
        let rS = World.convert(StateVector(position: rT, velocity: .zero), from: .terra, to: .sol, time: t).position
        let inSol = World.thermalEnvironment(body: .sol, position: rS, time: t).radiationTemperature
        #expect(abs(inTerra - inSol) < 1)
        let near = Vec3(Bodies.sol.radius + 100_000, 0, 0)
        #expect(World.thermalEnvironment(body: .sol, position: near, time: 0).radiationTemperature <= Bodies.sol.surfaceTemperature)
    }

    /// Почти отвесное падение с края SOI Терры: прогноз находит удар, а не обрывается по бюджету.
    @Test func radialFallFromSOIEdgeIsImpact() {
        let t = 0.0
        let luna = World.position(of: .luna, relativeTo: .terra, at: t)
        let lunaV = World.velocity(of: .luna, relativeTo: .terra, at: t)
        let away = luna.cross(lunaV).normalized   // вдоль нормали к орбите Луны — мимо неё
        let r = away * (Bodies.terra.soiRadius * 0.9)
        let v = away * -50 + luna.normalized * 1
        let tr = TrajectoryPredictor.predict(body: .terra, state: StateVector(position: r, velocity: v), time: t)
        #expect(tr.patches.first?.end == .impact)
    }

    /// Замкнутая орбита Терры с апоцентром за SOI — это уход к Сол, манёвров по ней нет.
    @Test func noGoalsWhenApoapsisBeyondSOI() {
        let b = Bodies.terra
        let rp = b.radius + 200_000, ra = b.soiRadius * 1.2
        let vp = (b.mu * (2 / rp - 2 / (ra + rp))).squareRoot()
        let s = StateVector(position: Vec3(rp, 0, 0), velocity: Vec3(0, vp, 0))
        #expect(ManeuverPlanner.availableGoals(body: .terra, state: s, time: 0).isEmpty)
    }
}
