import Foundation

extension Quat {
    /// Кватернион из ортонормированного базиса: образы осей корабля X, Y (нос), Z в инерциальной системе.
    public init(basisX x: Vec3, y: Vec3, z: Vec3) {
        // Матрица со столбцами x, y, z.
        let m00 = x.x, m01 = y.x, m02 = z.x
        let m10 = x.y, m11 = y.y, m12 = z.y
        let m20 = x.z, m21 = y.z, m22 = z.z
        let tr = m00 + m11 + m22
        if tr > 0 {
            let s = (tr + 1).squareRoot() * 2
            self.init(w: 0.25 * s, x: (m21 - m12) / s, y: (m02 - m20) / s, z: (m10 - m01) / s)
        } else if m00 > m11 && m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            self.init(w: (m21 - m12) / s, x: 0.25 * s, y: (m01 + m10) / s, z: (m02 + m20) / s)
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            self.init(w: (m02 - m20) / s, x: (m01 + m10) / s, y: 0.25 * s, z: (m12 + m21) / s)
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            self.init(w: (m10 - m01) / s, x: (m02 + m20) / s, y: (m12 + m21) / s, z: 0.25 * s)
        }
        self = self.normalized
    }

    /// Ориентация, при которой нос (+Y) смотрит вдоль `nose`, а ось +Z корабля — как можно ближе к `zHint`.
    public static func looking(nose: Vec3, zHint: Vec3) -> Quat {
        let y = nose.normalized
        var z = zHint - y * zHint.dot(y)
        if z.lengthSquared < 1e-12 {
            let alt = abs(y.x) < 0.9 ? Vec3.unitX : Vec3.unitY
            z = alt - y * alt.dot(y)
        }
        z = z.normalized
        let x = y.cross(z)
        return Quat(basisX: x, y: y, z: z)
    }

    /// Ось (единичная) и угол поворота 0…π.
    var axisAngle: (axis: Vec3, angle: Double) {
        var q = self.normalized
        if q.w < 0 { q = Quat(w: -q.w, x: -q.x, y: -q.y, z: -q.z) }
        let v = Vec3(q.x, q.y, q.z)
        let s = v.length
        if s < 1e-12 { return (.unitX, 0) }
        return (v / s, 2 * atan2(s, q.w))
    }

    /// Нос корабля (+Y) в инерциальной системе.
    public var nose: Vec3 { rotate(.unitY) }
}

@inline(__always) func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }

/// Угол в [−π, π).
@inline(__always) func wrapPi(_ a: Double) -> Double {
    var r = (a + .pi).truncatingRemainder(dividingBy: 2 * .pi)
    if r < 0 { r += 2 * .pi }
    return r - .pi
}

/// Угол в [0, 2π).
@inline(__always) func wrap2Pi(_ a: Double) -> Double {
    var r = a.truncatingRemainder(dividingBy: 2 * .pi)
    if r < 0 { r += 2 * .pi }
    return r
}

/// Стандартное ускорение свободного падения для Isp, м/с².
public let standardGravity = 9.80665
