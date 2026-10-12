import CoreGraphics
import Foundation
import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Облачный слой Терры «с орбиты»: сфера чуть выше поверхности с процедурной полупрозрачной
/// белой текстурой (равнопромежуточная развёртка; вихри — искажение области шума), медленно дрейфует.
/// Виден с высоты больше ~20 км, гаснет к 15 км (ниже работают облака `CloudVisual`).
@MainActor
final class CloudShell {
    /// Выключатель для поиска причин падений.
    static var enabled = true
    /// Высота слоя над уровнем моря, м (выше гор Терры).
    static let height = 9_000.0
    /// Дрейф относительно поверхности, рад/с.
    static let driftRate = 0.00008
    private static let fadeLow = 15_000.0
    private static let fadeHigh = 20_000.0
    private static let steps = 8

    let root = Entity()
    private let shell = ModelEntity()
    private var texture: TextureResource?
    private var materials: [Int: PhysicallyBasedMaterial] = [:]
    private var lastStep = -1

    /// Единичная сфера: UV по долготе/широте, нормаль наружу. Общая с картой.
    static let unitSphere: MeshResource? = {
        let lon = 96, lat = 48
        var b = MeshBuilder()
        var idx = [UInt32](repeating: 0, count: (lon + 1) * (lat + 1))
        for j in 0...lat {
            let a = Float.pi / 2 - Float.pi * Float(j) / Float(lat)
            for i in 0...lon {
                let l = 2 * Float.pi * Float(i) / Float(lon)
                let p = F3(cos(a) * cos(l), cos(a) * sin(l), sin(a))
                idx[j * (lon + 1) + i] = b.vertex(p, p, SIMD2(Float(i) / Float(lon), 1 - Float(j) / Float(lat)))
            }
        }
        for j in 0..<lat {
            for i in 0..<lon {
                let a = idx[j * (lon + 1) + i], c = idx[j * (lon + 1) + i + 1]
                let d = idx[(j + 1) * (lon + 1) + i + 1], e = idx[(j + 1) * (lon + 1) + i]
                let n = b.positions[Int(a)]
                b.quad(a, c, d, e, facing: n)
            }
        }
        return b.makeMesh(name: "cloudShell")
    }()

    init() {
        shell.isEnabled = false
        root.addChild(shell)
        root.isEnabled = false
    }

    func setTexture(_ tex: TextureResource?) {
        texture = tex
        materials.removeAll()
        lastStep = -1
        if tex != nil, let mesh = Self.unitSphere {
            shell.model = ModelComponent(mesh: mesh, materials: [])
        }
    }

    func reset() { lastStep = -1 }

    /// Материал слоя: белый, освещается Солнцем (ночью тёмный), прозрачность — из текстуры × `opacity`.
    static func material(_ tex: TextureResource, opacity: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(white: 0.97, alpha: 1))
        m.roughness = .init(floatLiteral: 1)
        m.metallic = .init(floatLiteral: 0)
        m.specular = .init(floatLiteral: 0)
        m.blending = .transparent(opacity: .init(scale: opacity, texture: .init(tex)))
        return m
    }

    func update(_ f: AtmosphereFrame) {
        let fade = clampd((f.altitude - Self.fadeLow) / (Self.fadeHigh - Self.fadeLow), 0, 1)
        // Низкое качество — без слоя (дорогой полноэкранный перерисованный слой).
        let on = Self.enabled && texture != nil && fade > 0 && f.quality > 0 && shell.model != nil
        if root.isEnabled != on { root.isEnabled = on }
        guard on, let tex = texture else { return }
        shell.isEnabled = true
        let step = Int((fade * Double(Self.steps)).rounded())
        if step != lastStep {
            lastStep = step
            let m: PhysicallyBasedMaterial
            if let cached = materials[step] {
                m = cached
            } else {
                m = Self.material(tex, opacity: Float(step) / Float(Self.steps) * 0.95)
                materials[step] = m
            }
            shell.model?.materials = [m]
        }
        let radius = Bodies.terra.radius + Self.height
        let s = Float(radius * f.terraScale)
        let drift = simd_quatd(angle: Self.driftRate * f.time, axis: D3(0, 0, 1))
        root.transform = Transform(scale: F3(repeating: s), rotation: quatf(f.terraRotation * drift),
                                   translation: f3(f.terraCenter * f.terraScale))
    }

    // MARK: - Текстура

    /// Процедурная текстура облаков (RGBA, премультиплицированная, белая).
    static func makeTexture() async -> TextureResource? {
        let w = 768, h = 384
        let bytes = await Task.detached(priority: .utility) { pixels(width: w, height: h) }.value
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        var options = TextureResource.CreateOptions(semantic: .color)
        options.mipmapsMode = .none
        return try? await TextureResource(image: cg, options: options)
    }

    nonisolated static func pixels(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for j in 0..<height {
            let lat = Double.pi / 2 - Double.pi * (Double(j) + 0.5) / Double(height)
            let la = abs(lat)
            // Пояса: больше облаков у экватора и в умеренных широтах, меньше в субтропиках.
            let bias = 0.09 * cos(la * 6)
            for i in 0..<width {
                let lon = 2 * Double.pi * (Double(i) + 0.5) / Double(width)
                let d = D3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
                // Вихри: область шума искажается другим шумом.
                let warp = D3(Palette.valueNoise(d * 2.2 + D3(1.3, 4.1, 7.7)),
                              Palette.valueNoise(d * 2.2 + D3(-6.2, 2.9, 0.4)),
                              Palette.valueNoise(d * 2.2 + D3(3.3, -8.1, 5.5))) - D3(repeating: 0.5)
                let p = d + warp * 0.55
                var n = 0.0, amp = 0.5, f = 2.4
                for _ in 0..<5 {
                    n += amp * Palette.valueNoise(p * f + D3(9.1, 0.7, -3.2))
                    amp *= 0.5
                    f *= 2.1
                }
                n /= 0.96875
                let dense = Palette.smooth(0.52 - bias, 0.68 - bias, n)
                let thin = 0.16 * Palette.smooth(0.40, 0.56, n)
                let a = min(1, max(dense * 0.95, thin))
                let v = UInt8(a * 255)
                let o = (j * width + i) * 4
                bytes[o] = v
                bytes[o + 1] = v
                bytes[o + 2] = v
                bytes[o + 3] = v
            }
        }
        return bytes
    }
}
