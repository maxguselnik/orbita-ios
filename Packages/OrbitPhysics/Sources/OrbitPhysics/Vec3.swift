import Foundation

/// 3D-вектор на Double. Единицы — СИ (м, м/с, м/с²).
public struct Vec3: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let unitX = Vec3(1, 0, 0)
    public static let unitY = Vec3(0, 1, 0)
    public static let unitZ = Vec3(0, 0, 1)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vec3) -> Vec3 { a * s }
    public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    public static func += (a: inout Vec3, b: Vec3) { a = a + b }
    public static func -= (a: inout Vec3, b: Vec3) { a = a - b }
    public static func *= (a: inout Vec3, s: Double) { a = a * s }

    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }

    public func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }

    public var lengthSquared: Double { dot(self) }
    public var length: Double { lengthSquared.squareRoot() }

    /// Единичный вектор; для нулевого возвращает `.zero`.
    public var normalized: Vec3 {
        let l = length
        return l > 0 ? self / l : .zero
    }
}
