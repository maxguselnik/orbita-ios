import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Взрыв при аварии: непрозрачные сферы (ядро, огонь, дым) растут и сжимаются до нуля,
/// тёмные обломки летят по баллистике и ложатся на грунт. Без прозрачности.
/// Локальные оси: +Y — вертикаль в точке аварии, y = 0 — грунт. Положение и поворот корня задаёт `SceneRenderer`.
@MainActor
final class ExplosionVisual {
    let root = Entity()
    /// Тело, в инерциальной системе которого задан центр, и точка аварии на грунте.
    let body: BodyID
    let center: D3
    /// Вертикаль в точке аварии (инерциальная система).
    let up: D3
    let startTime: Double

    private struct Ball {
        let entity: ModelEntity
        let peak: Float
        let delay: Double
        let life: Double
        let offset: F3
        let rise: Float
    }

    private struct Chunk {
        let entity: ModelEntity
        let p0: F3
        let v: F3
        let axis: F3
        let spin: Float
        let tLand: Double
        let rest: Float
    }

    private var balls: [Ball] = []
    private var chunks: [Chunk] = []
    private let gravity: Float
    private var finished = false
    private let endTime: Double

    private static var sphereMesh: MeshResource?
    private static var boxMesh: MeshResource?

    init(body: BodyID, center: D3, up: D3, size: Double, seed: UInt32, startTime: Double) {
        self.body = body
        self.center = center
        self.up = up
        self.startTime = startTime
        let b = Bodies.body(body)
        gravity = Float(max(1.0, b.mu / (b.radius * b.radius)))

        if Self.sphereMesh == nil { Self.sphereMesh = MeshResource.generateSphere(radius: 1) }
        if Self.boxMesh == nil { Self.boxMesh = MeshResource.generateBox(size: 1) }
        guard let sphere = Self.sphereMesh, let box = Self.boxMesh else {
            endTime = 0
            finished = true
            return
        }
        let r = Float(clampd(size, 3, 20))

        func unlit(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UnlitMaterial {
            UnlitMaterial(color: UIColor(red: r, green: g, blue: b, alpha: 1))
        }
        let core = unlit(1.0, 0.95, 0.72)
        let fire = unlit(1.0, 0.50, 0.10)
        let fire2 = unlit(0.95, 0.34, 0.06)
        let smoke = unlit(0.17, 0.17, 0.18)
        let smoke2 = unlit(0.27, 0.26, 0.26)

        // (материал, пик в долях r, задержка, длительность, смещение в долях r, подъём в долях r)
        let defs: [(UnlitMaterial, Float, Double, Double, F3, Float)] = [
            (core, 0.95, 0.00, 1.00, F3(0, 0.55, 0), 0),
            (fire, 1.35, 0.30, 1.80, F3(0, 0.55, 0), 0.3),
            (fire2, 1.00, 0.45, 1.60, F3(0.55, 0.40, 0.25), 0.2),
            (smoke, 1.70, 0.90, 2.20, F3(0, 0.90, 0), 1.6),
            (smoke2, 1.30, 1.05, 2.00, F3(-0.60, 0.70, -0.30), 1.3),
        ]
        var end = 0.0
        for d in defs {
            let e = ModelEntity(mesh: sphere, materials: [d.0])
            e.isEnabled = false
            root.addChild(e)
            balls.append(Ball(entity: e, peak: d.1 * r, delay: d.2, life: d.3, offset: d.4 * r, rise: d.5 * r))
            end = max(end, d.2 + d.3)
        }

        // Обломки: детерминированный разброс по seed.
        var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678
        func rnd() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        let count = 6 + Int(seed % 5)
        let k = max(0.7, min(2.0, r / 4))
        for i in 0..<count {
            let ang = (Float(i) + rnd() * 0.8) / Float(count) * 2 * .pi
            let hs = (6 + 16 * rnd()) * (0.7 + 0.3 * k)
            let vy = (10 + 18 * rnd()) * (0.7 + 0.3 * k)
            let v = F3(cos(ang) * hs, vy, sin(ang) * hs)
            let dims = F3(0.25 + 0.45 * rnd(), 0.2 + 0.4 * rnd(), 0.25 + 0.45 * rnd()) * k
            let e = ModelEntity(mesh: box, materials: [i % 3 == 0 ? RenderMaterials.shared.darkMetal : RenderMaterials.shared.darkGray])
            e.scale = dims
            root.addChild(e)
            let p0 = F3(0, 0.5 * r, 0)
            let rest = min(dims.x, min(dims.y, dims.z)) * 0.45
            let disc = vy * vy + 2 * gravity * (p0.y - rest)
            let tLand = Double((vy + max(0, disc).squareRoot()) / gravity)
            var axis = F3(rnd() - 0.5, rnd() - 0.5, rnd() - 0.5)
            axis = simd_length(axis) > 0.01 ? simd_normalize(axis) : F3(0, 1, 0)
            chunks.append(Chunk(entity: e, p0: p0, v: v, axis: axis, spin: 2 + 6 * rnd(), tLand: tLand, rest: rest))
            end = max(end, tLand)
        }
        endTime = end
        update(time: startTime)
    }

    /// Кадр анимации; `time` — то же время рендера, что и в `startTime`.
    func update(time: Double) {
        guard !finished else { return }
        let t = max(0, time - startTime)
        for b in balls {
            let u = (t - b.delay) / b.life
            guard u > 0, u < 1 else {
                if b.entity.isEnabled { b.entity.isEnabled = false }
                continue
            }
            let s = b.peak * Float(sin(Double.pi * pow(u, 0.55)))
            guard s > 0.02 else {
                if b.entity.isEnabled { b.entity.isEnabled = false }
                continue
            }
            if !b.entity.isEnabled { b.entity.isEnabled = true }
            b.entity.scale = F3(repeating: s)
            b.entity.position = b.offset + F3(0, b.rise * Float(u), 0)
        }
        for c in chunks {
            let tt = Float(min(t, c.tLand))
            var p = c.p0 + c.v * tt
            p.y -= 0.5 * gravity * tt * tt
            if t >= c.tLand { p.y = c.rest }
            c.entity.position = p
            c.entity.orientation = simd_quatf(angle: c.spin * tt, axis: c.axis)
        }
        if t > endTime + 0.1 { finished = true }
    }
}
