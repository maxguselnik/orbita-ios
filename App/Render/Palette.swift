import CoreGraphics
import Foundation
import OrbitPhysics
import RealityKit
import simd

/// Процедурные текстуры-палитры: цвет рельефа берётся по UV вершины (u — высота/биом, v — строка).
enum Palette {
    struct Key: Sendable {
        let u: Double
        let rgb: SIMD3<Double>
    }

    static let width = 256

    // MARK: - Терра

    /// Зоны покрова Терры по «климатическому» индексу z (строка палитры = зона; между строками — плавный переход).
    /// 0 тропический лес, 1 саванна, 2 пустыня, 3 степь, 4 луга, 5 лиственный лес, 6 тайга, 7 тундра, 8 лёд.
    static let terraZoneCount = 9

    private struct TerraZone {
        let low: SIMD3<Double>
        let up: SIMD3<Double>
        let rock: SIMD3<Double>
        /// Доля песка на пляже 0…1.
        let sand: Double
        /// u, с которого горы покрываются снегом.
        let snowLine: Double
        /// Доля морского льда 0…1.
        let seaIce: Double
    }

    private static let terraZones: [TerraZone] = [
        TerraZone(low: [0.06, 0.22, 0.09], up: [0.09, 0.24, 0.11], rock: [0.42, 0.38, 0.33], sand: 0.55, snowLine: 0.93, seaIce: 0),
        TerraZone(low: [0.33, 0.38, 0.15], up: [0.30, 0.34, 0.15], rock: [0.46, 0.40, 0.33], sand: 0.6, snowLine: 0.92, seaIce: 0),
        TerraZone(low: [0.76, 0.62, 0.40], up: [0.62, 0.47, 0.31], rock: [0.55, 0.43, 0.33], sand: 0.3, snowLine: 0.96, seaIce: 0),
        TerraZone(low: [0.52, 0.50, 0.27], up: [0.42, 0.40, 0.24], rock: [0.48, 0.42, 0.34], sand: 0.5, snowLine: 0.88, seaIce: 0),
        TerraZone(low: [0.30, 0.45, 0.18], up: [0.26, 0.38, 0.17], rock: [0.46, 0.42, 0.37], sand: 0.45, snowLine: 0.84, seaIce: 0),
        TerraZone(low: [0.15, 0.31, 0.13], up: [0.16, 0.28, 0.14], rock: [0.45, 0.42, 0.38], sand: 0.35, snowLine: 0.84, seaIce: 0),
        TerraZone(low: [0.08, 0.20, 0.15], up: [0.12, 0.22, 0.17], rock: [0.44, 0.43, 0.41], sand: 0.2, snowLine: 0.78, seaIce: 0),
        TerraZone(low: [0.40, 0.39, 0.33], up: [0.42, 0.41, 0.38], rock: [0.50, 0.50, 0.50], sand: 0.1, snowLine: 0.70, seaIce: 0.3),
        TerraZone(low: [0.90, 0.93, 0.97], up: [0.93, 0.95, 0.98], rock: [0.93, 0.95, 0.98], sand: 0, snowLine: 0.2, seaIce: 1),
    ]

    /// Океан по глубине (u от 0 на глубине до 0.299 у берега): глубокий синий → бирюзовое мелководье.
    private static let seaKeys: [Key] = [
        Key(u: 0.000, rgb: [0.015, 0.045, 0.14]),
        Key(u: 0.060, rgb: [0.02, 0.07, 0.20]),
        Key(u: 0.140, rgb: [0.04, 0.14, 0.33]),
        Key(u: 0.220, rgb: [0.07, 0.27, 0.44]),
        Key(u: 0.270, rgb: [0.12, 0.42, 0.54]),
        Key(u: 0.299, rgb: [0.30, 0.62, 0.64]),
    ]
    private static let iceSeaKeys: [Key] = [
        Key(u: 0.000, rgb: [0.58, 0.69, 0.80]),
        Key(u: 0.299, rgb: [0.82, 0.89, 0.95]),
    ]
    private static let snowColor: SIMD3<Double> = [0.94, 0.95, 0.97]

    /// Цвет Терры: зона (строка) × u (0 — дно, 0.3 — берег, выше — суша по высоте, 1 — высочайшие горы).
    static func terraColor(zone: Int, u: Double) -> SIMD3<Double> {
        let z = terraZones[min(max(zone, 0), terraZoneCount - 1)]
        let sandColor = SIMD3<Double>(0.76, 0.70, 0.52)
        let beach = z.low + (sandColor - z.low) * z.sand
        func water(_ x: Double) -> SIMD3<Double> {
            let sea = sample(seaKeys, x)
            return sea + (sample(iceSeaKeys, x) - sea) * z.seaIce
        }
        if u <= 0.299 { return water(u) }
        if u < 0.306 {
            let t = (u - 0.299) / 0.007
            return water(0.299) + (beach - water(0.299)) * t
        }
        let land = sample([
            Key(u: 0.306, rgb: beach), Key(u: 0.33, rgb: beach), Key(u: 0.385, rgb: z.low), Key(u: 0.45, rgb: z.low),
            Key(u: 0.62, rgb: z.up), Key(u: 0.80, rgb: z.rock), Key(u: 1.0, rgb: z.rock),
        ], u)
        let t = smooth(z.snowLine, z.snowLine + 0.07, u)
        return land + (snowColor - land) * t
    }

    /// Серая шкала Луны: u 0…1 → 0.06…0.80 без цветового оттенка.
    static func lunaGrey(_ u: Double) -> Double { 0.06 + 0.74 * u }

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
        image(rows: rows.count) { sample(rows[$0], $1) }
    }

    /// Изображение `width × rows` (sRGB): `color(строка, u)`.
    static func image(rows h: Int, _ color: (Int, Double) -> SIMD3<Double>) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * h * 4)
        for j in 0..<h {
            for i in 0..<width {
                let c = color(j, (Double(i) + 0.5) / Double(width))
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
        await texture(image: image(rows))
    }

    /// Палитра Терры: 9 строк-зон (v = 1 − (z + 0.5) / 9).
    @MainActor
    static func terraTexture() async -> TextureResource? {
        await texture(image: image(rows: terraZoneCount) { terraColor(zone: $0, u: $1) })
    }

    /// Палитра Луны: одна строка серой шкалы.
    @MainActor
    static func lunaTexture() async -> TextureResource? {
        await texture(image: image(rows: 1) { _, u in
            let g = lunaGrey(u)
            return [g, g, g]
        })
    }

    @MainActor
    private static func texture(image cg: CGImage?) async -> TextureResource? {
        guard let cg else { return nil }
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


    /// Фрактальный шум, нормированный примерно в −1…1. Частоты задаются в «оборотах на радиус»;
    /// не зависит от уровня LOD патча (цвет — функция направления).
    static func fbm3(_ d: D3, base: Double, octaves: Int, offset: D3) -> Double {
        var sum = 0.0, amp = 1.0, norm = 0.0, f = base
        for _ in 0..<octaves {
            sum += amp * (valueNoise(d * f + offset) - 0.5) * 2
            norm += amp
            amp *= 0.5
            f *= 2.3
        }
        return sum / norm
    }

    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = clampd((x - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Терра: климат

    /// Широта (градусы, по модулю) → индекс зоны 0…8 (кусочно-линейно).
    private static let latitudeKnots: [(lat: Double, z: Double)] = [
        (0, 0), (8, 0.3), (16, 1), (26, 2), (36, 3), (45, 4), (54, 5), (62, 6), (69, 7), (77, 8),
    ]

    private static func zone(latitude deg: Double) -> Double {
        let k = latitudeKnots
        if deg <= k[0].lat { return k[0].z }
        for i in 1..<k.count where deg <= k[i].lat {
            let t = (deg - k[i - 1].lat) / (k[i].lat - k[i - 1].lat)
            return k[i - 1].z + (k[i].z - k[i - 1].z) * t
        }
        return k[k.count - 1].z
    }

    /// u по высоте Терры: океан 0…0.3 (глубина), суша 0.3…1. Непрерывно через береговую линию,
    /// поэтому берег не «лесенкой»: цвет интерполируется по высоте между вершинами.
    static func terraElevationU(_ h: Double) -> Double {
        if h < 0 { return 0.3 * exp(h / 700) }
        let knots: [(h: Double, u: Double)] = [
            (0, 0.30), (40, 0.325), (300, 0.45), (1_200, 0.62), (2_500, 0.80), (4_300, 0.99),
        ]
        for i in 1..<knots.count where h <= knots[i].h {
            let t = (h - knots[i - 1].h) / (knots[i].h - knots[i - 1].h)
            return knots[i - 1].u + (knots[i].u - knots[i - 1].u) * t
        }
        return 0.99
    }

    // MARK: - Луна: кратеры

    /// Копия набора кратеров физики (`Terrain`, 48 штук, тот же генератор) — только для окраски.
    /// Если физика изменит генератор, обновить здесь (либо подключить `craterShade`).
    private struct LunarCrater: Sendable {
        let center: D3
        let radius: Double
        let rays: Bool
        let index: Int
    }

    private static let lunarCraters: [LunarCrater] = {
        var out: [LunarCrater] = []
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for i in 0..<48 {
            let z = 2 * rnd() - 1
            let lon = 2 * Double.pi * rnd()
            let rxy = (1 - z * z).squareRoot()
            let radius = 0.01 + 0.11 * pow(rnd(), 2)
            out.append(LunarCrater(center: D3(rxy * cos(lon), rxy * sin(lon), z), radius: radius,
                                   rays: i % 3 == 0 && radius > 0.025, index: i))
        }
        return out
    }()

    /// Сдвиг серого от кратеров: тёмное дно, светлый вал, выброс, лучи.
    private static func lunarCraterGrey(_ d: D3, base: Double) -> Double {
        var g = base
        for c in lunarCraters {
            let cosA = simd_dot(d, c.center)
            if cosA < cos(min(Double.pi, 9 * c.radius)) { continue }
            let ang = acos(clampd(cosA, -1, 1))
            let x = ang / c.radius
            if x < 1 {
                g -= 0.45 * g * smooth(1.0, 0.7, x)
            }
            let rim = (x - 1.05) / 0.14
            g += 0.16 * exp(-rim * rim)
            if x > 1, x < 2.4 { g += 0.07 * (1 - smooth(0, 1, (x - 1) / 1.4)) }
            if c.rays, x > 1.2, x < 9 {
                let e1 = simd_normalize(simd_cross(c.center, abs(c.center.z) < 0.9 ? D3(0, 0, 1) : D3(1, 0, 0)))
                let e2 = simd_cross(c.center, e1)
                let phi = atan2(simd_dot(d, e2), simd_dot(d, e1))
                let k = Double(c.index)
                let streak = valueNoise(D3(cos(phi) * 4 + k * 7.3, sin(phi) * 4, k * 1.7))
                let fade = pow(1 - smooth(0, 1, (x - 1.2) / 7.8), 1.5)
                g += 0.22 * smooth(0.55, 0.75, streak) * fade
            }
        }
        return g
    }

    // MARK: - UV рельефа

    /// Строки Терры по v: v = 1 − (z + 0.5) / 9. Луна — одна строка.
    /// `cell` — размер ячейки патча, м (не используется: цвет не зависит от LOD).
    /// `slope` — 1 − cos угла наклона (0 — ровно). `craterShade` — точка расширения для Луны:
    /// −1 дно … +1 вал (светлее вал, темнее дно); 0 — не задано.
    static func terrainUV(body: BodyID, direction d: D3, height h: Double, noise: Double,
                          cell: Double = 0, slope: Double = 0, craterShade: Double = 0) -> SIMD2<Float> {
        switch body {
        case .terra:
            var u = terraElevationU(h)
            // Крупные пятна климата, влажность и мелкая россыпь — функции направления.
            let latDeg = abs(asin(clampd(d.z, -1, 1))) * 180 / .pi
            let n1 = fbm3(d, base: 1.5, octaves: 4, offset: D3(3.1, 7.7, 1.3))
            let n2 = fbm3(d, base: 1.2, octaves: 4, offset: D3(-5.2, 2.4, 9.1))
            let n3 = fbm3(d, base: 10, octaves: 3, offset: D3(8.8, -3.3, 4.6))
            var z = zone(latitude: latDeg + 14 * n1)
            z += 2.4 * n2 * (1 - smooth(4.5, 6.5, z))
            if h > 0 { z += 0.5 * n3 + (noise - 0.5) * 0.12 }
            // Окрестность площадки (экватор, долгота 0): луга, а не джунгли.
            let padAngle = acos(clampd(d.x, -1, 1))
            z += (3.5 - z) * exp(-pow(padAngle / 0.02, 4))
            if h > 0 { u += (noise - 0.5) * 0.01 }
            let v = 1 - (clampd(z, 0, Double(terraZoneCount - 1)) + 0.5) / Double(terraZoneCount)
            return SIMD2(Float(clampd(u, 0.004, 0.996)), Float(v))
        case .luna:
            // Моря: низкочастотный шум + впадины; нагорья светлые.
            let m = fbm3(d, base: 1.1, octaves: 4, offset: D3(5.1, -2.2, 3.7)) + (1_800 - h) / 8_000
            let mare = smooth(0.10, 0.28, m)
            var g = 0.50 + (0.17 - 0.50) * mare
            g += 0.04 * fbm3(d, base: 14, octaves: 3, offset: D3(1.9, 6.2, -4.4))
            g += (noise - 0.5) * 0.07
            g = lunarCraterGrey(d, base: g)
            // Склоны чуть темнее; вал/дно из физики (если подключена).
            g -= 0.10 * clampd(slope * 4, 0, 1) * g
            g += 0.14 * craterShade * g
            let u = (g - 0.06) / 0.74
            return SIMD2(Float(clampd(u, 0.004, 0.996)), 0.5)
        }
    }
}
