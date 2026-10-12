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
    /// Новый полёт (старт из ангара, перезапуск): убрать корабли, обломки и эффекты прошлого полёта, сбросить камеру.
    func reset()
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

/// Поток B: 3D-превью корабля в ангаре. UI (C) показывает его через `HangarSceneView`.
@MainActor
protocol HangarPreview: AnyObject {
    /// Стек деталей сверху вниз; `selected` — индекс подсвеченной детали.
    func show(parts: [PartID], selected: Int?)
    /// Вращение и зум камеры вокруг корабля (жесты из UI), `reset` — исходный ракурс.
    func apply(_ camera: CameraInput)
}
