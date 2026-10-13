import CoreGraphics
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
    /// Желаемая частота кадров из настроек — ориентир авто-качества эффектов.
    var targetFrameRate: Double { get set }
    func apply(_ camera: CameraInput)
    func update(snapshot: WorldSnapshot, events: [SimEvent], frameDelta: Double)
    /// Новый полёт (старт из ангара, перезапуск): убрать корабли, обломки и эффекты прошлого полёта, сбросить камеру.
    func reset()

    // MARK: Карта (этап 5)

    /// Карта вместо полёта: тела в масштабе, орбиты, отметки. Жесты камеры (`apply`) крутят камеру карты.
    var isMapMode: Bool { get set }
    /// Вокруг чего вращается камера карты.
    var mapFocus: MapFocus { get set }
    /// Последние данные карты; рендер хранит их до следующего вызова.
    func updateMap(_ map: MapSnapshot)
    /// Размер 3D-вьюхи в точках (для проекции), выставляет UI.
    var viewSize: CGSize { get set }
    /// Точка `position` (инерциальная система тела `body`, м, на время последнего снимка) → точки экрана
    /// в текущем кадре карты; nil — за камерой или карта выключена.
    func project(_ position: Vec3, body: BodyID) -> CGPoint?
    /// Тап по орбите: время ближайшей точки текущей траектории (до манёвра) не дальше `maxDistance` pt; nil — мимо.
    func orbitPick(at point: CGPoint, maxDistance: CGFloat) -> Double?
}

/// Фокус камеры карты.
enum MapFocus: String, CaseIterable, Sendable {
    case vessel, terra, luna
}

/// Данные карты: прогноз траектории, орбита после узла, отметки. Считает `MapModel` (ведущий).
struct MapSnapshot: Sendable {
    /// Время симуляции, на которое сделан прогноз.
    var time: Double = 0
    /// Текущая орбита (участки патченных коник).
    var trajectory: Trajectory?
    /// Узел и орбита после него.
    var maneuver: ManeuverPrediction?
    /// Ап/Пе, AN/DN, входы/выходы SOI, падение, узел — для текущей орбиты и орбиты после узла.
    var markers: [MapMarker] = []
    /// Фаза Луны относительно корабля на орбите Терры, рад (nil — не на орбите Терры), и гомановская фаза.
    var lunaPhase: Double?
    var hohmannPhase: Double?

    static let empty = MapSnapshot()
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

/// Поток B: 3D-превью корабля в ангаре (конструктор 5.2). UI (C) показывает его через `HangarSceneView`.
@MainActor
protocol HangarPreview: AnyObject {
    /// Дерево проекта (раскладка — `design.layout()`); `selected` — id подсвеченных деталей.
    func show(design: VesselDesign, selected: Set<Int>)
    /// Вращение и зум камеры вокруг корабля (жесты из UI), `reset` — исходный ракурс.
    func apply(_ camera: CameraInput)
    /// Точка в осях раскладки (м) → точка экрана вида размера `viewSize`, pt; nil — за камерой.
    func project(_ point: Vec3, viewSize: CGSize) -> CGPoint?
    /// id детали под точкой экрана; nil — пусто.
    func pickPart(at point: CGPoint, viewSize: CGSize) -> Int?
}
