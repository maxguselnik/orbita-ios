import Foundation
import simd

/// Орбитальная камера вокруг корабля: азимут/возвышение/расстояние со сглаживанием.
/// Знаки ввода (от UI): orbitDelta.x > 0 — азимут растёт (камера уходит вправо от себя,
/// сцена — влево), orbitDelta.y > 0 — камера выше, zoomFactor < 1 — ближе.
struct CameraRig {
    static let minDistance = 5.0
    static let maxDistance = 50_000.0
    static let maxElevation = 1.45

    var azimuth = -2.1
    var elevation = 0.12
    var defaultElevation = 0.12
    /// Азимут по умолчанию (зависит от режима: «по курсу» — 0, ровно сзади).
    var defaultAzimuth = -2.1 {
        didSet { azimuth = defaultAzimuth }
    }
    var distance = 25.0
    var defaultDistance = 25.0

    private var sAz = -2.1
    private var sEl = 0.12
    private var sDist = 25.0
    private var sForward: D3?
    private var sUp: D3?
    private var initialized = false
    private var manualElevation = false

    mutating func apply(orbit: SIMD2<Float>, zoom: Float, reset: Bool) {
        if reset {
            manualElevation = false
            azimuth = defaultAzimuth
            elevation = defaultElevation
            distance = defaultDistance
            return
        }
        if orbit.y != 0 { manualElevation = true }
        azimuth += Double(orbit.x)
        elevation = clampd(elevation + Double(orbit.y), -Self.maxElevation, Self.maxElevation)
        if zoom.isFinite, zoom > 0 {
            distance = clampd(distance * Double(zoom), Self.minDistance, Self.maxDistance)
        }
    }

    /// Задать расстояние по размеру корабля (при первом кадре и смене корабля).
    mutating func setDefaultDistance(_ d: Double, snap: Bool) {
        defaultDistance = clampd(d, Self.minDistance, 2_000)
        if snap {
            distance = defaultDistance
            sDist = distance
        }
    }

    mutating func setDefaultElevation(_ e: Double) {
        defaultElevation = e
        if !manualElevation { elevation = e }
    }

    /// Положение камеры относительно цели и вектор «верх» кадра.
    /// `forward` — опорное направление «азимут 0» (камера там при az = 0), `up` — вертикаль режима.
    mutating func offset(forward f0: D3, up u0: D3, dt: Double) -> (offset: D3, up: D3) {
        let up = simd_normalize(u0)
        let f = perpendicular(f0, to: up)
        if !initialized || dt <= 0 && sForward == nil {
            sAz = azimuth
            sEl = elevation
            sDist = distance
            sForward = f
            sUp = up
            initialized = true
        } else if dt > 0 {
            let k = 1 - exp(-dt * 9)
            let kf = 1 - exp(-dt * 4)
            sAz += (azimuth - sAz) * k
            sEl += (elevation - sEl) * k
            sDist *= pow(distance / sDist, k)
            let nu = simd_normalize((sUp ?? up) + (up - (sUp ?? up)) * kf)
            sUp = nu
            let pf = sForward ?? f
            sForward = perpendicular(pf + (f - pf) * kf, to: nu)
        }
        let uu = sUp ?? up
        let ff = sForward ?? f
        let rt = simd_cross(uu, ff)
        let dir = cos(sEl) * (cos(sAz) * ff + sin(sAz) * rt) + sin(sEl) * uu
        return (dir * sDist, uu)
    }
}
