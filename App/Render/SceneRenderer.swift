import OrbitPhysics
import RealityKit

/// Рендер полёта (поток B). Заглушка этапа 2: реализацию пишет поток B.
@MainActor
final class SceneRenderer: FlightRenderer {
    var cameraMode: CameraMode = .follow

    func apply(_ camera: CameraInput) {}

    func update(snapshot: WorldSnapshot, events: [SimEvent], frameDelta: Double) {}
}
