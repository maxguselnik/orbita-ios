import CoreGraphics
import Observation
import OrbitPhysics

/// Карта (ведущий): прогноз траектории и узла для рендера (B) и оверлея (C).
/// Владеет ею `FlightHUDModel`: вызывает `update(sim:now:)` каждый кадр, прогноз пересчитывается
/// не чаще `refreshInterval` (сразу — при смене узла, но не чаще `editInterval`).
@MainActor
@Observable
final class MapModel {
    /// Пересчёт без изменений узла, с.
    static let refreshInterval = 0.25
    /// Пересчёт во время правки узла, с.
    static let editInterval = 1.0 / 30
    /// Участков патченных коник в прогнозе.
    static let maxPatches = TrajectoryPredictor.defaultMapPatches

    /// Карта открыта: рендер показывает карту вместо полёта.
    var isOpen = false {
        didSet {
            renderer?.isMapMode = isOpen
            if isOpen { lastRefresh = nil }
        }
    }
    var focus: MapFocus = .vessel {
        didSet { renderer?.mapFocus = focus }
    }
    /// Последний прогноз (меняется не чаще `refreshInterval`).
    private(set) var snapshot = MapSnapshot.empty

    @ObservationIgnored weak var renderer: (any FlightRenderer)? {
        didSet {
            renderer?.isMapMode = isOpen
            renderer?.mapFocus = focus
        }
    }
    @ObservationIgnored private var lastRefresh: Double?
    @ObservationIgnored private var lastNode: ManeuverNode?

    init() {}

    /// Кадр: пересчитать прогноз, если карта открыта и пора.
    func update(sim: any FlightSimulation, now: Double) {
        guard isOpen else { return }
        let node = sim.snapshot.telemetry.maneuver?.node
        let elapsed = lastRefresh.map { now - $0 } ?? .infinity
        let due = node != lastNode ? elapsed >= Self.editInterval : elapsed >= Self.refreshInterval
        guard due else { return }
        lastRefresh = now
        lastNode = node
        snapshot = Self.compute(sim: sim, node: node)
        renderer?.updateMap(snapshot)
    }

    /// Пересчитать на следующем кадре (новый полёт, смена SOI).
    func invalidate() {
        lastRefresh = nil
    }

    /// Размер 3D-вьюхи в точках.
    func setViewSize(_ size: CGSize) {
        renderer?.viewSize = size
    }

    /// Точка в системе тела → экран; nil — не видна или карта закрыта.
    func project(_ position: Vec3, body: BodyID) -> CGPoint? {
        renderer?.project(position, body: body)
    }

    /// Время точки текущей орбиты под пальцем, nil — мимо.
    func orbitPick(at point: CGPoint, maxDistance: CGFloat = 28) -> Double? {
        renderer?.orbitPick(at: point, maxDistance: maxDistance)
    }

    static func compute(sim: any FlightSimulation, node: ManeuverNode?) -> MapSnapshot {
        let world = sim.snapshot
        var map = MapSnapshot()
        map.time = world.time
        let trajectory = sim.predictTrajectory(maxPatches: maxPatches)
        map.trajectory = trajectory
        map.markers = MapMarkers.compute(trajectory, afterManeuver: false)
        if let node, let prediction = sim.predictManeuver(node, maxPatches: maxPatches) {
            map.maneuver = prediction
            map.markers += MapMarkers.compute(prediction.trajectory, afterManeuver: true)
            if let first = prediction.trajectory.patches.first {
                let s = first.start
                map.markers.append(MapMarker(kind: .maneuver, body: prediction.body, position: s.position,
                                             time: first.startTime,
                                             altitude: s.position.length - Bodies.body(prediction.body).radius,
                                             patchIndex: 0, afterManeuver: true))
            }
        }
        let t = world.telemetry
        if t.body == .terra, t.situation == .orbiting,
           let v = world.vessels.first(where: { $0.id == world.activeVessel }) {
            map.lunaPhase = TrajectoryPredictor.lunaPhase(position: v.position, velocity: v.velocity, time: world.time)
            map.hohmannPhase = TrajectoryPredictor.hohmannLunaPhase(radius: v.position.length)
        }
        return map
    }
}
