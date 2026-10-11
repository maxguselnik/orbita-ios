import CoreGraphics
import Foundation
import OrbitPhysics
import RealityKit

/// Процедурные текстуры-палитры: цвет рельефа берётся по UV вершины (u — высота/биом, v — строка).
enum Palette {
    struct Key: Sendable {
        let u: Double
        let rgb: SIMD3<Double>
    }

    static let width = 256

    // Терра, обычная строка: океан (u < 0.3, по глубине), берег, низины, нагорья, горы.
    static let terraRow: [Key] = [
        Key(u: 0.00, rgb: [0.02, 0.06, 0.20]),
        Key(u: 0.20, rgb: [0.03, 0.14, 0.36]),
        Key(u: 0.295, rgb: [0.09, 0.33, 0.50]),
        Key(u: 0.305, rgb: [0.78, 0.72, 0.52]),
        Key(u: 0.355, rgb: [0.62, 0.62, 0.40]),
        Key(u: 0.37, rgb: [0.30, 0.47, 0.20]),
        Key(u: 0.59, rgb: [0.20, 0.36, 0.14]),
        Key(u: 0.61, rgb: [0.38, 0.40, 0.22]),
        Key(u: 0.79, rgb: [0.47, 0.39, 0.27]),
        Key(u: 0.81, rgb: [0.46, 0.43, 0.40]),
        Key(u: 0.93, rgb: [0.58, 0.56, 0.55]),
        Key(u: 1.00, rgb: [0.93, 0.94, 0.96]),
    ]
    // Терра, полярная строка: лёд на море и на суше.
    static let terraPolarRow: [Key] = [
        Key(u: 0.00, rgb: [0.62, 0.72, 0.82]),
        Key(u: 0.30, rgb: [0.78, 0.85, 0.90]),
        Key(u: 0.31, rgb: [0.90, 0.93, 0.96]),
        Key(u: 1.00, rgb: [0.97, 0.98, 1.00]),
    ]
    static let lunaRow: [Key] = [
        Key(u: 0.00, rgb: [0.24, 0.24, 0.25]),
        Key(u: 0.45, rgb: [0.42, 0.41, 0.40]),
        Key(u: 1.00, rgb: [0.72, 0.71, 0.69]),
    ]
    static let lunaCraterRow: [Key] = [
        Key(u: 0.00, rgb: [0.20, 0.19, 0.19]),
        Key(u: 0.45, rgb: [0.34, 0.33, 0.32]),
        Key(u: 1.00, rgb: [0.62, 0.61, 0.59]),
    ]
    /// Небо: u = (1 + sin(возвышение)) / 2; 0.5 — горизонт.
    static let skyRow: [Key] = [
        Key(u: 0.00, rgb: [0.42, 0.52, 0.64]),
        Key(u: 0.50, rgb: [0.74, 0.84, 0.95]),
        Key(u: 0.56, rgb: [0.55, 0.72, 0.92]),
        Key(u: 0.75, rgb: [0.32, 0.52, 0.86]),
        Key(u: 1.00, rgb: [0.16, 0.34, 0.74]),
    ]
    /// Звёзды: яркость по u.
    static let starRow: [Key] = [
        Key(u: 0.00, rgb: [0.35, 0.37, 0.45]),
        Key(u: 0.70, rgb: [0.80, 0.82, 0.90]),
        Key(u: 1.00, rgb: [1.00, 0.97, 0.90]),
    ]

    static func sample(_ row: [Key], _ u: Double) -> SIMD3<Double> {
        guard let first = row.first, let last = row.last else { return .zero }
        if u <= first.u { return first.rgb }
        for k in 1..<row.count where u <= row[k].u {
            let a = row[k - 1], b = row[k]
            let t = (u - a.u) / max(1e-9, b.u - a.u)
            return a.rgb + (b.rgb - a.rgb) * t
        }
        return last.rgb
    }

    /// Изображение `width × rows.count` (sRGB).
    static func image(_ rows: [[Key]]) -> CGImage? {
        let h = rows.count
        var bytes = [UInt8](repeating: 255, count: width * h * 4)
        for (j, row) in rows.enumerated() {
            for i in 0..<width {
                let c = sample(row, (Double(i) + 0.5) / Double(width))
                let o = (j * width + i) * 4
                bytes[o] = UInt8(clampd(c.x, 0, 1) * 255)
                bytes[o + 1] = UInt8(clampd(c.y, 0, 1) * 255)
                bytes[o + 2] = UInt8(clampd(c.z, 0, 1) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    @MainActor
    static func texture(_ rows: [[Key]]) async -> TextureResource? {
        guard let cg = image(rows) else { return nil }
        return try? await TextureResource(image: cg, options: .init(semantic: .color))
    }

    // MARK: - UV рельефа

    /// Строки текстуры по v: центр первой — 0.25, второй — 0.75.
    static func terrainUV(body: BodyID, direction d: D3, height h: Double, noise: Double) -> SIMD2<Float> {
        let dir = vec3(d)
        let biome = Terrain.biome(body: body, direction: dir)
        switch body {
        case .terra:
            var u: Double
            if h < 0 {
                u = 0.29 * clampd(1 + h / 3_000, 0, 1)
            } else {
                switch biome {
                case .shores: u = 0.31 + 0.04 * clampd(h / 150, 0, 1)
                case .highlands: u = 0.61 + 0.18 * clampd((h - 1_200) / 1_300, 0, 1)
                case .mountains: u = 0.81 + 0.19 * clampd((h - 2_500) / 1_800, 0, 1)
                case .launchPad: u = 0.45
                default:
                    // Низины и полярный лёд — по высоте.
                    if h < 150 { u = 0.31 + 0.04 * clampd(h / 150, 0, 1) } else if h < 1_200 {
                        u = 0.37 + 0.22 * clampd((h - 150) / 1_050, 0, 1)
                    } else if h < 2_500 {
                        u = 0.61 + 0.18 * clampd((h - 1_200) / 1_300, 0, 1)
                    } else {
                        u = 0.81 + 0.19 * clampd((h - 2_500) / 1_800, 0, 1)
                    }
                }
                u += (noise - 0.5) * 0.03
            }
            let v: Float = biome == .polarIce ? 0.75 : 0.25
            return SIMD2(Float(clampd(u, 0.002, 0.998)), v)
        case .luna:
            var u = clampd((h + 2_500) / 7_000, 0, 1)
            if biome == .lunarPoles { u = min(1, u + 0.12) }
            u += (noise - 0.5) * 0.08
            let v: Float = biome == .lunarCraters ? 0.75 : 0.25
            return SIMD2(Float(clampd(u, 0.002, 0.998)), v)
        }
    }
}
