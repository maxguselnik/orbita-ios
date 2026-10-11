import Foundation

/// Кватернион ориентации на Double (w + xi + yj + zk), единичный.
public struct Quat: Sendable, Hashable, Codable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

    /// Поворот на `angle` радиан вокруг оси `axis`.
    public init(axis: Vec3, angle: Double) {
        let n = axis.normalized
        let s = sin(angle / 2)
        self.init(w: cos(angle / 2), x: n.x * s, y: n.y * s, z: n.z * s)
    }

    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w
        )
    }

    public var conjugate: Quat { Quat(w: w, x: -x, y: -y, z: -z) }

    public var normalized: Quat {
        let l = (w * w + x * x + y * y + z * z).squareRoot()
        return l > 0 ? Quat(w: w / l, x: x / l, y: y / l, z: z / l) : .identity
    }

    /// Поворачивает вектор.
    public func rotate(_ v: Vec3) -> Vec3 {
        let q = Vec3(x, y, z)
        let t = 2 * q.cross(v)
        return v + w * t + q.cross(t)
    }
}
