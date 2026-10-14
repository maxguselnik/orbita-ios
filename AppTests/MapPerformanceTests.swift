import OrbitPhysics
import Testing
@testable import Orbita

@MainActor
@Suite("Регрессии прогноза карты")
struct MapPerformanceTests {
    @Test func completedTransferNodeIsNotAppliedAgainAtLuna() {
        let sim = CountingPredictionFlight(done: true)
        let map = MapModel.compute(sim: sim, node: sim.node)
        #expect(map.trajectory?.patches.first?.body == .luna)
        #expect(map.maneuver == nil)
        #expect(sim.trajectoryCalls == 1)
        #expect(sim.cachedManeuverCalls == 0 && sim.uncachedManeuverCalls == 0)
    }

    @Test func pendingNodeReusesCurrentTrajectoryThroughSimulationProtocol() {
        let sim = CountingPredictionFlight(done: false)
        let map = MapModel.compute(sim: sim, node: sim.node)
        #expect(map.maneuver != nil)
        #expect(sim.trajectoryCalls == 1)
        #expect(sim.cachedManeuverCalls == 1 && sim.uncachedManeuverCalls == 0)
        #expect(sim.receivedPrecomputedTrajectory)
    }
}

/// Реальный расчёт траекторий с учётом вызовов интерфейса: карта не должна обходить кеш через existential.
private final class CountingPredictionFlight: FlightSimulation {
    let snapshot: WorldSnapshot
    let node: ManeuverNode
    private let state: StateVector
    private(set) var trajectoryCalls = 0
    private(set) var cachedManeuverCalls = 0
    private(set) var uncachedManeuverCalls = 0
    private(set) var receivedPrecomputedTrajectory = false

    init(done: Bool) {
        let r = Bodies.luna.radius + 30_000
        state = StateVector(position: Vec3(r, 0, 0), velocity: Vec3(0, (Bodies.luna.mu / r).squareRoot(), 0))
        var world = FlightSim(design: .luna, body: .luna, position: state.position, velocity: state.velocity,
                              time: 80_000).snapshot
        node = ManeuverNode(time: done ? 10_000 : world.time + 100, prograde: done ? 860 : 10)
        world.telemetry.maneuver = ManeuverStatus(node: node, timeToNode: node.time - world.time, deltaV: node.deltaV,
                                                 remainingDeltaV: done ? 0 : node.deltaV, burnTime: 10,
                                                 timeToBurn: node.time - world.time - 5, isDone: done)
        snapshot = world
    }

    func setInput(_ input: ControlInput) {}
    func send(_ command: FlightCommand) {}
    func advance(realDelta: Double) -> [SimEvent] { [] }

    func predictTrajectory(maxPatches: Int) -> Trajectory {
        trajectoryCalls += 1
        return TrajectoryPredictor.predict(body: .luna, state: state, time: snapshot.time, maxPatches: maxPatches)
    }

    func predictManeuver(_ node: ManeuverNode, maxPatches: Int) -> ManeuverPrediction? {
        uncachedManeuverCalls += 1
        return prediction(node, trajectory: nil, maxPatches: maxPatches)
    }

    func predictManeuver(_ node: ManeuverNode, using trajectory: Trajectory?,
                         maxPatches: Int) -> ManeuverPrediction? {
        cachedManeuverCalls += 1
        receivedPrecomputedTrajectory = trajectory?.patches.first?.body == .luna
        return prediction(node, trajectory: trajectory, maxPatches: maxPatches)
    }

    private func prediction(_ node: ManeuverNode, trajectory: Trajectory?, maxPatches: Int) -> ManeuverPrediction? {
        TrajectoryPredictor.predict(node: node, body: .luna, state: state, time: snapshot.time,
                                    mass: 1_000, thrust: 60_000, isp: 345,
                                    maxPatches: maxPatches, preTrajectory: trajectory)
    }
}
