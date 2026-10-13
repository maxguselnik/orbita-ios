import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Фон у земли: дальние холмы-силуэты по горизонту и стенки дымки (градиент прозрачности вверх),
/// из-за которых земля плавно уходит в цвет неба. Всё вокруг камеры, привязано к местной вертикали;
/// исчезает с высотой (выше пары километров работают пояса `AtmosphereVisual`).
/// Прозрачные материалы без записи глубины, факел и эффекты не перекрываются.
@MainActor
final class GroundBackdrop {
    /// Выключатель для поиска причин падений.
    static var enabled = true

    let root = Entity()

    /// Стенки дымки: радиус, высота, плотность у земли.
    private static let hazeLayers: [(r: Float, h: Float, a: Float)] = [
        (3_000, 300, 0.40), (7_000, 650, 0.42), (10_000, 1_000, 0.42), (14_500, 1_500, 0.45),
    ]
    /// Холмы: радиус, наибольшая высота, цвет, непрозрачность, зерно формы.
    private static let ridgeLayers: [(r: Float, h: Float, rgb: F3, a: Float, seed: Float)] = [
        (17_000, 1_150, F3(0.52, 0.64, 0.80), 0.95, 3.1),
        (12_000, 650, F3(0.40, 0.55, 0.66), 0.92, 7.7),
    ]
    private static let ridgeBase: Float = -400

    private var hazeEntities: [ModelEntity] = []
    private var ridgeEntities: [ModelEntity] = []
    private var lastKey = -1
    private var hazeReady = false

    init() {
        SoftTextures.shared.start()
        root.isEnabled = false
        for l in Self.hazeLayers {
            let profile = [SIMD2<Float>(l.r, 0), SIMD2<Float>(l.r, l.h)]
            let e = ModelEntity()
            if let mesh = SoftMeshes.axialLathe(profile, segments: 64, name: "groundHaze") {
                e.model = ModelComponent(mesh: mesh, materials: [])
            }
            root.addChild(e)
            hazeEntities.append(e)
        }
        for l in Self.ridgeLayers {
            let e = ModelEntity()
            if let mesh = Self.ridgeMesh(radius: l.r, height: l.h, seed: l.seed) {
                e.model = ModelComponent(mesh: mesh, materials: [])
            }
            root.addChild(e)
            ridgeEntities.append(e)
        }
    }

    func reset() {
        root.isEnabled = false
        lastKey = -1
        hazeReady = false
    }

    /// Цилиндр с неровным верхом (сумма синусов разных частот), виден изнутри и снаружи.
    private static func ridgeMesh(radius: Float, height: Float, seed: Float) -> MeshResource? {
        let segs = 192
        var b = MeshBuilder()
        var bottoms: [UInt32] = [], tops: [UInt32] = []
        for j in 0...segs {
            let a = 2 * Float.pi * Float(j) / Float(segs)
            var n: Float = 0.5 * sin(2 * a + seed) + 0.3 * sin(5 * a + seed * 1.7) + 0.2 * sin(11 * a + seed * 2.3)
            n += 0.12 * sin(23 * a + seed * 0.7) + 0.07 * sin(47 * a + seed * 3.1)
            let t = max(0.08, min(1, 0.52 + 0.5 * n))
            let top = ridgeBase + (height - ridgeBase) * t * t * 0.9 + 60
            let c = cos(a) * radius, s = sin(a) * radius
            let nrm = F3(-cos(a), 0, -sin(a))
            bottoms.append(b.vertex(F3(c, ridgeBase, s), nrm))
            tops.append(b.vertex(F3(c, top, s), nrm))
        }
        for j in 0..<segs {
            b.quad(bottoms[j], bottoms[j + 1], tops[j + 1], tops[j], facing: F3(1, 0, 0))
            b.quad(bottoms[j], bottoms[j + 1], tops[j + 1], tops[j], facing: F3(-1, 0, 0))
        }
        return b.makeMesh(name: "ridge")
    }

    func update(_ f: AtmosphereFrame) {
        let h = f.altitude - Terrain.padHeight
        let fade = clampd(1 - (h - 600) / 3_000, 0, 1)
        guard Self.enabled, f.frameBody == .terra, abs(f.terraScale - 1) < 1e-6, fade > 0.01 else {
            if root.isEnabled { reset() }
            return
        }
        root.isEnabled = true
        let b = clampd(f.skyBrightness, 0, 1)
        let hazeTex = SoftTextures.shared.haze

        // Материалы — при заметном изменении яркости или появлении текстуры.
        let key = Int((b * 33).rounded()) * 10_000 + Int((fade * 20).rounded()) * 10 + (hazeTex != nil ? 1 : 0)
        if key != lastKey {
            lastKey = key
            let k = CGFloat(0.22 + 0.78 * b)
            let sky = Palette.sample(Palette.skyRow, 0.5)
            let hazeColor = UIColor(red: CGFloat(sky.x) * k, green: CGFloat(sky.y) * k, blue: CGFloat(sky.z) * k, alpha: 1)
            if let tex = hazeTex {
                for (i, e) in hazeEntities.enumerated() {
                    let m = SoftTextures.material(tex, tint: hazeColor, opacity: Self.hazeLayers[i].a * Float(fade))
                    e.model?.materials = [m]
                }
            }
            for (i, e) in ridgeEntities.enumerated() {
                let l = Self.ridgeLayers[i]
                var m = UnlitMaterial(color: UIColor(red: CGFloat(l.rgb.x) * k, green: CGFloat(l.rgb.y) * k,
                                                     blue: CGFloat(l.rgb.z) * k, alpha: 1))
                m.blending = .transparent(opacity: .init(floatLiteral: l.a * Float(fade)))
                e.model?.materials = [m]
            }
        }

        // Земля — на глубине камеры над площадкой; кривизна: на r километрах поверхность ниже на r²/2R.
        root.orientation = simd_quatf(from: F3(0, 1, 0), to: f3(f.up))
        let ground = Float(-max(0, h))
        let planetR = Float(Bodies.terra.radius)
        for (i, e) in hazeEntities.enumerated() {
            let r = Self.hazeLayers[i].r
            e.position = F3(0, ground - r * r / (2 * planetR), 0)
        }
        for (i, e) in ridgeEntities.enumerated() {
            let r = Self.ridgeLayers[i].r
            e.position = F3(0, ground - r * r / (2 * planetR), 0)
        }
    }
}
