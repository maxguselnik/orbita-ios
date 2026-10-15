import Foundation

/// Общая геометрия опор для физики и модели: координаты от низа детали.
public enum LandingLegGeometry {
    public static let footHeight = 0.04
    public static let padCenterOffset = -0.02
    public static let padHalfWidth = 0.22
    public static let padHalfHeight = 0.03

    public static func feet(diameter: Double, drop: Double) -> [Vec3] {
        let radius = diameter / 2 + 0.9
        return (0..<4).map { k in
            let angle = Double(k) * .pi / 2 + .pi / 4
            return Vec3(cos(angle) * radius, -drop + footHeight, sin(angle) * radius)
        }
    }
}

extension Ship {
    /// Опоры и оболочки деталей в осях корабля. Кешируется при изменении состава.
    func makeContactPoints() -> [Vec3] {
        var points = [Vec3.zero]
        for part in parts {
            let p = part.placement
            func add(_ local: Vec3) {
                points.append(p.center + p.geometryOrientation.rotate(local))
            }
            for end in [-0.5, 0.5] {
                add(Vec3(0, p.height * end, 0))
                for i in 0..<16 {
                    let a = Double(i) * .pi / 8
                    add(Vec3(cos(a) * p.diameter / 2, p.height * end, sin(a) * p.diameter / 2))
                }
            }
            if part.spec.kind == .legs {
                for foot in LandingLegGeometry.feet(diameter: p.diameter, drop: max(0, p.bottom)) {
                    for x in [-1.0, 1.0] {
                        for y in [-1.0, 1.0] {
                            for z in [-1.0, 1.0] {
                                add(foot + Vec3(x * LandingLegGeometry.padHalfWidth,
                                              LandingLegGeometry.padCenterOffset + y * LandingLegGeometry.padHalfHeight - p.height / 2,
                                              z * LandingLegGeometry.padHalfWidth))
                            }
                        }
                    }
                }
            }
        }
        return points
    }
}
