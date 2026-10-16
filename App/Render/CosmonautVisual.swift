import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Материалы и общие меши скафандра: создаются один раз.
@MainActor
private enum SuitKit {
    static let white = SimpleMaterial(color: UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1), roughness: 0.55, isMetallic: false)
    static let grey = SimpleMaterial(color: UIColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1), roughness: 0.6, isMetallic: false)
    static let dark = SimpleMaterial(color: UIColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1), roughness: 0.7, isMetallic: false)
    static let gold = SimpleMaterial(color: UIColor(red: 0.95, green: 0.72, blue: 0.22, alpha: 1), roughness: 0.18, isMetallic: true)
    static let orange = SimpleMaterial(color: UIColor(red: 0.95, green: 0.45, blue: 0.12, alpha: 1), roughness: 0.6, isMetallic: false)
    static let jet = UnlitMaterial(color: UIColor(red: 0.82, green: 0.93, blue: 1.0, alpha: 1))

    /// Конус струйки: основание в y = 0 (радиус 0.05), вершина в y = 1.
    static let jetMesh: MeshResource = {
        var b = MeshBuilder()
        b.lathe([SIMD2(0.05, 0.0), SIMD2(0.035, 0.35), SIMD2(0.0, 1.0)], segments: 8)
        return b.makeMesh(name: "suitJet") ?? MeshResource.generateBox(size: 0.05)
    }()
}

/// Поза скафандра: углы шарниров (рад), сглаживаются каждый кадр.
private struct SuitPose {
    var thighL: Float = 0, thighR: Float = 0
    var kneeL: Float = 0, kneeR: Float = 0
    var armL: Float = 0, armR: Float = 0
    var elbow: Float = 0
    var lean: Float = 0
    var roll: Float = 0
    var drop: Float = 0

    mutating func blend(to t: SuitPose, k: Float) {
        thighL += (t.thighL - thighL) * k; thighR += (t.thighR - thighR) * k
        kneeL += (t.kneeL - kneeL) * k; kneeR += (t.kneeR - kneeR) * k
        armL += (t.armL - armL) * k; armR += (t.armR - armR) * k
        elbow += (t.elbow - elbow) * k
        lean += (t.lean - lean) * k; roll += (t.roll - roll) * k; drop += (t.drop - drop) * k
    }
}

/// Космонавт в скафандре (~1.8 м). Оси: +Y — голова, −Z — лицо, +Z — спина (ранец). Начало — между стопами.
/// Модель собирается один раз; в кадре меняются только трансформы шарниров.
@MainActor
final class CosmonautVisual {
    let root = Entity()
    private let upper = Entity()
    private let legL = Entity(), legR = Entity()
    private let shinL = Entity(), shinR = Entity()
    private let armL = Entity(), armR = Entity()
    private let foreL = Entity(), foreR = Entity()
    private var jets: [(entity: ModelEntity, axis: Int, sign: Float)] = []
    private var pose = SuitPose()
    private var phase: Float = 0
    private var clock: Float = 0
    private var firstFrame = true

    private static let hipY: Float = 0.93
    private static let packCenter = F3(0, 1.22, 0.22)
    private static let packHalf = F3(0.17, 0.25, 0.09)

    init() {
        func part(_ mesh: MeshResource, _ mat: any Material, _ p: F3, scale: F3 = .one) -> ModelEntity {
            let e = ModelEntity(mesh: mesh, materials: [mat])
            e.position = p
            e.scale = scale
            return e
        }
        let hy = Self.hipY
        root.addChild(upper)
        upper.position = F3(0, hy, 0)
        // Торс и голова (позиции относительно бёдер).
        upper.addChild(part(.generateBox(size: F3(0.42, 0.55, 0.26), cornerRadius: 0.06), SuitKit.white, F3(0, 1.20 - hy, 0)))
        upper.addChild(part(.generateBox(size: F3(0.30, 0.18, 0.04), cornerRadius: 0.02), SuitKit.grey, F3(0, 1.28 - hy, -0.135)))
        upper.addChild(part(.generateBox(size: F3(0.44, 0.10, 0.28), cornerRadius: 0.04), SuitKit.grey, F3(0, 0.97 - hy, 0)))
        upper.addChild(part(.generateCylinder(height: 0.06, radius: 0.09), SuitKit.grey, F3(0, 1.50 - hy, 0)))
        upper.addChild(part(.generateSphere(radius: 0.17), SuitKit.white, F3(0, 1.64 - hy, 0)))
        upper.addChild(part(.generateSphere(radius: 0.125), SuitKit.gold, F3(0, 1.645 - hy, -0.075), scale: F3(1.05, 0.85, 0.7)))
        // Ранец.
        let pc = Self.packCenter
        upper.addChild(part(.generateBox(size: F3(0.34, 0.50, 0.18), cornerRadius: 0.04), SuitKit.grey, F3(pc.x, pc.y - hy, pc.z)))
        upper.addChild(part(.generateCylinder(height: 0.34, radius: 0.045), SuitKit.orange, F3(-0.10, 1.22 - hy, 0.33)))
        upper.addChild(part(.generateCylinder(height: 0.34, radius: 0.045), SuitKit.orange, F3(0.10, 1.22 - hy, 0.33)))
        // Руки: плечо — шарнир, предплечье — вложенный шарнир.
        for (arm, fore, sx) in [(armL, foreL, Float(-1)), (armR, foreR, Float(1))] {
            arm.position = F3(sx * 0.27, 1.40 - hy, 0)
            upper.addChild(arm)
            arm.addChild(part(.generateBox(size: F3(0.11, 0.30, 0.11), cornerRadius: 0.04), SuitKit.white, F3(0, -0.15, 0)))
            arm.addChild(part(.generateSphere(radius: 0.065), SuitKit.grey, F3(0, 0, 0)))
            fore.position = F3(0, -0.30, 0)
            arm.addChild(fore)
            fore.addChild(part(.generateBox(size: F3(0.10, 0.26, 0.10), cornerRadius: 0.04), SuitKit.white, F3(0, -0.13, 0)))
            fore.addChild(part(.generateSphere(radius: 0.07), SuitKit.dark, F3(0, -0.30, 0)))
        }
        // Ноги: бедро — шарнир в бедре, голень — в колене, ботинок.
        for (leg, shin, sx) in [(legL, shinL, Float(-1)), (legR, shinR, Float(1))] {
            leg.position = F3(sx * 0.10, hy, 0)
            root.addChild(leg)
            leg.addChild(part(.generateBox(size: F3(0.16, 0.46, 0.17), cornerRadius: 0.05), SuitKit.white, F3(0, -0.22, 0)))
            shin.position = F3(0, -0.45, 0)
            leg.addChild(shin)
            shin.addChild(part(.generateBox(size: F3(0.14, 0.38, 0.15), cornerRadius: 0.05), SuitKit.white, F3(0, -0.19, 0)))
            shin.addChild(part(.generateBox(size: F3(0.16, 0.10, 0.27), cornerRadius: 0.035), SuitKit.dark, F3(0, -0.43, -0.04)))
        }
        // Струйки ранца: по два конуса на ось (тяга вдоль ±ось, выхлоп противоположно).
        for axis in 0..<3 {
            for sign in [Float(-1), 1] {
                let j = ModelEntity(mesh: SuitKit.jetMesh, materials: [SuitKit.jet])
                j.isEnabled = false
                root.addChild(j)
                jets.append((j, axis, sign))
            }
        }
    }

    /// Положение/поворот и анимация. `rel` — центр модели относительно камеры (Double → Float здесь).
    func update(_ c: CosmonautState, rel: D3, dt: Double) {
        root.transform = Transform(scale: .one, rotation: quatf(c.attitude.quatd), translation: f3(rel))
        let d = Float(clampd(dt, 0, 0.1))
        clock += d
        let speed = Float(c.surfaceSpeed)
        var target = SuitPose()
        let injured = c.health == .injured
        if let g = c.grip {
            if let along = g.along {
                // Лестница: один шаг на ступень (~0.3 м); руки и ноги попеременно, фаза — по высоте.
                let a = Float(along) / 0.3 * .pi
                let sn = sin(a), cs = cos(a)
                target.armL = 2.35 + 0.35 * sn
                target.armR = 2.35 - 0.35 * sn
                target.elbow = 0.45 + 0.25 * max(0, cs)
                target.thighL = 0.55 + 0.45 * max(0, -sn)
                target.thighR = 0.55 + 0.45 * max(0, sn)
                target.kneeL = -0.7 - 0.5 * max(0, -sn)
                target.kneeR = -0.7 - 0.5 * max(0, sn)
                target.lean = 0.05
            } else {
                // Поручни: обе руки на рамке вперёд-вверх, ноги свободно покачиваются.
                let drift = sin(clock * 0.7) * 0.08
                target.armL = 2.0; target.armR = 2.0
                target.elbow = 0.7
                target.thighL = 0.3 + drift; target.thighR = 0.15 - drift
                target.kneeL = -0.5; target.kneeR = -0.3
                target.lean = 0.08
            }
            if injured { target.roll = 0.05 }
        } else if c.onGround {
            let amp = min(1, speed / 2.0) * 0.55
            if speed > 0.15 { phase += d * (2.5 + speed * 1.2) }
            let s = sin(phase), co = cos(phase)
            let ampR = injured ? amp * 0.5 : amp
            target.thighL = amp * s
            target.thighR = -ampR * s
            target.kneeL = -amp * max(0, co)
            target.kneeR = -ampR * max(0, -co)
            target.armL = -0.6 * target.thighL + 0.05
            target.armR = -0.6 * target.thighR + 0.05
            target.elbow = 0.25 + 0.4 * amp
            target.lean = 0.03 + 0.10 * min(1, speed / 2.0)
            if injured {
                target.roll = 0.08 * min(1, 0.4 + speed)
                target.drop = 0.03
            }
        } else {
            // Полёт/прыжок/орбита: ноги чуть согнуты, руки вперёд, медленный дрейф.
            let drift = sin(clock * 0.6) * 0.08
            target.thighL = 0.35 + drift
            target.thighR = 0.15 - drift
            target.kneeL = -0.55
            target.kneeR = -0.35
            target.armL = 0.35 - drift
            target.armR = 0.35 + drift
            target.elbow = 0.5
            target.lean = 0.12
            if injured { target.roll = 0.06 }
        }
        if firstFrame { pose = target; firstFrame = false }
        pose.blend(to: target, k: 1 - exp(-d * 10))

        upper.orientation = simd_quatf(angle: -pose.lean, axis: F3(1, 0, 0)) * simd_quatf(angle: pose.roll, axis: F3(0, 0, 1))
        upper.position = F3(0, Self.hipY - pose.drop, 0)
        func rx(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: F3(1, 0, 0)) }
        legL.orientation = rx(pose.thighL); legR.orientation = rx(pose.thighR)
        shinL.orientation = rx(pose.kneeL); shinR.orientation = rx(pose.kneeR)
        armL.orientation = rx(pose.armL); armR.orientation = rx(pose.armR)
        foreL.orientation = rx(pose.elbow); foreR.orientation = rx(pose.elbow)

        // Струйки: тяга по команде в осях скафандра, выхлоп в обратную сторону.
        let f = F3(Float(c.jetpackFiring.x), Float(c.jetpackFiring.y), Float(c.jetpackFiring.z))
        let pc = Self.packCenter, half = Self.packHalf
        for j in jets {
            let mag = f[j.axis] * j.sign
            if mag <= 0.05 || !c.jetpackOn {
                if j.entity.isEnabled { j.entity.isEnabled = false }
                continue
            }
            var e = F3.zero
            e[j.axis] = -j.sign
            let m = min(1, mag)
            var p = pc + F3(e.x * half.x, e.y * half.y, e.z * half.z)
            // Выхлоп к лицу (тяга назад): сопло сбоку ранца, чтобы не прятаться в торсе.
            if j.axis == 2 && j.sign > 0 { p = F3(0.30, 1.15, 0.10) }
            let len = (0.18 + 0.55 * m) * (0.9 + 0.1 * sin(clock * 60 + Float(j.axis)))
            j.entity.transform = Transform(scale: F3(0.7 + 0.5 * m, len, 0.7 + 0.5 * m),
                                           rotation: simd_quatf(from: F3(0, 1, 0), to: e), translation: p)
            if !j.entity.isEnabled { j.entity.isEnabled = true }
        }
    }
}

/// Подсветка люка: зелёное пунктирное кольцо ~0.6 м в плоскости люка (нормаль задаётся ориентацией: +Z кольца).
@MainActor
final class HatchHighlight {
    let root = Entity()
    private var segments: [ModelEntity] = []
    private var bright: Bool?
    private static let dim = UnlitMaterial(color: UIColor(red: 0.27, green: 0.49, blue: 0.30, alpha: 1))
    private static let lit = UnlitMaterial(color: UIColor(red: 0.486, green: 0.89, blue: 0.545, alpha: 1))

    init() {
        let n = 16
        let radius: Float = 0.30
        let mesh = MeshResource.generateBox(size: F3(0.075, 0.018, 0.012))
        for k in 0..<n {
            let a = Float(k) / Float(n) * 2 * .pi
            let e = ModelEntity(mesh: mesh, materials: [Self.dim])
            // Сегмент касателен к окружности: длинная сторона вдоль касательной.
            e.transform = Transform(scale: .one, rotation: simd_quatf(angle: a + .pi / 2, axis: F3(0, 0, 1)),
                                    translation: F3(cos(a) * radius, sin(a) * radius, 0))
            root.addChild(e)
            segments.append(e)
        }
        root.isEnabled = false
    }

    /// `rel` — центр кольца относительно камеры, `orientation` — поворот корабля.
    func update(rel: D3, orientation: simd_quatd, canBoard: Bool, time: Float) {
        if bright != canBoard {
            bright = canBoard
            for s in segments { s.model?.materials = [canBoard ? Self.lit : Self.dim] }
        }
        let pulse: Float = canBoard ? 1 + 0.08 * sin(time * 6) : 1
        let spin = simd_quatf(angle: time * (canBoard ? 0.8 : 0.25), axis: F3(0, 0, 1))
        root.transform = Transform(scale: F3(repeating: pulse), rotation: quatf(orientation) * spin, translation: f3(rel))
        if !root.isEnabled { root.isEnabled = true }
    }

    func hide() { if root.isEnabled { root.isEnabled = false } }
}
