import CoreGraphics
import Foundation
import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Процедурные текстуры фона у площадки: луг, бетон с разметкой, фасад здания, градиент дымки.
/// Всё считается один раз вне главного потока и кэшируется; внешних ассетов нет.
enum BackdropTextures {
    /// Сторона квадрата травяной «заплатки» вокруг площадки, м (диаметр 2 × `groundRadius`).
    static let groundRadius = 1_000.0
    /// Радиус выреза под бетонную плиту, м (плита 32 × 32 м, угол ~22.6 м).
    static let groundHole = 26.0
    /// Сторона бетонной плиты, м.
    static let slabSize = 32.0

    // MARK: - Шум

    @inline(__always)
    private static func hash(_ x: Int, _ y: Int, _ s: UInt32) -> Double {
        var v = UInt32(truncatingIfNeeded: x) &* 374_761_393 &+ UInt32(truncatingIfNeeded: y) &* 668_265_263 &+ s &* 2_246_822_519
        v = (v ^ (v >> 13)) &* 1_274_126_177
        v ^= v >> 16
        return Double(v & 0xFFFF) / 65_535
    }

    private static func noise(_ x: Double, _ y: Double, _ s: UInt32) -> Double {
        let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
        var tx = x - Double(xi), ty = y - Double(yi)
        tx = tx * tx * (3 - 2 * tx)
        ty = ty * ty * (3 - 2 * ty)
        let a = hash(xi, yi, s), b = hash(xi + 1, yi, s)
        let c = hash(xi, yi + 1, s), d = hash(xi + 1, yi + 1, s)
        return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty
    }

    private static func fbm(_ x: Double, _ y: Double, _ s: UInt32, _ octaves: Int) -> Double {
        var sum = 0.0, amp = 1.0, norm = 0.0, f = 1.0
        for i in 0..<octaves {
            sum += amp * noise(x * f, y * f, s &+ UInt32(i) &* 17)
            norm += amp
            amp *= 0.5
            f *= 2.07
        }
        return sum / norm
    }

    private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    private static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }

    // MARK: - Сборка текстуры

    @MainActor
    static func texture(width: Int, height: Int, mipmaps: Bool, bytes: [UInt8]) async -> TextureResource? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        var options = TextureResource.CreateOptions(semantic: .color)
        options.mipmapsMode = mipmaps ? .allocateAndGenerateAll : .none
        return try? await TextureResource(image: cg, options: options)
    }

    private static func put(_ bytes: inout [UInt8], _ o: Int, _ c: SIMD3<Double>) {
        bytes[o] = UInt8(min(1, max(0, c.x)) * 255)
        bytes[o + 1] = UInt8(min(1, max(0, c.y)) * 255)
        bytes[o + 2] = UInt8(min(1, max(0, c.z)) * 255)
        bytes[o + 3] = 255
    }

    // MARK: - Луг

    /// Луг 1 пиксель = 2 м: пятна полей и перелесков, колея, закопчённая зона у плиты;
    /// к краю плавно переходит в цвет рельефа `edge` (чтобы не было шва с ландшафтом).
    nonisolated static func groundBytes(size: Int, edge: SIMD3<Double>) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        let dark: SIMD3<Double> = [0.15, 0.30, 0.10]
        let green: SIMD3<Double> = [0.26, 0.42, 0.14]
        let light: SIMD3<Double> = [0.40, 0.53, 0.20]
        let ochre: SIMD3<Double> = [0.56, 0.49, 0.26]
        let dirt: SIMD3<Double> = [0.47, 0.39, 0.28]
        let scorch: SIMD3<Double> = [0.30, 0.28, 0.25]
        let span = groundRadius * 2
        for py in 0..<size {
            for px in 0..<size {
                let wx = (Double(px) + 0.5) / Double(size) * span - groundRadius
                let wy = (Double(py) + 0.5) / Double(size) * span - groundRadius
                let r = (wx * wx + wy * wy).squareRoot()
                let large = fbm(wx / 240, wy / 240, 1, 3)
                let mid = fbm(wx / 30, wy / 30, 2, 3)
                let fine = noise(wx / 3, wy / 3, 3)
                var c = dark
                c = mix(c, green, smooth(0.30, 0.46, large))
                c = mix(c, light, smooth(0.50, 0.64, large))
                c = mix(c, ochre, smooth(0.66, 0.78, large))
                // Борозды на «полях».
                let rows = 0.5 + 0.5 * sin((wx * 0.9 + wy * 0.4) / 2.2)
                let field = smooth(0.45, 0.6, fbm(wx / 130, wy / 130, 7, 2))
                var m = 0.80 + 0.34 * mid + 0.10 * fine + 0.10 * (hash(px, py, 4) - 0.5)
                m *= 1 + 0.07 * (rows - 0.5) * field
                c *= m
                // Грунтовая колея.
                let track = abs(wy - (-170 + 0.22 * wx + 38 * sin(wx / 170)))
                let tw = 1 - smooth(1.6, 3.4, track + 3 * (noise(wx / 12, wy / 12, 5) - 0.5))
                c = mix(c, dirt * (0.85 + 0.25 * fine), tw * 0.85)
                // Гарь и гравий вокруг плиты.
                let sc = (1 - smooth(groundHole, 95, r)) * (0.55 + 0.45 * fine)
                c = mix(c, scorch * (0.8 + 0.4 * mid), sc * 0.85)
                // К краю — цвет рельефа.
                c = mix(c, edge * (0.92 + 0.16 * mid), smooth(0.62, 0.98, r / groundRadius))
                put(&bytes, (py * size + px) * 4, c)
            }
        }
        return bytes
    }

    // MARK: - Бетон

    /// Плита 32 × 32 м, 16 пикселей на метр: швы 4 м, пятна, гарь, кольцо старта и полосы по краю.
    nonisolated static func slabBytes(size: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        let half = slabSize / 2
        for py in 0..<size {
            for px in 0..<size {
                let x = (Double(px) + 0.5) / Double(size) * slabSize - half
                let y = (Double(py) + 0.5) / Double(size) * slabSize - half
                let r = (x * x + y * y).squareRoot()
                let big = fbm(x / 6, y / 6, 11, 3)
                let grain = hash(px, py, 12) - 0.5
                var g = 0.50 + 0.12 * (big - 0.5) + 0.05 * grain
                // Швы между плитами 4 м.
                let sx = abs((x + half).truncatingRemainder(dividingBy: 4) - 2)
                let sy = abs((y + half).truncatingRemainder(dividingBy: 4) - 2)
                let seam = max(smooth(1.94, 1.99, sx), smooth(1.94, 1.99, sy))
                g -= 0.16 * seam
                var c = SIMD3<Double>(g, g * 0.99, g * 0.96)
                // Закопчённая зона у центра.
                c *= 1 - 0.55 * (1 - smooth(1.5, 9, r)) * (0.6 + 0.8 * noise(x / 1.5, y / 1.5, 13))
                // Кольцо вокруг стартового стола и крест.
                let ring = 1 - smooth(0.06, 0.16, abs(r - 5.2))
                c = mix(c, [0.92, 0.92, 0.88], ring * 0.9)
                let cross = (1 - smooth(0.05, 0.12, min(abs(x), abs(y)))) * (smooth(5.6, 5.9, r)) * (1 - smooth(7.3, 7.6, r))
                c = mix(c, [0.92, 0.92, 0.88], cross * 0.9)
                // Жёлто-чёрные полосы по периметру.
                let edge = half - max(abs(x), abs(y))
                if edge < 0.55 {
                    let stripe = Int(((x + y) / 0.6).rounded(.down)) & 1
                    let hz: SIMD3<Double> = stripe == 0 ? [0.92, 0.72, 0.10] : [0.10, 0.10, 0.10]
                    c = mix(c, hz, smooth(0.0, 0.03, edge) * 0.95)
                }
                // Белая линия безопасной зоны.
                let line = 1 - smooth(0.05, 0.12, abs(edge - 2.0))
                c = mix(c, [0.88, 0.88, 0.85], line * 0.8)
                put(&bytes, (py * size + px) * 4, c)
            }
        }
        return bytes
    }

    // MARK: - Фасад

    /// Стена здания 512 × 128: светлая облицовка, пояс, ряд окон, дверь.
    nonisolated static func facadeBytes(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for py in 0..<height {
            for px in 0..<width {
                let u = (Double(px) + 0.5) / Double(width)
                let v = (Double(py) + 0.5) / Double(height)   // v = 0 — верх
                let grain = hash(px, py, 21) - 0.5
                var c = SIMD3<Double>(0.80, 0.80, 0.77) * (1 + 0.05 * grain)
                // Нижний цоколь и верхний карниз.
                if v > 0.88 { c = [0.42, 0.42, 0.42] * (1 + 0.05 * grain) }
                if v < 0.07 { c = [0.62, 0.20, 0.14] }
                // Окна: 6 штук.
                let cell = u * 6
                let cu = cell - cell.rounded(.down)
                let inWinU = cu > 0.22 && cu < 0.78
                let inWinV = v > 0.28 && v < 0.62
                if inWinU && inWinV {
                    let gv = (v - 0.28) / 0.34
                    let glass: SIMD3<Double> = mix([0.20, 0.30, 0.42], [0.08, 0.12, 0.20], gv)
                    let frame = cu < 0.25 || cu > 0.75 || v < 0.30 || v > 0.60 || abs(cu - 0.5) < 0.012
                    c = frame ? [0.90, 0.90, 0.88] : glass
                }
                put(&bytes, (py * width + px) * 4, c)
            }
        }
        return bytes
    }
}
