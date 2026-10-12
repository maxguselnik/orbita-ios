import OrbitPhysics
import simd

// Математика рендера: всё в Double до последнего момента (floating origin),
// в Float переводится только относительно точки отсчёта (камеры).

typealias D3 = SIMD3<Double>
typealias F3 = SIMD3<Float>

extension Vec3 {
    var d3: D3 { D3(x, y, z) }
}

extension Quat {
    /// Поворот из осей корабля в инерциальные (Double).
    var quatd: simd_quatd { simd_quatd(ix: x, iy: y, iz: z, r: w) }
}

@inline(__always) func f3(_ v: D3) -> F3 { F3(Float(v.x), Float(v.y), Float(v.z)) }
@inline(__always) func vec3(_ v: D3) -> Vec3 { Vec3(v.x, v.y, v.z) }

@inline(__always) func quatf(_ q: simd_quatd) -> simd_quatf {
    simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real))
}

@inline(__always) func clampd(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }

/// Нормаль, перпендикулярная `v`, ближайшая к `hint` (или любая, если они параллельны).
func perpendicular(_ hint: D3, to v: D3) -> D3 {
    var p = hint - v * simd_dot(hint, v)
    if simd_length_squared(p) < 1e-10 {
        let alt: D3 = abs(v.x) < 0.9 ? D3(1, 0, 0) : D3(0, 1, 0)
        p = alt - v * simd_dot(alt, v)
    }
    return simd_normalize(p)
}

/// Системы координат рендера. Мир рендера — инерциальная система тела активного корабля
/// (оси совпадают с физикой: Терра вращается вокруг +Z), со сдвигом на точку отсчёта.
enum RenderFrame {
    /// Центр тела `body` в инерциальной системе тела `frame`.
    static func bodyCenter(_ body: BodyID, in frame: BodyID, luna: D3) -> D3 {
        if body == frame { return .zero }
        return frame == .terra ? luna : -luna
    }

    /// Поворот «связанная с телом система → инерциальная».
    static func bodyRotation(_ body: BodyID, terraRotation: Double) -> simd_quatd {
        body == .terra ? simd_quatd(angle: terraRotation, axis: D3(0, 0, 1)) : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    }
}

/// Детерминированный шум 0…1 по направлению (для разброса цвета рельефа).
func hashNoise(_ d: D3, scale: Double) -> Double {
    let q = (d * scale).rounded(.down)
    var h = UInt64(bitPattern: Int64(q.x)) &* 0x9E37_79B9_7F4A_7C15
    h ^= UInt64(bitPattern: Int64(q.y)) &* 0xC2B2_AE3D_27D4_EB4F
    h ^= UInt64(bitPattern: Int64(q.z)) &* 0x1656_67B1_9E37_79F9
    h ^= h >> 29
    h = h &* 0xBF58_476D_1CE4_E5B9
    h ^= h >> 32
    return Double(h & 0xFFFF) / 65_535
}
