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
        // Низины: густая трава → луг → сухая степь → лес → тёмный лес (выбор по шуму, не только по высоте).
        Key(u: 0.37, rgb: [0.30, 0.50, 0.17]),
        Key(u: 0.44, rgb: [0.50, 0.55, 0.24]),
        Key(u: 0.50, rgb: [0.66, 0.60, 0.38]),
        Key(u: 0.545, rgb: [0.22, 0.40, 0.15]),
        Key(u: 0.59, rgb: [0.11, 0.26, 0.09]),
        Key(u: 0.61, rgb: [0.27, 0.35, 0.14]),
        Key(u: 0.79, rgb: [0.40, 0.33, 0.20]),
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
        Key(u: 0.00, rgb: [0.15, 0.15, 0.16]),
        Key(u: 0.25, rgb: [0.27, 0.27, 0.28]),
        Key(u: 0.50, rgb: [0.44, 0.43, 0.42]),
        Key(u: 0.75, rgb: [0.60, 0.59, 0.57]),
        Key(u: 1.00, rgb: [0.78, 0.77, 0.75]),
    ]
    static let lunaCraterRow: [Key] = [
        Key(u: 0.00, rgb: [0.13, 0.13, 0.13]),
        Key(u: 0.30, rgb: [0.24, 0.23, 0.23]),
        Key(u: 0.60, rgb: [0.40, 0.39, 0.37]),
        Key(u: 1.00, rgb: [0.68, 0.67, 0.64]),
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
        // Без мип-уровней: палитра по u, усреднение по мипам смешало бы все цвета.
        var options = TextureResource.CreateOptions(semantic: .color)
        options.mipmapsMode = .none
        return try? await TextureResource(image: cg, options: options)
    }

    // MARK: - Шум

    /// Гладкий value-noise 0…1 на целочисленной решётке (трилинейно, сглаженные веса).
    static func valueNoise(_ p: D3) -> Double {
        let i = D3(p.x.rounded(.down), p.y.rounded(.down), p.z.rounded(.down))
        let t = p - i
        let w = t * t * (D3(repeating: 3) - 2 * t)
        func h(_ x: Double, _ y: Double, _ z: Double) -> Double { hashNoise(i + D3(x, y, z), scale: 1) }
        let x00 = h(0, 0, 0) + (h(1, 0, 0) - h(0, 0, 0)) * w.x
        let x10 = h(0, 1, 0) + (h(1, 1, 0) - h(0, 1, 0)) * w.x
        let x01 = h(0, 0, 1) + (h(1, 0, 1) - h(0, 0, 1)) * w.x
        let x11 = h(0, 1, 1) + (h(1, 1, 1) - h(0, 1, 1)) * w.x
        let y0 = x00 + (x10 - x00) * w.y
        let y1 = x01 + (x11 - x01) * w.y
        return y0 + (y1 - y0) * w.z
    }

    /// Фрактальный шум около 0 (примерно ±0.5): крупные пятна материков/морей и мелкая россыпь.
    /// Октавы мельче 2 % радиуса не берутся (одинаково на всех уровнях LOD, `cell` не используется);
    /// октавы суммируются без перенормировки — детализация лишь добавляется.
    static func fbm(_ d: D3, radius: Double, cell: Double) -> Double {
        var sum = 0.0
        var amp = 1.0
        var wavelength = radius * 0.9
        // Минимальная длина волны не зависит от уровня LOD: иначе соседние патчи разных уровней
        // получают разный цвет и видны квадратами.
        let minWavelength = radius * 0.02
        for _ in 0..<6 {
            if wavelength < minWavelength { break }
            sum += amp * (valueNoise(d * (radius / wavelength)) - 0.5)
            amp *= 0.5
            wavelength *= 0.38
        }
        return sum
    }

    // MARK: - UV рельефа

    /// Строки текстуры по v (v = 0 — низ изображения): первая строка — v = 0.75, вторая — v = 0.25.
    /// `cell` — размер ячейки патча, м (ограничивает частоту шума; 0 — все октавы).
    static func terrainUV(body: BodyID, direction d: D3, height h: Double, noise: Double,
                          cell: Double = 0) -> SIMD2<Float> {
        let dir = vec3(d)
        let radius = Bodies.body(body).radius
        let big = fbm(d, radius: radius, cell: cell)
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
                    // Низины и полярный лёд — по высоте; в низинах тип покрова выбирает шум.
                    if h < 150 { u = 0.31 + 0.04 * clampd(h / 150, 0, 1) } else if h < 1_200 {
                        u = clampd(0.48 + 0.7 * big + 0.05 * clampd((h - 150) / 1_050, 0, 1), 0.372, 0.588)
                    } else if h < 2_500 {
                        u = 0.61 + 0.18 * clampd((h - 1_200) / 1_300, 0, 1)
                    } else {
                        u = 0.81 + 0.19 * clampd((h - 2_500) / 1_800, 0, 1)
                    }
                }
                u += (noise - 0.5) * 0.03 + (h >= 1_200 ? 0.06 * big : 0)
            }
            let v: Float = biome == .polarIce ? 0.25 : 0.75
            return SIMD2(Float(clampd(u, 0.002, 0.998)), v)
        case .luna:
            var u = clampd((h + 2_500) / 7_000, 0, 1)
            if biome == .lunarPoles { u = min(1, u + 0.12) }
            // Моря (тёмные пятна) и светлые нагорья, плюс мелкая зернистость реголита.
            u += 0.55 * big + (noise - 0.5) * 0.06
            let v: Float = biome == .lunarCraters ? 0.25 : 0.75
            return SIMD2(Float(clampd(u, 0.002, 0.998)), v)
        }
    }
}
