import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Облака Терры на высотах 2–12 км: детерминированная сетка в системе, связанной с Террой,
/// кластеры мягких биллбордов (процедурная радиальная альфа-текстура) из пула сущностей;
/// высокие слоистые — широкие плоские пятна. Внутри комка экран мутнеет (сфера-«туман» у камеры).
@MainActor
final class CloudVisual {
    /// Выключатель для поиска причин падений.
    static var enabled = true

    let root = Entity()

    private static let poolSize = 160
    private static let cellSize = 3_000.0
    private static let viewRadius = 28_000.0
    private static let rebuildDistance = 1_500.0

    /// Один мягкий клуб: центр и вертикаль в связанной с Террой системе, полуширина и полувысота.
    /// `tone` — 0…2 оттенок (верх клуба светлее, низ серее), 3 — тонкая слоистая дымка.
    private struct Puff {
        var pos: D3
        var up: D3
        var rx: Double
        var ry: Double
        var tone: Int
    }

    /// Облачная ячейка-кандидат (центр в связанной системе, высота, состояние генератора).
    private struct Candidate {
        var dist: Double
        var center: D3
        var altitude: Double
        var state: UInt64
    }

    private var pool: [ModelEntity] = []
    private var puffs: [Puff] = []
    private var candidates: [Candidate] = []
    private var shownCount = 0
    private var lastBuildPos: D3?
    private var lastQuality = -1
    private var effectiveRadius = CloudVisual.viewRadius

    private var materials: [UnlitMaterial] = []
    private var texturesReady = false
    private var lastLightKey = -1

    private let fog = ModelEntity()
    private var fogLevel = 0.0
    private var lastFogKey = -1

    init() {
        SoftTextures.shared.start()
        puffs.reserveCapacity(Self.poolSize)
        candidates.reserveCapacity(2_048)

        let quad = SoftMeshes.billboard ?? MeshResource.generateBox(size: 1)
        for _ in 0..<Self.poolSize {
            let e = ModelEntity(mesh: quad, materials: [Self.fogMaterial(opacity: 0.5, shade: 1)])
            e.isEnabled = false
            root.addChild(e)
            pool.append(e)
        }

        // Сфера вокруг камеры, видимая изнутри (двусторонняя).
        var b = MeshBuilder()
        var profile: [SIMD2<Float>] = []
        for i in 0...12 {
            let a = Float.pi * Float(i) / 12
            profile.append(SIMD2<Float>(3 * sin(a), -3 * cos(a)))
        }
        b.lathe(profile, segments: 16, twoSided: true)
        if let mesh = b.makeMesh(name: "cloudFog") {
            fog.model = ModelComponent(mesh: mesh, materials: [Self.fogMaterial(opacity: 0.1, shade: 1)])
        }
        fog.isEnabled = false
        root.addChild(fog)
        root.isEnabled = false
    }

    func reset() {
        root.isEnabled = false
        for e in pool { e.isEnabled = false }
        shownCount = 0
        puffs.removeAll(keepingCapacity: true)
        lastBuildPos = nil
        lastQuality = -1
        lastLightKey = -1
        lastFogKey = -1
        fogLevel = 0
        fog.isEnabled = false
        texturesReady = false
    }

    // MARK: - Материалы

    /// Четыре материала: три оттенка плотного клуба и тонкая дымка. Ночью темнее (`shade`).
    private static func cloudMaterials(tex: TextureResource, shade: Float) -> [UnlitMaterial] {
        let tones: [(Float, Float)] = [(1.0, 0.85), (0.88, 0.85), (0.76, 0.8), (0.95, 0.5)]
        return tones.map { tone, opacity in
            let c = CGFloat(0.97 * shade * tone)
            return SoftTextures.material(tex, tint: UIColor(red: c, green: c, blue: min(1, c * 1.03), alpha: 1), opacity: opacity)
        }
    }

    private static func fogMaterial(opacity: Float, shade: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: UIColor(white: CGFloat(0.9 * shade), alpha: 1))
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return m
    }

    // MARK: - Генератор

    private struct Rng {
        var s: UInt64
        mutating func next() -> Double {
            s = CloudVisual.mix(s)
            return Double(s >> 11) / 9_007_199_254_740_992
        }
    }

    nonisolated private static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    nonisolated private static func cellSeed(_ x: Int64, _ y: Int64, _ z: Int64) -> UInt64 {
        var h = mix(UInt64(bitPattern: x))
        h = mix(h ^ UInt64(bitPattern: y))
        h = mix(h ^ UInt64(bitPattern: z))
        return h
    }

    /// Собирает кандидатов вокруг камеры и раскладывает ближайшие облака по пулу.
    private func rebuild(camBF: D3, capacity: Int) {
        let size = Self.cellSize
        let rv = Self.viewRadius
        let planetR = Bodies.terra.radius
        let lo = (planetR + 300) * (planetR + 300)
        let hi = (planetR + 13_700) * (planetR + 13_700)
        candidates.removeAll(keepingCapacity: true)

        let x0 = Int64(((camBF.x - rv) / size).rounded(.down)), x1 = Int64(((camBF.x + rv) / size).rounded(.down))
        let y0 = Int64(((camBF.y - rv) / size).rounded(.down)), y1 = Int64(((camBF.y + rv) / size).rounded(.down))
        let z0 = Int64(((camBF.z - rv) / size).rounded(.down)), z1 = Int64(((camBF.z + rv) / size).rounded(.down))
        for ix in x0...x1 {
            for iy in y0...y1 {
                for iz in z0...z1 {
                    let center = D3((Double(ix) + 0.5) * size, (Double(iy) + 0.5) * size, (Double(iz) + 0.5) * size)
                    let r2 = simd_length_squared(center)
                    guard r2 > lo, r2 < hi else { continue }
                    let dist = simd_length(center - camBF)
                    guard dist < rv else { continue }
                    var rng = Rng(s: Self.cellSeed(ix, iy, iz))
                    let alt = r2.squareRoot() - planetR + (rng.next() - 0.5) * size
                    guard alt >= 2_000, alt <= 12_000 else { continue }
                    // Больше кучевых низко и слоистых высоко, меньше посередине.
                    let p = alt < 4_500 ? 0.42 : (alt < 8_000 ? 0.14 : 0.3)
                    guard rng.next() < p else { continue }
                    candidates.append(Candidate(dist: dist, center: center, altitude: alt, state: rng.s))
                }
            }
        }
        candidates.sort { $0.dist < $1.dist }

        puffs.removeAll(keepingCapacity: true)
        var lastDist = rv
        var full = false
        for c in candidates {
            var rng = Rng(s: c.state)
            let jitter = D3(rng.next() - 0.5, rng.next() - 0.5, rng.next() - 0.5) * size * 0.8
            let dir = simd_normalize(c.center + jitter)
            let t1 = perpendicular(D3(0, 0, 1), to: dir)
            let t2 = simd_cross(dir, t1)
            let base = dir * (planetR + c.altitude)

            let count: Int
            let spread: Double
            if c.altitude < 5_000 {
                count = 4 + Int(rng.next() * 3)
                spread = 700
            } else if c.altitude > 8_000 {
                count = 3
                spread = 1_600
            } else {
                count = 3
                spread = 1_000
            }
            if puffs.count + count > capacity {
                full = true
                break
            }
            for _ in 0..<count {
                let o1 = (rng.next() - 0.5) * 2 * spread
                let o2 = (rng.next() - 0.5) * 2 * spread
                let rise = rng.next()
                let rx: Double
                let ry: Double
                var tone = 0
                var lift = rise * 350
                if c.altitude < 5_000 {
                    // Кучевые: шапка из клубов, верхние светлее.
                    rx = 380 + rng.next() * 420
                    ry = rx * (0.62 + rng.next() * 0.2)
                    tone = rise > 0.66 ? 0 : (rise > 0.33 ? 1 : 2)
                    lift = rise * 450
                } else if c.altitude > 8_000 {
                    // Высокие слоистые: широкие плоские мягкие пятна.
                    rx = 1_800 + rng.next() * 1_300
                    ry = rx * (0.08 + rng.next() * 0.06)
                    tone = 3
                    lift = rise * 150
                } else {
                    rx = 800 + rng.next() * 700
                    ry = rx * (0.28 + rng.next() * 0.14)
                    tone = rise > 0.5 ? 1 : 2
                }
                let pos = base + t1 * o1 + t2 * o2 + dir * lift
                puffs.append(Puff(pos: pos, up: dir, rx: rx, ry: ry, tone: tone))
            }
            lastDist = c.dist
        }
        effectiveRadius = full ? max(lastDist, 8_000) : Self.viewRadius

        applyMaterials()
    }

    private func applyMaterials() {
        guard materials.count == 4 else { return }
        for (i, e) in pool.enumerated() where i < puffs.count {
            e.model?.materials = [materials[puffs[i].tone]]
        }
    }

    // MARK: - Кадр

    func update(_ f: AtmosphereFrame) {
        guard Self.enabled, f.frameBody == .terra, abs(f.terraScale - 1) < 1e-6, f.altitude < 40_000,
              let tex = SoftTextures.shared.puff, SoftTextures.shared.isReady else {
            if root.isEnabled { reset() }
            return
        }
        if !texturesReady {
            texturesReady = true
            lastLightKey = -1
            lastBuildPos = nil
        }
        root.isEnabled = true
        let rot = f.terraRotation
        let camBF = rot.inverse.act(-f.terraCenter)
        let capacity = f.quality <= 0 ? 40 : (f.quality == 1 ? 90 : Self.poolSize)

        // Материалы: ночью темнее (шаг ~0.03 по яркости).
        let b = clampd(f.skyBrightness, 0, 1)
        let lightKey = Int((b * 33).rounded())
        if lightKey != lastLightKey {
            lastLightKey = lightKey
            let shade = Float(0.14 + 0.86 * b)
            materials = Self.cloudMaterials(tex: tex, shade: shade)
            applyMaterials()
            lastFogKey = -1
        }

        if lastBuildPos == nil || f.quality != lastQuality || simd_length(camBF - (lastBuildPos ?? camBF)) > Self.rebuildDistance {
            lastBuildPos = camBF
            lastQuality = f.quality
            rebuild(camBF: camBF, capacity: capacity)
        }

        // Расстановка пула и поиск комка, внутри которого камера.
        let n = puffs.count
        var inside = 0.0
        let fadeSpan = effectiveRadius * 0.25
        for i in 0..<n {
            let p = puffs[i]
            let rel = f3(f.terraCenter + rot.act(p.pos))
            let dist = Double(simd_length(rel))
            let fade = clampd((effectiveRadius - dist) / fadeSpan, 0, 1)
            let e = pool[i]
            e.isEnabled = fade > 0.01
            e.position = rel
            // Биллборд к камере, вертикаль — вдоль местной «вверх»: слоистые остаются горизонтальными пятнами.
            e.orientation = SoftMeshes.facing(position: rel, up: f3(rot.act(p.up)))
            e.scale = F3(Float(p.rx * 2 * fade), Float(p.ry * 2 * fade), 1)

            // Камера внутри эллипсоида (в связанной системе).
            let d = camBF - p.pos
            let y = simd_dot(d, p.up)
            let h2 = max(0, simd_length_squared(d) - y * y)
            let m = h2 / (p.rx * p.rx) + y * y / (p.ry * p.ry)
            if m < 1 { inside = max(inside, clampd((1 - m.squareRoot()) * 2.5, 0, 1)) }
        }
        if n < shownCount {
            for i in n..<shownCount { pool[i].isEnabled = false }
        }
        shownCount = n

        // Туман внутри облака: плавное нарастание и спад.
        fogLevel += (inside - fogLevel) * min(1, f.dt * 5)
        if fogLevel < 0.02 {
            fog.isEnabled = false
        } else {
            fog.isEnabled = true
            let key = Int((fogLevel * 25).rounded())
            if key != lastFogKey {
                lastFogKey = key
                let shade = Float(0.14 + 0.86 * b)
                fog.model?.materials = [Self.fogMaterial(opacity: Float(0.75 * fogLevel), shade: shade)]
            }
        }
    }
}
