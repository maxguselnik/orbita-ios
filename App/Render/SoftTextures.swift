import CoreGraphics
import Foundation
import RealityKit
import simd
import UIKit

/// Процедурные альфа-текстуры и меши для мягких эффектов (облака, факел, штрихи, плазма, лимб).
/// Всё генерируется в коде: внешних ассетов нет. Пока текстуры не готовы (`isReady == false`),
/// потребители держат свои эффекты выключенными или рисуют запасной вариант.
@MainActor
final class SoftTextures {
    static let shared = SoftTextures()

    /// Выключатель мягких (текстурных) эффектов; при `false` везде работает запасной путь.
    static var enabled = true

    private(set) var puff: TextureResource?
    private(set) var plumeOuter: TextureResource?
    private(set) var plumeCore: TextureResource?
    private(set) var streak: TextureResource?
    private(set) var plasma: TextureResource?
    private(set) var hat: TextureResource?
    /// Вертикальный градиент дымки у земли: 0 — низ стенки (плотно), 1 — верх (прозрачно).
    private(set) var haze: TextureResource?
    private var started = false

    var isReady: Bool {
        Self.enabled && puff != nil && plumeOuter != nil && plumeCore != nil && streak != nil && plasma != nil && hat != nil
    }

    /// Запускает генерацию (один раз); вызывать можно сколько угодно.
    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            let puff = await Self.make(width: 128, height: 128, Self.puffPixel)
            let outer = await Self.make(width: 128, height: 4, Self.plumeOuterPixel)
            let core = await Self.make(width: 128, height: 4, Self.plumeCorePixel)
            let streak = await Self.make(width: 128, height: 4, Self.streakPixel)
            let plasma = await Self.make(width: 128, height: 4, Self.plasmaPixel)
            let hat = await Self.make(width: 128, height: 4, Self.hatPixel)
            let haze = await Self.make(width: 128, height: 4, Self.hazePixel)
            guard let self else { return }
            self.puff = puff
            self.plumeOuter = outer
            self.plumeCore = core
            self.streak = streak
            self.plasma = plasma
            self.hat = hat
            self.haze = haze
        }
    }

    // MARK: - Материал

    /// Unlit с текстурой (цвет и непрозрачность — из неё) и общей непрозрачностью `opacity`.
    static func material(_ tex: TextureResource, tint: UIColor = .white, opacity: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: tint)
        m.color = .init(tint: tint, texture: .init(tex))
        m.blending = .transparent(opacity: .init(scale: opacity, texture: .init(tex)))
        return m
    }

    // MARK: - Пиксельные функции (x, y в 0…1; результат — непремультиплицированный RGBA)

    private typealias Pixel = (Double, Double) -> SIMD4<Double>

    private static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// Мягкий клуб с неровным («кудрявым») контуром: светлый верх, тёплые светлые края, серо-голубой низ.
    private static let puffPixel: Pixel = { x, y in
        let dx = x * 2 - 1, dy = y * 2 - 1
        let r = (dx * dx + dy * dy).squareRoot()
        let a = atan2(dy, dx)
        let edge = 1 + 0.10 * sin(3 * a + 1.0) + 0.07 * sin(5 * a + 2.0) + 0.05 * sin(9 * a) + 0.035 * sin(14 * a + 0.6)
        let t = 1 - r / edge
        let alpha = smooth(t * 1.5)
        // Внутри — «бугры»: затемнение в ложбинах, подсветка сверху-слева.
        let lump = 0.5 + 0.5 * sin(6.0 * dx + 2.0 * sin(5 * dy)) * sin(5.0 * dy + 1.3)
        let up = 0.5 - 0.5 * dy
        let shade = 0.70 + 0.30 * up + 0.07 * (lump - 0.5) - 0.06 * smooth(r * 0.9)
        return SIMD4(shade * 0.98, shade, min(1, shade * 1.04 + 0.03 * (1 - up)), alpha * alpha * (3 - 2 * alpha))
    }

    /// Факел: от сопла (x = 0) к концу (x = 1): цвет жёлтый → оранжевый, прозрачность → 0.
    private static let plumeOuterPixel: Pixel = { x, _ in
        let c = SIMD3<Double>(1.0, 0.86, 0.45) + (SIMD3<Double>(1.0, 0.42, 0.08) - SIMD3<Double>(1.0, 0.86, 0.45)) * x
        return SIMD4(c.x, c.y, c.z, 0.85 * pow(max(0, 1 - x), 1.5))
    }

    private static let plumeCorePixel: Pixel = { x, _ in
        let c = SIMD3<Double>(1.0, 0.98, 0.9) + (SIMD3<Double>(1.0, 0.80, 0.40) - SIMD3<Double>(1.0, 0.98, 0.9)) * x
        return SIMD4(c.x, c.y, c.z, 1.0 * pow(max(0, 1 - x), 1.1))
    }

    /// Штрих воздуха: хвост (x = 0) прозрачный, голова ярче и мягко обрывается.
    private static let streakPixel: Pixel = { x, _ in
        let a = smooth(x / 0.75) * (1 - smooth((x - 0.88) / 0.12))
        return SIMD4(0.95, 0.97, 1.0, a)
    }

    /// Плазма: от носа (x = 0) к хвосту (x = 1): бело-жёлтый → оранжевый, затухание.
    private static let plasmaPixel: Pixel = { x, _ in
        let c = SIMD3<Double>(1.0, 0.95, 0.8) + (SIMD3<Double>(1.0, 0.5, 0.15) - SIMD3<Double>(1.0, 0.95, 0.8)) * x
        let a = pow(max(0, 1 - x), 1.2) * (0.35 + 0.65 * smooth(x / 0.1))
        return SIMD4(c.x, c.y, c.z, a)
    }

    /// Дымка: плотная у земли, к верху плавно в ноль.
    private static let hazePixel: Pixel = { x, _ in
        SIMD4(1, 1, 1, pow(max(0, 1 - x), 1.7))
    }

    /// Колпак для колец лимба: 0 → 1 → 0 по ширине.
    private static let hatPixel: Pixel = { x, _ in
        let a = 1 - abs(2 * x - 1)
        return SIMD4(1, 1, 1, smooth(a))
    }

    private static func image(width: Int, height: Int, _ f: Pixel) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for j in 0..<height {
            for i in 0..<width {
                let c = f((Double(i) + 0.5) / Double(width), (Double(j) + 0.5) / Double(height))
                let a = min(1, max(0, c.w))
                let o = (j * width + i) * 4
                // Премультиплицированный альфа.
                bytes[o] = UInt8(min(1, max(0, c.x)) * a * 255)
                bytes[o + 1] = UInt8(min(1, max(0, c.y)) * a * 255)
                bytes[o + 2] = UInt8(min(1, max(0, c.z)) * a * 255)
                bytes[o + 3] = UInt8(a * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func make(width: Int, height: Int, _ f: Pixel) async -> TextureResource? {
        guard let cg = image(width: width, height: height, f) else { return nil }
        var options = TextureResource.CreateOptions(semantic: .color)
        options.mipmapsMode = .none
        return try? await TextureResource(image: cg, options: options)
    }
}

/// Общие меши мягких эффектов.
@MainActor
enum SoftMeshes {
    /// Единичный квадрат в плоскости XY (от −0.5 до 0.5), двусторонний, UV 0…1.
    static let billboard: MeshResource? = {
        var b = MeshBuilder()
        let a = b.vertex(F3(-0.5, -0.5, 0), F3(0, 0, 1), SIMD2(0, 0))
        let c = b.vertex(F3(0.5, -0.5, 0), F3(0, 0, 1), SIMD2(1, 0))
        let d = b.vertex(F3(0.5, 0.5, 0), F3(0, 0, 1), SIMD2(1, 1))
        let e = b.vertex(F3(-0.5, 0.5, 0), F3(0, 0, 1), SIMD2(0, 1))
        b.quad(a, c, d, e, facing: F3(0, 0, 1))
        b.quad(a, c, d, e, facing: F3(0, 0, -1))
        return b.makeMesh(name: "billboard")
    }()

    /// Лента: длина по Y (−0.5…0.5), ширина по X; UV.x — вдоль длины (0 — хвост, 1 — голова).
    static let ribbon: MeshResource? = {
        var b = MeshBuilder()
        let a = b.vertex(F3(-0.5, -0.5, 0), F3(0, 0, 1), SIMD2(0, 0))
        let c = b.vertex(F3(0.5, -0.5, 0), F3(0, 0, 1), SIMD2(0, 1))
        let d = b.vertex(F3(0.5, 0.5, 0), F3(0, 0, 1), SIMD2(1, 1))
        let e = b.vertex(F3(-0.5, 0.5, 0), F3(0, 0, 1), SIMD2(1, 0))
        b.quad(a, c, d, e, facing: F3(0, 0, 1))
        b.quad(a, c, d, e, facing: F3(0, 0, -1))
        return b.makeMesh(name: "ribbon")
    }()

    /// Кольцо в плоскости XY (нормаль +Z): внутренний радиус 0.7, внешний 1; UV.x: 0 внутри, 1 снаружи.
    static let limbRing: MeshResource? = {
        var b = MeshBuilder()
        let n = F3(0, 0, 1)
        let segs = 72
        var inner: [UInt32] = [], outer: [UInt32] = []
        for s in 0...segs {
            let a = Float(s) / Float(segs) * 2 * .pi
            let c = cos(a), sn = sin(a)
            inner.append(b.vertex(F3(0.7 * c, 0.7 * sn, 0), n, SIMD2(0, 0.5)))
            outer.append(b.vertex(F3(c, sn, 0), n, SIMD2(1, 0.5)))
        }
        for s in 0..<segs {
            b.quad(inner[s], outer[s], outer[s + 1], inner[s + 1], facing: n)
            b.quad(inner[s], outer[s], outer[s + 1], inner[s + 1], facing: -n)
        }
        return b.makeMesh(name: "limbRing")
    }()

    /// Тело вращения вокруг Y, UV.x — доля пути по профилю (0 — первая точка, 1 — последняя).
    static func axialLathe(_ profile: [SIMD2<Float>], segments: Int, name: String) -> MeshResource? {
        var b = MeshBuilder()
        b.lathe(profile, segments: segments, twoSided: true)
        b.uvs = b.uvs.map { SIMD2($0.y, 0.5) }
        return b.makeMesh(name: name)
    }

    /// Кватернион по базису (столбцы — оси x, y, z; оси ортонормированы).
    static func basis(x: F3, y: F3, z: F3) -> simd_quatf {
        simd_quatf(simd_float3x3(columns: (x, y, z)))
    }

    /// Ориентация биллборда: нормаль к камере (в нуле), ось Y — вдоль `up`.
    static func facing(position p: F3, up: F3) -> simd_quatf {
        let len = simd_length(p)
        guard len > 1e-3 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        let z = -p / len
        var x = simd_cross(up, z)
        let xl = simd_length(x)
        if xl < 1e-4 { x = simd_cross(F3(0, 1, 0), z) }
        x = simd_normalize(x)
        let y = simd_cross(z, x)
        return basis(x: x, y: y, z: z)
    }

    /// Ориентация ленты: ось Y — вдоль `axis`, плоскость к камере (в нуле).
    static func ribbonOrientation(position p: F3, axis: F3) -> simd_quatf {
        let len = simd_length(p)
        let toCam = len > 1e-3 ? -p / len : F3(0, 0, 1)
        var x = simd_cross(axis, toCam)
        if simd_length(x) < 1e-4 { x = simd_cross(axis, F3(0, 1, 0)) }
        if simd_length(x) < 1e-4 { x = simd_cross(axis, F3(1, 0, 0)) }
        x = simd_normalize(x)
        let z = simd_cross(x, axis)
        return basis(x: x, y: axis, z: z)
    }
}
