import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Небо вокруг камеры: купол-градиент (темнеет с высотой), звёзды, диск Солнца, солнечный свет.
@MainActor
final class SkyVisual {
    let root = Entity()
    /// Направление на Солнце в инерциальной системе (неподвижно).
    static let sunDirection = simd_normalize(D3(0.6, 0.75, 0.3))

    static let skyRadius: Float = 4.0e6
    static let starRadius: Float = 3.8e6
    static let sunRadius: Float = 3.6e6

    private let dome = ModelEntity()
    private let stars = ModelEntity()
    private let sun = Entity()
    let sunLight = DirectionalLight()
    let fillLight = DirectionalLight()

    private var skyTexture: TextureResource?
    private var starTexture: TextureResource?
    private var lastBrightness: Double = -1
    private var lastStarOpacity: Double = -1

    init() {
        root.addChild(dome)
        root.addChild(stars)
        root.addChild(sun)

        var b = MeshBuilder()
        let rings = 24, segs = 48
        let r = Self.skyRadius
        var idx: [[UInt32]] = []
        for i in 0...rings {
            let el = -Float.pi / 2 + Float.pi * Float(i) / Float(rings)
            var row: [UInt32] = []
            for j in 0...segs {
                let az = 2 * Float.pi * Float(j) / Float(segs)
                let p = F3(cos(el) * cos(az), sin(el), cos(el) * sin(az))
                row.append(b.vertex(p * r, -p, SIMD2((1 + sin(el)) / 2, 0.5)))
            }
            idx.append(row)
        }
        for i in 0..<rings {
            for j in 0..<segs {
                let a = idx[i][j], c = idx[i + 1][j + 1]
                let mid = -simd_normalize(b.positions[Int(a)] + b.positions[Int(c)])
                b.quad(a, idx[i][j + 1], c, idx[i + 1][j], facing: mid)
            }
        }
        if let mesh = b.makeMesh(name: "sky") {
            dome.model = ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: .black)])
        }

        // Звёзды — квадраты на сфере, лицом к центру; яркость — по u палитры.
        var s = MeshBuilder()
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func rnd() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24)
        }
        for _ in 0..<1_600 {
            let z = 2 * rnd() - 1
            let lon = 2 * Float.pi * rnd()
            let rxy = (1 - z * z).squareRoot()
            let dir = F3(rxy * cos(lon), rxy * sin(lon), z)
            let mag = rnd()
            let size = Self.starRadius * (0.0008 + 0.0016 * mag * mag)
            let t1 = simd_normalize(simd_cross(dir, abs(dir.z) < 0.9 ? F3(0, 0, 1) : F3(1, 0, 0)))
            let t2 = simd_cross(dir, t1)
            let c = dir * Self.starRadius
            let uv = SIMD2<Float>(0.2 + 0.8 * mag, 0.5)
            let i0 = s.vertex(c - t1 * size - t2 * size, -dir, uv)
            let i1 = s.vertex(c + t1 * size - t2 * size, -dir, uv)
            let i2 = s.vertex(c + t1 * size + t2 * size, -dir, uv)
            let i3 = s.vertex(c - t1 * size + t2 * size, -dir, uv)
            s.quad(i0, i1, i2, i3, facing: -dir)
        }
        if let mesh = s.makeMesh(name: "stars") {
            stars.model = ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        }

        // Солнце: яркий диск и ореол, лицом к камере.
        var disc = MeshBuilder()
        disc.disc(radius: Self.sunRadius * 0.012, segments: 32)
        var halo = MeshBuilder()
        halo.disc(radius: Self.sunRadius * 0.045, segments: 32)
        if let m = disc.makeMesh(name: "sun") {
            sun.addChild(ModelEntity(mesh: m, materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.97, blue: 0.88, alpha: 1))]))
        }
        if let m = halo.makeMesh(name: "halo") {
            var mat = UnlitMaterial(color: UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 1))
            mat.blending = .transparent(opacity: .init(floatLiteral: 0.18))
            let e = ModelEntity(mesh: m, materials: [mat])
            e.position = F3(0, 0, -Self.sunRadius * 0.01)
            sun.addChild(e)
        }
        let sd = f3(Self.sunDirection)
        sun.position = sd * Self.sunRadius
        sun.orientation = simd_quatf(from: F3(0, 0, 1), to: -sd)

        sunLight.light.intensity = 7_000
        sunLight.light.color = UIColor(red: 1, green: 0.97, blue: 0.92, alpha: 1)
        sunLight.look(at: -sd, from: .zero, relativeTo: nil)
        root.addChild(sunLight)
        // Слабая подсветка с обратной стороны — чтобы ночная сторона не была чёрной дырой.
        fillLight.light.intensity = 700
        fillLight.light.color = UIColor(red: 0.6, green: 0.7, blue: 1, alpha: 1)
        fillLight.look(at: sd, from: .zero, relativeTo: nil)
        root.addChild(fillLight)

        Task { [weak self] in
            let sky = await Palette.texture([Palette.skyRow])
            let star = await Palette.texture([Palette.starRow])
            self?.skyTexture = sky
            self?.starTexture = star
            self?.lastBrightness = -1
            self?.lastStarOpacity = -1
        }
    }

    /// `up` — местная вертикаль у камеры, `brightness` 0…1 — яркость дневного неба.
    func update(up: D3, brightness: Double) {
        dome.orientation = simd_quatf(from: F3(0, 1, 0), to: f3(up))
        if abs(brightness - lastBrightness) > 0.004 {
            lastBrightness = brightness
            let b = CGFloat(brightness)
            var m = UnlitMaterial(color: .black)
            if let tex = skyTexture {
                m.color = .init(tint: UIColor(red: b, green: b, blue: b, alpha: 1), texture: .init(tex))
            } else {
                m.color = .init(tint: UIColor(red: 0.3 * b, green: 0.5 * b, blue: 0.85 * b, alpha: 1))
            }
            dome.model?.materials = [m]
        }
        let opacity = clampd(1 - brightness * 3.5, 0, 1)
        if abs(opacity - lastStarOpacity) > 0.01 {
            lastStarOpacity = opacity
            stars.isEnabled = opacity > 0.02
            var m = UnlitMaterial(color: .white)
            if let tex = starTexture {
                m.color = .init(tint: .white, texture: .init(tex))
            }
            m.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            stars.model?.materials = [m]
        }
    }
}
