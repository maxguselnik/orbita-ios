import Foundation

/// Развёртка шести граней кубосферы в готовую текстуру 3 × 2.
/// Общая для карты, всех LOD и офлайн-генератора: берег не меняет цвет при переключении сетки.
enum PlanetSurface {
    static let faceSize = 1024
    static let gutter = 8
    static let tileSize = faceSize + 2 * gutter
    static let width = 3 * tileSize
    static let height = 2 * tileSize

    /// a, b — координаты грани −1…1. PNG хранит строки сверху вниз, UV — снизу вверх.
    static func uv(face: Int, a: Double, b: Double) -> SIMD2<Float> {
        let x = Double((face % 3) * tileSize + gutter) + (a + 1) * 0.5 * Double(faceSize)
        let y = Double((face / 3) * tileSize + gutter) + (1 - b) * 0.5 * Double(faceSize)
        return SIMD2(Float(x / Double(width)), Float(1 - y / Double(height)))
    }
}
