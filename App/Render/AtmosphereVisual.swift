import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Атмосфера Терры: дымка у горизонта (вложенные цилиндрические пояса вокруг камеры)
/// и голубой ореол лимба. Ореол — набор колец за диском планеты с градиентной альфа-текстурой
/// («колпак» 0→1→0 по ширине), соседние кольца перекрываются и дают плавный спад от края вверх.
/// Работает на любой высоте от ~2.5 км (с земли — полоса над горизонтом, из космоса — тонкий ободок),
/// гаснет ночью. Старые диски ореола выключены (`haloDiscsEnabled`).
@MainActor
final class AtmosphereVisual {
    /// Выключатель для поиска причин падений.
    static var enabled = true
    /// Старый ореол из плоских дисков; заменён кольцами лимба.
    static var haloDiscsEnabled = false

    let root = Entity()

    // Лимб: кольца в плоскости, перпендикулярной направлению на центр планеты.
    private static let limbCount = 8
    private static let limbHeight = 42_000.0
    private let limbRoot = Entity()
    private var rings: [ModelEntity] = []
    private var lastLimbKey = -1

    // Дымка: пояса (полуугол над горизонтом, множитель радиуса).
    private static let hazeAngles: [Float] = [1.5, 3.5, 6, 9.5, 14]
    private static let hazeMults: [Float] = [1.0, 1.4, 2.0, 2.8, 4.0]
    private let hazeRoot = Entity()
    private var tubes: [ModelEntity] = []
    private var lastHazeKey = -1

    // Ореол: диски от внутреннего к внешнему краю (доли толщины атмосферы).
    private static let haloWeights: [Double] = [0.15, 0.3, 0.5, 0.7, 0.85, 1.0]
    /// Видимая толщина ореола, м (атмосфера 70 км с запасом).
    private static let haloThickness = 85_000.0
    private let haloRoot = Entity()
    private var discs: [ModelEntity] = []
    private var lastHaloKey = -1

    init() {
        root.addChild(hazeRoot)
        root.addChild(haloRoot)
        root.addChild(limbRoot)
        if let mesh = SoftMeshes.limbRing {
            for _ in 0..<Self.limbCount {
                let e = ModelEntity(mesh: mesh, materials: [Self.material(rgb: F3(0.4, 0.65, 1), opacity: 0.1)])
                limbRoot.addChild(e)
                rings.append(e)
            }
        }
        limbRoot.isEnabled = false
        SoftTextures.shared.start()

        // Единичный открытый цилиндр (радиус 1, полувысота 1), видимый изнутри (двусторонний).
        var tube = MeshBuilder()
        tube.lathe([SIMD2<Float>(1, 1), SIMD2<Float>(1, -1)], segments: 48, twoSided: true)
        if let mesh = tube.makeMesh(name: "hazeTube") {
            for _ in Self.hazeAngles {
                let e = ModelEntity(mesh: mesh, materials: [Self.material(rgb: F3(0.74, 0.84, 0.95), opacity: 0.1)])
                hazeRoot.addChild(e)
                tubes.append(e)
            }
        }

        // Единичный диск лицом +Z.
        var disc = MeshBuilder()
        disc.disc(radius: 1, segments: 64)
        if let mesh = disc.makeMesh(name: "haloDisc") {
            for _ in Self.haloWeights {
                let e = ModelEntity(mesh: mesh, materials: [Self.material(rgb: F3(0.38, 0.62, 1.0), opacity: 0.1)])
                haloRoot.addChild(e)
                discs.append(e)
            }
        }
        hazeRoot.isEnabled = false
        haloRoot.isEnabled = false
    }

    func reset() {
        hazeRoot.isEnabled = false
        haloRoot.isEnabled = false
        limbRoot.isEnabled = false
        lastHazeKey = -1
        lastHaloKey = -1
        lastLimbKey = -1
    }

    func update(_ f: AtmosphereFrame) {
        guard Self.enabled else {
            reset()
            return
        }
        updateHaze(f)
        if Self.haloDiscsEnabled {
            updateHalo(f)
        } else {
            haloRoot.isEnabled = false
        }
        updateLimb(f)
    }

    // MARK: - Лимб

    private func updateLimb(_ f: AtmosphereFrame) {
        let tex = SoftTextures.shared
        let n = Self.limbCount
        let scale = f.terraScale
        let c = f.terraCenter * scale
        let d = simd_length(c)
        let rs = Bodies.terra.radius * scale
        let altFade = Self.smooth((f.altitude - 2_500) / 10_000)
        guard tex.isReady, let hat = tex.hat, rings.count == n, altFade > 0.01, d > rs * 1.0005 else {
            limbRoot.isEnabled = false
            return
        }
        // Касательная до планеты, угловой радиус диска, толщина слоя атмосферы в углах.
        let t = (d * d - rs * rs).squareRoot()
        let thetaR = asin(min(rs / d, 0.9999))
        let delta = clampd(Self.limbHeight * scale / t, 0.01, 0.2)
        let x0 = tan(thetaR)
        // Предел ширины: шаг между кольцами не больше полуширины колпака (иначе щели).
        let x1 = min(tan(min(thetaR + delta, 1.5)), x0 * (1 + 0.13 * Double(n - 1)))
        let spacing = (x1 / x0 - 1) / Double(n - 1)
        guard spacing > 1e-4 else {
            limbRoot.isEnabled = false
            return
        }
        limbRoot.isEnabled = true

        // Освещённость: камера над дневной стороной ярче; ночью гаснет.
        let a = c / d
        let phase = simd_dot(f.sun, -a)
        let lit = clampd(0.08 + 0.92 * (phase + 0.3) / 1.1, 0.03, 1)
        let norm = clampd(spacing / 0.177, 0.05, 1)
        let key = Int((altFade * 20).rounded()) * 10_000 + Int((lit * 20).rounded()) * 100 + Int((norm * 10).rounded())
        if key != lastLimbKey {
            lastLimbKey = key
            let k = CGFloat(0.55 + 0.45 * lit)
            let tint = UIColor(red: 0.42 * k, green: 0.68 * k, blue: 1.0 * k, alpha: 1)
            let base = Float(0.6 * lit * altFade * norm)
            for (i, e) in rings.enumerated() {
                let fall = pow(1 - Float(i) / Float(n), 1.7)
                e.model?.materials = [SoftTextures.material(hat, tint: tint, opacity: base * fall)]
            }
        }

        // Плоскость колец — чуть дальше касательной точки, чтобы планета закрывала внутреннюю часть.
        let dp = t * 1.06
        let dirF = f3(a)
        let q = simd_quatf(from: F3(0, 0, 1), to: -dirF)
        for (i, e) in rings.enumerated() {
            // Пик колпака (0.85 внешнего радиуса) — на радиусе x0·(1 + spacing·i).
            // Кольца не в одной плоскости: иначе z-конфликт даёт зубчатые клинья. Дальние — крупнее
            // в той же пропорции, угловой размер прежний; порядок прозрачных — от дальнего к ближнему.
            let depth = dp * (1 + 0.004 * Double(n - 1 - i))
            let peak = x0 * (1 + spacing * Double(i))
            let ro = Float(depth * peak / 0.85)
            e.position = dirF * Float(depth)
            e.orientation = q
            e.scale = F3(ro, ro, 1)
        }
    }

    private static func material(rgb: F3, opacity: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1))
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return m
    }

    private static func smooth(_ x: Double) -> Double {
        let t = clampd(x, 0, 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Дымка

    private func updateHaze(_ f: AtmosphereFrame) {
        let alt = f.altitude
        let b = clampd(f.skyBrightness, 0, 1)
        let fade = Self.smooth(1 - alt / 50_000) * clampd(b * 1.5, 0, 1)
        guard f.frameBody == .terra, alt < 70_000, fade > 0.01, tubes.count == Self.hazeAngles.count else {
            hazeRoot.isEnabled = false
            return
        }
        hazeRoot.isEnabled = true
        hazeRoot.orientation = simd_quatf(from: F3(0, 1, 0), to: f3(f.up))

        // Материалы — только при заметном изменении (шаг ~0.03).
        let key = Int((fade * 33).rounded()) * 1_000 + Int((b * 33).rounded())
        if key != lastHazeKey {
            lastHazeKey = key
            let c = Palette.sample(Palette.skyRow, 0.5)
            let k = Float(0.25 + 0.75 * b)
            let rgb = F3(Float(c.x), Float(c.y), Float(c.z)) * k
            let m = Self.material(rgb: rgb, opacity: Float(0.14 * fade))
            for t in tubes { t.model?.materials = [m] }
        }

        // Радиусы растут с высотой, но меньше дальности горизонта.
        let planetR = Bodies.terra.radius
        let horizon = (2 * planetR * max(alt, 200)).squareRoot()
        let base = 3_000 + alt * 0.35
        let dip = acos(planetR / (planetR + max(alt, 0)))
        for (i, t) in tubes.enumerated() {
            let r = clampd(base * Double(Self.hazeMults[i]), 3_000, max(4_000, 2.2 * horizon))
            let half = r * tan(Double(Self.hazeAngles[i]) * Double.pi / 180)
            let yoff = -r * tan(dip)
            t.position = F3(0, Float(yoff), 0)
            t.scale = F3(Float(r), Float(half), Float(r))
        }
    }

    // MARK: - Ореол

    private func updateHalo(_ f: AtmosphereFrame) {
        let scale = f.terraScale
        let c = f.terraCenter * scale
        let d = simd_length(c)
        let rs = Bodies.terra.radius * scale
        let h = Self.haloThickness * scale
        let altFade = Self.smooth((f.altitude - 20_000) / 60_000)
        guard discs.count == Self.haloWeights.count, d > (rs + h) * 1.02, altFade > 0.01, d > 1 else {
            haloRoot.isEnabled = false
            return
        }
        let u = c / d
        // Плоскость касания: d − R²/d; диски кладём чуть за ней (закрыты диском планеты).
        let d0 = d - rs * rs / d + 0.01 * rs
        let thetaR = asin(min(rs / d, 0.999))
        let thetaH = asin(min((rs + h) / d, 0.999))
        guard d0 < 3.0e6, thetaH - thetaR > 0.002 else {
            haloRoot.isEnabled = false
            return
        }
        haloRoot.isEnabled = true

        // Освещённость: камера над дневной стороной — ярче.
        let phase = simd_dot(f.sun, -u)
        let lit = clampd(0.3 + 0.7 * (phase + 0.25) / 1.1, 0.05, 1)
        let key = Int((altFade * 33).rounded()) * 1_000 + Int((lit * 33).rounded())
        if key != lastHaloKey {
            lastHaloKey = key
            let k = Float(0.35 + 0.65 * lit)
            let m = Self.material(rgb: F3(0.38, 0.62, 1.0) * k, opacity: Float(0.12 * lit * altFade))
            for e in discs { e.model?.materials = [m] }
        }

        let dirF = f3(u)
        let q = simd_quatf(from: F3(0, 0, 1), to: -dirF)
        for (i, e) in discs.enumerated() {
            let di = d0 + 0.002 * rs * Double(i)
            let theta = asin(min((rs + Self.haloWeights[i] * h) / d, 0.999))
            let r = di * tan(theta)
            e.position = dirF * Float(di)
            e.orientation = q
            e.scale = F3(Float(r), Float(r), 1)
        }
    }
}
