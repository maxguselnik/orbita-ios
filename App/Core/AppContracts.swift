import OrbitPhysics

// Контракты между потоками B (рендер), C (UI), D (звук/вибрация). Описание — docs/CONTRACTS.md.
// Все читают только WorldSnapshot и SimEvent из OrbitPhysics; физику не меняют.

/// Режим камеры.
enum CameraMode: String, CaseIterable, Sendable {
    case free, follow, heading
}

/// Жесты камеры за кадр (C → B).
struct CameraInput: Sendable {
    /// Поворот орбиты камеры, рад (азимут, возвышение).
    var orbitDelta: SIMD2<Float> = .zero
    /// Множитель расстояния (щипок), 1 — без изменений.
    var zoomFactor: Float = 1
    var reset = false
}

/// Поток B: 3D-сцена.
@MainActor
protocol FlightRenderer: AnyObject {
    var cameraMode: CameraMode { get set }
    func apply(_ camera: CameraInput)
    func update(snapshot: WorldSnapshot, events: [SimEvent], frameDelta: Double)
}

/// Поток D: звук.
@MainActor
protocol FlightAudio: AnyObject {
    var isEnabled: Bool { get set }
    func update(snapshot: WorldSnapshot, events: [SimEvent])
}

/// Поток D: вибрация.
@MainActor
protocol FlightHaptics: AnyObject {
    var isEnabled: Bool { get set }
    func update(snapshot: WorldSnapshot, events: [SimEvent])
}
