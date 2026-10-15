import CoreGraphics
import Foundation
import OrbitPhysics
import simd

/// Масштаб и система координат карты.
///
/// Сцена карты — инерциальная система Терры (оси как у физики: Луна в плоскости XY, ось Терры +Z),
/// 1 единица = 10 км. Содержимое сдвинуто на −фокус, так что фокус камеры в нуле сцены:
/// координаты сцены не больше нескольких тысяч единиц, точности Float хватает.
enum MapScale {
    static let metersPerUnit = 1.0e4
    /// Вертикальное поле зрения камеры карты, градусы.
    static let fovDegrees = 50.0
    static var tanHalfFov: Double { tan(fovDegrees * .pi / 360) }
    /// Радиус тела в единицах карты.
    static func radius(_ body: BodyID) -> Double { Bodies.body(body).radius / metersPerUnit }
    static let lunaOrbit = Bodies.luna.orbitRadius / metersPerUnit
    static let lunaSOI = Bodies.luna.soiRadius / metersPerUnit
    /// Дальше всего — орбита Луны с её SOI целиком ×1.3.
    static var maxDistance: Double { 1.5 * Bodies.taros.orbitRadius / metersPerUnit / tanHalfFov }
}

/// Орбитальная камера карты: азимут/возвышение/расстояние вокруг фокуса, ось «верх» — +Z.
/// Знаки ввода — как у `CameraRig`.
struct MapCamera {
    static let maxElevation = 1.45
    static let defaultElevation = 0.62
    static let defaultAzimuth = -1.9

    var azimuth = MapCamera.defaultAzimuth
    var elevation = MapCamera.defaultElevation
    var distance = 300.0
    var minDistance = 40.0
    var maxDistance = MapScale.maxDistance
    /// Нужен исходный ракурс (новый полёт, первый показ, сброс жестом).
    var needsDefault = true

    private(set) var sAz = MapCamera.defaultAzimuth
    private(set) var sEl = MapCamera.defaultElevation
    private(set) var sDist = 300.0

    mutating func apply(orbit: SIMD2<Float>, zoom: Float) {
        azimuth += Double(orbit.x)
        elevation = clampd(elevation + Double(orbit.y), -Self.maxElevation, Self.maxElevation)
        if zoom.isFinite, zoom > 0 {
            distance = clampd(distance * Double(zoom), minDistance, maxDistance)
        }
    }

    /// Исходный ракурс: сверху-сбоку, расстояние `d`.
    mutating func setDefault(distance d: Double, snap: Bool) {
        azimuth = Self.defaultAzimuth
        elevation = Self.defaultElevation
        distance = clampd(d, minDistance, maxDistance)
        needsDefault = false
        if snap { self.snap() }
    }

    mutating func setLimits(min lo: Double) {
        minDistance = lo
        distance = clampd(distance, minDistance, maxDistance)
    }

    mutating func snap() {
        sAz = azimuth
        sEl = elevation
        sDist = distance
    }

    /// Сглаживание к целевым значениям; возвращает положение камеры относительно фокуса.
    mutating func step(dt: Double) -> D3 {
        if dt > 0 {
            let k = 1 - exp(-dt * 10)
            sAz += (azimuth - sAz) * k
            sEl += (elevation - sEl) * k
            sDist *= pow(distance / sDist, k)
        }
        let dir = D3(cos(sEl) * cos(sAz), cos(sEl) * sin(sAz), sin(sEl))
        return dir * sDist
    }
}

/// Вид камеры карты в последнем кадре — для проекции точек на экран (как у RealityKit-камеры).
struct MapViewState {
    /// Фокус в координатах карты (инерциальная система Терры, единицы карты).
    var focus: D3
    /// Камера относительно фокуса.
    var eye: D3
    var right: D3
    var up: D3
    var forward: D3
    var near: Double
    var size: CGSize

    init(focus: D3, eye: D3, near: Double, size: CGSize) {
        self.focus = focus
        self.eye = eye
        self.near = near
        self.size = size
        let fwd = simd_normalize(-eye)
        let r = simd_cross(fwd, D3(0, 0, 1))
        right = simd_length_squared(r) > 1e-12 ? simd_normalize(r) : D3(1, 0, 0)
        up = simd_cross(right, fwd)
        forward = fwd
    }

    /// Поворот камеры: −Z камеры смотрит вперёд, +Y — вверх.
    var rotation: simd_quatf {
        simd_quatf(simd_float3x3(columns: (f3(right), f3(up), f3(-forward))))
    }

    /// Размер одного экранного пункта на расстоянии `depth` (единицы карты).
    func unitsPerPoint(depth: Double) -> Double {
        let h = size.height > 1 ? Double(size.height) : 393
        return 2 * depth * MapScale.tanHalfFov / h
    }

    /// Точка карты → экранные точки (начало слева сверху); nil — за камерой.
    func project(_ q: D3) -> CGPoint? {
        guard size.width > 1, size.height > 1 else { return nil }
        let v = q - focus - eye
        let z = simd_dot(v, forward)
        guard z > near else { return nil }
        let t = MapScale.tanHalfFov
        let aspect = Double(size.width / size.height)
        let nx = simd_dot(v, right) / (z * t * aspect)
        let ny = simd_dot(v, up) / (z * t)
        return CGPoint(x: (nx + 1) / 2 * Double(size.width), y: (1 - ny) / 2 * Double(size.height))
    }
}
