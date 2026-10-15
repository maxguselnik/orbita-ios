import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Кусок персонажа одной сущностью: геометрия по материалам (`CrewMat`), меш кэшируется по ключу.
struct CrewPiece {
    var batch = MeshBatch()
    var specs: [CrewMat] = []

    mutating func add(_ b: MeshBuilder, _ m: float4x4? = nil, _ s: CrewMat) {
        let i: Int
        if let k = specs.firstIndex(of: s) {
            i = k
        } else {
            specs.append(s)
            i = specs.count - 1
        }
        batch.add(b, m, mat: i)
    }
}

/// Кэш кусков: меш и список материалов на ключ (общие для всех слотов и вьюх).
@MainActor
enum CrewPieces {
    private static var built: [String: (mesh: MeshResource, specs: [CrewMat])] = [:]

    static func entity(_ key: String, _ make: () -> CrewPiece) -> ModelEntity {
        let a = CrewAssets.shared
        if let b = built[key] {
            return ModelEntity(mesh: b.mesh, materials: b.specs.map { a.material($0) })
        }
        let p = make()
        guard let mesh = p.batch.makeMesh(name: key) else { return ModelEntity() }
        built[key] = (mesh, p.specs)
        return ModelEntity(mesh: mesh, materials: p.specs.map { a.material($0) })
    }
}

/// Портрет одного места в ряду (`buildCharacter` + `animate` макета): персонаж в скафандре и шлеме, его кабина,
/// эффекты настроения. Пространство — координаты макета (голова в нуле, камера спереди по +Z).
@MainActor
final class CrewCharacter {
    let root = Entity()
    let member: CrewMember
    private let look: CrewLook
    private let seed: Double
    private let cellWidth: Float

    // Скелет: тело (сдвиг, часть крена) → верх (полный крен) → голова → лицо (масштаб).
    private let body = Entity()
    private let upper = Entity()
    private let headG = Entity()
    private let face = Entity()

    private struct Eye {
        let sd: Float, r: Float
        let g: Entity, ball: Entity, pupil: ModelEntity
        let glint: Entity, glint2: Entity, upperLid: Entity, lowerLid: Entity, arc: Entity, tear: Entity
    }
    private var eyes: [Eye] = []
    private var pupilKey: [Int] = [-1, -1]
    private var brows: [(g: Entity, m: Entity, sd: Float)] = []
    private var wrinkles: [Entity] = []
    private var nostrils: [(e: Entity, base: F3)] = []
    private let mouth = ModelEntity()
    private var mouthMesh: MeshResource?
    private var goshaTeeth: [Entity] = []
    private let tongueOut = Entity()
    private var blush: [ModelEntity] = []
    private var blushLevel = -1
    private let soot = Entity()
    private var sweat: [Entity] = []
    private var sway: [(e: Entity, amp: Float, fast: Bool)] = []
    private let crack = Entity()
    private var stars: [Entity] = []
    private var smoke: [ModelEntity] = []
    private var smokeLevels: [Int] = [-1, -1, -1]
    private var buttons: [ModelEntity] = []
    private var buttonState = -1
    private let heat = PointLight()

    // Кабина и настроение.
    private var cabin: CrewCabin?
    private(set) var mood: CrewMood = .calm
    private var intensity = 0.0
    private var from = CrewFace.base(.calm)
    private var target = CrewFace.base(.calm)
    private var moodStart = -10.0
    private var current = CrewFace.base(.calm)

    static let head: Float = 1.22

    init(member: CrewMember, seed: Double, cellWidth: Float) {
        self.member = member
        self.look = CrewLook.of(member.id)
        self.seed = seed
        self.cellWidth = cellWidth
        build()
    }

    /// Новое настроение: плавный переход параметров ~0.3 с (кабина — сразу).
    func set(mood: CrewMood, intensity: Double, time t: Double, animated: Bool) {
        var next = CrewFace.expr(mood, brave: member.bravery, silly: member.silliness)
        next.shake *= 0.3 + 0.7 * min(1, max(0, intensity))
        if cabin != nil && mood == self.mood && intensity == self.intensity { return }
        from = animated ? current : next
        target = next
        moodStart = t
        if cabin == nil || mood != self.mood {
            cabin?.root.removeFromParent()
            let c = CrewCabin(mood: mood, cellWidth: cellWidth)
            root.addChild(c.root)
            cabin = c
        }
        self.mood = mood
        self.intensity = intensity
        if !animated { current = next }
    }

    // MARK: - Сборка

    private var S: CrewShape { look.shape }

    private func placed(_ x: Float, _ y: Float, _ lift: Float = 0) -> float4x4 {
        let p = S.place(x, y, lift: lift)
        return crewMatrix(p.p, p.q)
    }

    private func setPlaced(_ e: Entity, _ x: Float, _ y: Float, _ lift: Float) {
        let p = S.place(x, y, lift: lift)
        e.transform = Transform(scale: e.scale, rotation: p.q, translation: p.p)
    }

    private var skin: CrewMat { CrewMat(color: look.skin.hex, rough: 0.6, coat: 0.1, coatRough: 0.7, emissive: 0x5a1a10, glow: 0.12) }
    private var hairM: CrewMat { CrewMat(color: look.hair.hex, rough: 0.5, metal: 0.05, tex: "hairTube") }
    private var hairCapM: CrewMat { CrewMat(color: look.hair.hex, rough: 0.5, metal: 0.05, tex: "hairCap") }
    private static let suitM = CrewMat(color: 0xeef0f4, rough: 0.85)
    private static let suitShadeM = CrewMat(color: 0xc3c9d3, rough: 0.8)
    private static let metalM = CrewMat(color: 0xc4ccd8, rough: 0.28, metal: 0.85)
    private static let darkMetalM = CrewMat(color: 0x4a5262, rough: 0.4, metal: 0.7)
    private static let waterM = CrewMat(color: 0xbfe8ff, rough: 0.02, coat: 1, coatRough: 0, opacity: 0.8)
    private static let id = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private static let mid = CrewGeo.sphere(24, 16)

    private func build() {
        let kind = look.kind.rawValue
        let key = kind + "-" + member.name
        root.addChild(body)
        body.addChild(upper)
        upper.addChild(headG)
        headG.position = F3(0, 0.12, 0)
        headG.addChild(face)

        // Скафандр: торс, плечи цвета персонажа с нашивкой, нагрудный пульт, бирка с именем, шланги, швы.
        body.addChild(CrewPieces.entity(key + "-body") { torsoPiece() })
        let chest = crewMatrix(F3(0.15, -2.32, 1.1), simd_quatf(angle: -0.35, axis: F3(1, 0, 0)))
        if let sphere = CrewMeshCache.mesh("sphereMid", { Self.mid }) {
            for (i, c) in [UInt32(0xff5b5b), 0x7ce38b, 0xf2a03d].enumerated() {
                let b = ModelEntity(mesh: sphere, materials: [buttonMaterial(c, 0.4)])
                b.transform = Transform(matrix: chest * crewMatrix(F3(0.2 + Float(i) * 0.13, 0.1, 0.11), Self.id, F3(0.05, 0.05, 0.035)))
                body.addChild(b)
                buttons.append(b)
            }
        }
        // Шея, уплотнитель, воротник.
        upper.addChild(CrewPieces.entity(kind + "-neck") { neckPiece() })
        // Голова, волосы, нос, неподвижные детали лица.
        face.addChild(CrewPieces.entity("head-" + kind) {
            var p = CrewPiece()
            p.add(headMesh(), nil, CrewMat(color: look.skin.hex, rough: 0.6, coat: 0.1, coatRough: 0.7, emissive: 0x5a1a10, glow: 0.12,
                                           tex: CrewAssets.headKey(look.kind)))
            return p
        })
        face.addChild(CrewPieces.entity(kind + "-hair") { hairPiece() })
        buildSway()
        buildNose()
        buildEyes()
        buildBrows()
        buildFaceFX()
        face.addChild(mouth)
        buildHelmet()
        buildFX()
    }

    private func headMesh() -> MeshBuilder {
        var b = CrewGeo.sphere(64, 48)
        for k in 0..<b.positions.count { b.positions[k] = S.headPoint(b.positions[k]) }
        // Нормали по граням; шов и полюса усредняются.
        var acc = [F3](repeating: .zero, count: b.positions.count)
        var i = 0
        while i + 2 < b.indices.count {
            let a = Int(b.indices[i]), c = Int(b.indices[i + 1]), d = Int(b.indices[i + 2])
            let n = simd_cross(b.positions[c] - b.positions[a], b.positions[d] - b.positions[a])
            acc[a] += n
            acc[c] += n
            acc[d] += n
            i += 3
        }
        let w = 64, h = 48
        for row in 0...h {
            let r0 = row * (w + 1)
            if row == 0 || row == h {
                var s = F3.zero
                for j in 0...w { s += acc[r0 + j] }
                for j in 0...w { acc[r0 + j] = s }
            } else {
                let s = acc[r0] + acc[r0 + w]
                acc[r0] = s
                acc[r0 + w] = s
            }
        }
        for k in 0..<acc.count {
            let l = simd_length(acc[k])
            b.normals[k] = l > 1e-9 ? acc[k] / l : simd_normalize(b.positions[k])
        }
        // Обход треугольников — заново по новым нормалям.
        let pos = b.positions, nrm = b.normals, uvs = b.uvs
        var out = MeshBuilder()
        out.positions = pos
        out.normals = nrm
        out.uvs = uvs
        out.gridFaces(rows: h, cols: w, base: 0)
        return out
    }

    private func torsoPiece() -> CrewPiece {
        var p = CrewPiece()
        let suitColor = CrewMat(color: look.suit.hex, rough: 0.75)
        p.add(CrewGeo.sphereHi, crewMatrix(F3(0, -2.75, 0), Self.id, F3(2.05, 1.25, 1.3)), Self.suitM)
        for sd: Float in [-1, 1] {
            // Плечи чуть уже макета: соседние ячейки стоят вплотную, кадр общий.
            p.add(CrewGeo.sphereHi, crewMatrix(F3(sd * 1.5, -2.15, 0.1), Self.id, F3(0.58, 0.42, 0.62)), suitColor)
            p.add(CrewGeo.strand([F3(sd * 0.55, -1.7, 1.0), F3(sd * 0.7, -2.2, 1.25), F3(sd * 0.75, -2.9, 1.25)], 0.022, seg: 16, rad: 6),
                  nil, Self.suitShadeM)
            p.add(CrewGeo.strand([F3(sd * 0.55 + 0.15, -2.3, 1.15), F3(sd * 1.1, -2.0, 1.2), F3(sd * 1.15, -1.6, 0.75)],
                                 0.075, seg: 40, rad: 10, ripple: 14), nil, Self.darkMetalM)
        }
        let patchDir = simd_normalize(F3(3.24, 0, 1.86))
        p.add(CrewGeo.circle(0.5, segments: 40), crewMatrix(F3(1.52, -1.98, 0.66), crewFromTo(F3(0, 0, 1), patchDir), F3(repeating: 0.55)),
              CrewMat(color: 0xffffff, rough: 0.8, tex: CrewAssets.patchKey(look.suit)))
        p.add(CrewGeo.roundedBox(0.7, 0.28, 0.06, 0.03), crewMatrix(F3(-0.9, -2.28, 1.16)), CrewMat(color: 0xe7ebf2, rough: 0.7))
        p.add(CrewGeo.plane, crewMatrix(F3(-0.9, -2.28, 1.18), crewEuler(-0.35, -0.42, 0), F3(0.62, 0.22, 1)),
              CrewMat(color: 0xffffff, rough: 0.7, tex: CrewAssets.tagKey(member.name)))
        let chest = crewMatrix(F3(0.15, -2.32, 1.1), simd_quatf(angle: -0.35, axis: F3(1, 0, 0)))
        p.add(CrewGeo.roundedBox(1.0, 0.55, 0.22, 0.09), chest, Self.suitShadeM)
        p.add(CrewGeo.plane, chest * crewMatrix(F3(-0.2, 0.1, 0.105), Self.id, F3(0.45, 0.16, 1)),
              CrewMat(color: 0xffffff, tex: "o2", unlit: true))
        p.add(Self.mid, chest * crewMatrix(F3(-0.2, -0.14, 0.12), Self.id, F3(0.07, 0.07, 0.04)), Self.metalM)
        return p
    }

    private func neckPiece() -> CrewPiece {
        var p = CrewPiece()
        let r = look.neck
        p.add(CrewGeo.sphereHi, crewMatrix(F3(0, -1.6, -0.05), Self.id, F3(0.62, 0.25, 0.52)), Self.suitShadeM)
        let neckM = CrewMat(color: look.skin.hex, rough: 0.6, coat: 0.1, coatRough: 0.7, emissive: 0x5a1a10, glow: 0.12)
        p.add(CrewGeo.cylinder(r, r * 1.18, 1.0, radial: 40, open: true), crewMatrix(F3(0, -1.12, -0.04)), neckM)
        if look.kind == .anton {
            p.add(Self.mid, crewMatrix(F3(0, -1.22, r - 0.03), Self.id, F3(0.09, 0.12, 0.08)), neckM)
        }
        p.add(CrewGeo.rim, crewMatrix(F3(0, -1.5, -0.03), simd_quatf(angle: .pi / 2, axis: F3(1, 0, 0)), F3(r * 1.35, r * 1.35, 1.1)),
              CrewMat(color: look.suit.hex, rough: 0.6))
        p.add(CrewGeo.sphereHi, crewMatrix(F3(0, -1.78, 0), Self.id, F3(1.3, 0.3, 1.3)), Self.suitShadeM)
        return p
    }

    // MARK: Волосы и аксессуары (только мягкие объёмы)

    private static func dir(_ az: Float, _ el: Float) -> F3 { F3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) }

    private func hairPiece() -> CrewPiece {
        var p = CrewPiece()
        let hair = hairM, cap = hairCapM
        // Объём волос — сфера в масштабе головы, сдвинутая вверх и назад: линия роста волос — плавная кривая.
        func volume(_ dy: Float, _ dz: Float, _ r: Float, _ sx: Float) {
            p.add(CrewGeo.sphereHi, crewMatrix(.zero, Self.id, F3(S.hx * sx, S.hy, S.hz)) * crewMatrix(F3(0, dy, dz), Self.id, F3(repeating: r)), cap)
        }
        func blob(_ c: F3, _ s: F3, _ q: simd_quatf = CrewCharacter.id, _ m: CrewMat? = nil) {
            p.add(Self.mid, crewMatrix(c, q, s), m ?? hair)
        }
        func freckles(_ pts: [(Float, Float)], _ c: UInt32) {
            for (x, y) in pts { p.add(CrewGeo.sphereLo, placed(x, y) * crewMatrix(.zero, Self.id, F3(0.024, 0.024, 0.006)), CrewMat(color: c)) }
        }
        switch look.kind {
        case .lera:
            volume(0.2, -0.15, 1.07, 1.03)
            // Мягкая чёлка набок.
            for b in [(Float(-0.3), Float(0.7), Float(0.3), Float(0.2), Float(0.22), Float(-0.5)),
                      (0.05, 0.78, 0.35, 0.2, 0.22, -0.25), (0.38, 0.72, 0.3, 0.18, 0.2, 0.1)] {
                let s = S.surface(b.0, b.1).p
                blob(F3(s.x, s.y, s.z - 0.06), F3(b.2, b.3, b.4), crewEuler(0, 0, b.5))
            }
            // Подкрученные кончики каре.
            for sd: Float in [-1, 1] {
                for j in 0..<3 { blob(S.onSkull(Self.dir(sd * (1.45 + Float(j) * 0.35), -0.12), 1.03), F3(0.2, 0.17, 0.2)) }
            }
            freckles([(-0.44, -0.17), (-0.52, -0.25), (-0.36, -0.27), (0.44, -0.17), (0.52, -0.25), (0.36, -0.27)], 0xbf7f58)
        case .anton:
            volume(0.32, -0.1, 1.0, 1.02)
            // Взъерошенные мягкие хохолки вместо шипов.
            for i in 0..<16 {
                let a = Float(i) * 2.39996, r = 0.15 + 0.6 * Float((i * 7) % 11) / 11
                let d = simd_normalize(F3(cos(a) * r, 1 - r * 0.4, sin(a) * r * 0.9 - 0.2))
                let c = F3(d.x * 0.96 * S.hx * 1.02, (0.32 + d.y * 0.96) * S.hy, (-0.1 + d.z * 0.96) * S.hz)
                blob(c, F3(0.14, 0.24, 0.14), crewFromTo(F3(0, 1, 0), d))
            }
            // Ремешок и очки-гоглы.
            p.add(CrewGeo.rim, crewMatrix(F3(0, S.hy * 0.5, -0.05), simd_quatf(angle: .pi / 2 - 0.18, axis: F3(1, 0, 0)), F3(S.hx, S.hz * 0.97, 0.6)),
                  CrewMat(color: 0x5a4630, rough: 0.7))
            for sd: Float in [-1, 1] {
                let gg = placed(sd * 0.32, S.hy * 0.55, 0.07)
                p.add(CrewGeo.rim, gg * crewMatrix(.zero, Self.id, F3(0.18, 0.18, 0.9)), CrewMat(color: 0x6a5236, rough: 0.45, metal: 0.3))
                p.add(Self.mid, gg * crewMatrix(F3(0, 0, 0.02), Self.id, F3(0.16, 0.16, 0.08)),
                      CrewMat(color: 0x9fd6e8, rough: 0, metal: 0.2, coat: 1))
            }
            // Усы — две пухлые подкрученные «колбаски».
            for sd: Float in [-1, 1] {
                let m = placed(0, -0.3, 0.06)
                p.add(CrewGeo.strand([F3(0, 0, 0.01), F3(sd * 0.14, -0.01, 0.01), F3(sd * 0.26, -0.06, -0.01), F3(sd * 0.32, -0.01, -0.03)],
                                     0.075, 0.045, seg: 20, rad: 12), m, hair)
                p.add(Self.mid, m * crewMatrix(F3(sd * 0.32, -0.01, -0.03), Self.id, F3(repeating: 0.05)), hair)
                p.add(Self.mid, m * crewMatrix(F3(0, 0, 0.01), Self.id, F3(0.085, 0.075, 0.07)), hair)
            }
        case .mira:
            volume(0.18, -0.16, 1.08, 1.04)
            // Мягкие пряди у висков.
            for sd: Float in [-1, 1] {
                blob(S.onSkull(Self.dir(sd * 1.2, 0.05), 1.0), F3(0.2, 0.5, 0.24), crewEuler(0, 0, sd * -0.15), cap)
            }
            // Очки: оправа, стёкла, дужки, переносица.
            let frame = CrewMat(color: 0x24242f, rough: 0.25, metal: 0.6)
            for sd: Float in [-1, 1] {
                let r = placed(sd * 0.34, 0.14, 0.24)
                p.add(CrewGeo.rim, r * crewMatrix(.zero, Self.id, F3(0.27, 0.27, 0.3)), frame)
                p.add(Self.mid, r * crewMatrix(.zero, Self.id, F3(0.26, 0.26, 0.02)), CrewMat(color: 0xeef6ff, rough: 0, coat: 1, opacity: 0.14))
                p.add(CrewGeo.strand([F3(sd * 0.27, 0, 0), F3(sd * 0.42, 0.02, -0.15), F3(sd * 0.5, 0.03, -0.45)], 0.016, seg: 12, rad: 6), r, frame)
            }
            p.add(CrewGeo.strand([F3(-0.08, 0, 0), F3(0, 0.04, 0.02), F3(0.08, 0, 0)], 0.018, seg: 10, rad: 6), placed(0, 0.18, 0.25), frame)
        case .gosha:
            volume(0.42, -0.1, 0.95, 1.02)
            for (i, d) in [(Float(-0.15), Float(0.05)), (0.05, 0.12), (0.2, 0)].enumerated() {
                let c = S.onSkull(F3(d.0, 1, d.1 - 0.15), 1.0)
                blob(F3(c.x, c.y + 0.04, c.z), F3(0.11, 0.15, 0.11), crewEuler(0, 0, -0.4 + Float(i) * 0.3))
            }
            // Пластырь крестиком.
            let pl = placed(0.02, -0.04, 0.08)
            for r: Float in [0.6, -0.6] {
                p.add(CrewGeo.roundedBox(0.24, 0.08, 0.025, 0.012), pl * crewMatrix(.zero, crewEuler(0, 0, r)), CrewMat(color: 0xe8c39a, rough: 0.9))
            }
            freckles([(-0.47, -0.2), (-0.4, -0.28), (0.47, -0.2), (0.4, -0.28), (-0.52, -0.3), (0.52, -0.3)], 0xd88a5a)
            // Только у Гоши — большие круглые уши.
            for sd: Float in [-1, 1] {
                let e = crewMatrix(F3(sd * S.hx * S.widen(-0.05) * 0.96, -0.05, -0.05), simd_quatf(angle: sd * 0.5, axis: F3(0, 1, 0)))
                p.add(Self.mid, e * crewMatrix(.zero, Self.id, F3(0.14, 0.26, 0.1)), skin)
                p.add(Self.mid, e * crewMatrix(F3(sd * 0.03, 0, 0.05), Self.id, F3(0.08, 0.16, 0.05)),
                      CrewMat(color: look.skin.scaled(0.85).hex))
            }
        case .neutral:
            volume(0.42, -0.1, 0.95, 1.02)
        }
        // Нос-пуговка.
        let ns = look.nose
        let noseM: CrewMat = look.kind == .gosha ? CrewMat(color: 0xf0a08a, rough: 0.55)
            : look.kind == .anton ? CrewMat(color: 0xd8916a, rough: 0.55) : skin
        p.add(Self.mid, placed(0, -0.08, ns * 0.4) * crewMatrix(.zero, Self.id, F3(ns, ns * 0.9, ns * 0.9)), noseM)
        return p
    }

    /// Качающиеся детали волос: хвостик Леры, пучок Миры, росток Гоши.
    private func buildSway() {
        let kind = look.kind.rawValue
        let hair = hairM
        switch look.kind {
        case .lera:
            let tail = CrewPieces.entity(kind + "-tail") {
                var p = CrewPiece()
                p.add(CrewGeo.rim, crewMatrix(.zero, Self.id, F3(0.14, 0.14, 0.5)), CrewMat(color: 0xe14c6a, rough: 0.4))
                p.add(CrewGeo.strand([F3(0, 0, 0), F3(0.32, -0.02, -0.05), F3(0.48, -0.35, 0), F3(0.42, -0.72, 0.1)], 0.17, 0.1, seg: 24, rad: 12), nil, hair)
                p.add(Self.mid, crewMatrix(F3(0.42, -0.72, 0.1), Self.id, F3(repeating: 0.1)), hair)
                return p
            }
            tail.position = S.onSkull(Self.dir(2.0, 0.3), 1.02)
            face.addChild(tail)
            sway.append((tail, 0.22, false))
        case .mira:
            let bun = CrewPieces.entity(kind + "-bun") {
                var p = CrewPiece()
                p.add(CrewGeo.torusKnot(0.21, 0.11, p: 2, q: 3), crewMatrix(F3(0, 0.12, 0), Self.id, F3(1, 0.85, 1)), hair)
                p.add(CrewGeo.rim, crewMatrix(F3(0, -0.06, 0), simd_quatf(angle: .pi / 2, axis: F3(1, 0, 0)), F3(0.25, 0.25, 0.6)),
                      CrewMat(color: 0x9b6be0, rough: 0.4))
                let pencil = crewMatrix(F3(0, 0.14, 0), crewEuler(0.3, 0, 1.05))
                p.add(CrewGeo.cylinder(1, 1, 1, radial: 16), pencil * crewMatrix(.zero, Self.id, F3(0.05, 0.8, 0.05)), CrewMat(color: 0xf2c230, rough: 0.5))
                p.add(Self.mid, pencil * crewMatrix(F3(0, 0.42, 0), Self.id, F3(0.055, 0.07, 0.055)), CrewMat(color: 0xe88aa0))
                p.add(CrewGeo.cylinder(1, 1, 1, radial: 16), pencil * crewMatrix(F3(0, 0.38, 0), Self.id, F3(0.054, 0.05, 0.054)), Self.metalM)
                p.add(Self.mid, pencil * crewMatrix(F3(0, -0.4, 0), Self.id, F3(0.05, 0.08, 0.05)), CrewMat(color: 0xe9c79a))
                return p
            }
            bun.position = S.onSkull(Self.dir(0, 1.1), 1.02) + F3(0, 0.08, -0.2)
            face.addChild(bun)
            sway.append((bun, 0.1, false))
        case .gosha:
            let ant = CrewPieces.entity(kind + "-sprout") {
                var p = CrewPiece()
                p.add(CrewGeo.strand([F3(0, 0, 0), F3(0.05, 0.25, 0), F3(-0.1, 0.45, 0.02), F3(0.05, 0.62, 0), F3(0.2, 0.7, 0)],
                                     0.05, 0.035, seg: 30, rad: 10), nil, hair)
                p.add(Self.mid, crewMatrix(F3(0.2, 0.7, 0), Self.id, F3(repeating: 0.1)), hair)
                return p
            }
            ant.position = S.onSkull(F3(0, 1, -0.1), 0.99)
            face.addChild(ant)
            sway.append((ant, 0.5, true))
        case .anton, .neutral:
            break
        }
    }

    private func buildNose() {
        let ns = look.nose
        let nose = Entity()
        let pl = S.place(0, -0.08, lift: ns * 0.4)
        nose.transform = Transform(scale: F3(1, 1, 1), rotation: pl.q, translation: pl.p)
        face.addChild(nose)
        guard let sphere = CrewMeshCache.mesh("sphereMid", { Self.mid }) else { return }
        let throat = CrewAssets.shared.material(CrewMat(color: 0x1d060b, rough: 1))
        for sd: Float in [-1, 1] {
            let n = ModelEntity(mesh: sphere, materials: [throat])
            let base = F3(ns * 0.16, ns * 0.12, ns * 0.1)
            n.position = F3(sd * ns * 0.4, -ns * 0.5, ns * 0.5)
            n.scale = base
            nose.addChild(n)
            nostrils.append((n, base))
        }
    }

    // MARK: Глаза, брови, рот

    private func buildEyes() {
        let kind = look.kind.rawValue
        let a = CrewAssets.shared
        let lowSphere = CrewMeshCache.mesh("sphereLo") { CrewGeo.sphereLo }
        let upperMesh = CrewMeshCache.mesh("lidUp") { CrewGeo.sphere(32, 14, thetaLen: .pi / 2) }
        let lowerMesh = CrewMeshCache.mesh("lidLow") { CrewGeo.sphere(32, 14, theta0: .pi / 2, thetaLen: .pi / 2) }
        let glintM = a.material(CrewMat(color: 0xffffff, unlit: true))
        let skinMat = a.material(skin)
        for sd: Float in [-1, 1] {
            let r = look.eye * (look.kind == .gosha && sd < 0 ? 1.15 : 1)
            let g = Entity()
            let pl = S.place(sd * 0.34, 0.14, lift: -r * 0.42)
            g.transform = Transform(scale: F3(1, 1, 1), rotation: pl.q, translation: pl.p)
            face.addChild(g)
            let ball = Entity()
            g.addChild(ball)
            ball.addChild(CrewPieces.entity("eye-\(kind)-\(r)") {
                var p = CrewPiece()
                p.add(CrewGeo.sphereHi, crewMatrix(.zero, Self.id, F3(repeating: r)), CrewMat(color: 0xfbfbfb, rough: 0.15, coat: 1, coatRough: 0.05))
                p.add(CrewGeo.cap(0.58), crewMatrix(.zero, Self.id, F3(repeating: r * 1.004)),
                      CrewMat(color: 0xffffff, rough: 0.5, tex: CrewAssets.irisKey(look.iris)))
                p.add(CrewGeo.cap(0.75), crewMatrix(.zero, Self.id, F3(repeating: r * 1.04)), CrewMat(color: 0xffffff, rough: 0, coat: 1, opacity: 0.08))
                return p
            })
            let pupil = ModelEntity()
            pupil.scale = F3(repeating: r * 1.008)
            pupil.model = CrewMeshCache.mesh("cap8") { CrewGeo.cap(0.2) }.map {
                ModelComponent(mesh: $0, materials: [a.material(CrewMat(color: 0x020203, unlit: true))])
            }
            ball.addChild(pupil)
            let glint = ModelEntity()
            let glint2 = ModelEntity()
            if let lowSphere {
                glint.model = ModelComponent(mesh: lowSphere, materials: [glintM])
                glint2.model = ModelComponent(mesh: lowSphere, materials: [glintM])
            }
            glint.position = F3(-r * 0.28, r * 0.3, r * 1.0)
            glint.scale = F3(r * 0.11, r * 0.14, r * 0.05)
            glint2.position = F3(r * 0.22, -r * 0.12, r * 1.01)
            glint2.scale = F3(repeating: r * 0.06)
            g.addChild(glint)
            g.addChild(glint2)
            let up = ModelEntity()
            let low = ModelEntity()
            if let upperMesh { up.model = ModelComponent(mesh: upperMesh, materials: [skinMat]) }
            if let lowerMesh { low.model = ModelComponent(mesh: lowerMesh, materials: [skinMat]) }
            up.scale = F3(repeating: r * 1.14)
            low.scale = F3(repeating: r * 1.13)
            g.addChild(up)
            g.addChild(low)
            // Дуги радости вместо глаз.
            let arc = CrewPieces.entity("eyeArc") {
                var p = CrewPiece()
                let m = CrewMat(color: 0x2b2b3a)
                p.add(CrewGeo.torus(0.15, 0.034, radial: 10, tubular: 28, arc: .pi), nil, m)
                for e: Float in [-1, 1] { p.add(Self.mid, crewMatrix(F3(e * 0.15, 0, 0), Self.id, F3(repeating: 0.034)), m) }
                return p
            }
            setPlaced(arc, sd * 0.34, 0.1, 0.02)
            arc.isEnabled = false
            face.addChild(arc)
            let tear = CrewPieces.entity("tear") {
                var p = CrewPiece()
                p.add(Self.mid, crewMatrix(.zero, Self.id, F3(0.05, 0.075, 0.035)), Self.waterM)
                return p
            }
            tear.isEnabled = false
            face.addChild(tear)
            eyes.append(Eye(sd: sd, r: r, g: g, ball: ball, pupil: pupil, glint: glint, glint2: glint2,
                            upperLid: up, lowerLid: low, arc: arc, tear: tear))
        }
    }

    private func buildBrows() {
        let kind = look.kind.rawValue
        let br = look.brow
        let bm = CrewMat(color: look.hair.hex, rough: 0.8)
        for sd: Float in [-1, 1] {
            let g = Entity()
            face.addChild(g)
            let m = CrewPieces.entity("brow-\(kind)-\(sd)") {
                var p = CrewPiece()
                p.add(CrewGeo.strand([F3(-sd * 0.15, -0.01, 0), F3(-sd * 0.05, 0.03, 0.01), F3(sd * 0.06, 0.035, 0.005), F3(sd * 0.16, -0.015, -0.01)],
                                     br, br * 0.8, seg: 16, rad: 10), nil, bm)
                p.add(Self.mid, crewMatrix(F3(-sd * 0.15, -0.01, 0), Self.id, F3(repeating: br)), bm)
                p.add(Self.mid, crewMatrix(F3(sd * 0.16, -0.015, -0.01), Self.id, F3(repeating: br * 0.8)), bm)
                return p
            }
            g.addChild(m)
            brows.append((g, m, sd))
        }
        // Морщины на лбу (напряжение, паника, грусть).
        for i in 0..<3 {
            let w = 0.22 - Float(i) * 0.03
            let e = CrewPieces.entity("wrinkle-\(kind)-\(i)") {
                var p = CrewPiece()
                p.add(CrewGeo.strand([F3(-w, 0, 0), F3(0, 0.02, 0.01), F3(w, 0, 0)], 0.012, seg: 12, rad: 6), nil,
                      CrewMat(color: look.skin.scaled(0.7).hex))
                return p
            }
            setPlaced(e, 0, 0.58 + Float(i) * 0.08, 0.005)
            e.isEnabled = false
            face.addChild(e)
            wrinkles.append(e)
        }
    }

    private func buildFaceFX() {
        let a = CrewAssets.shared
        let plane = CrewMeshCache.mesh("plane") { CrewGeo.plane }
        for sd: Float in [-1, 1] {
            let b = ModelEntity()
            if let plane { b.model = ModelComponent(mesh: plane, materials: [blushMaterial(5)]) }
            b.scale = F3(0.46, 0.3, 1)
            setPlaced(b, sd * 0.55, -0.2, 0.012)
            b.isEnabled = false
            face.addChild(b)
            blush.append(b)
        }
        let kind = look.kind.rawValue
        let sootPiece = CrewPieces.entity("soot-\(kind)") {
            var p = CrewPiece()
            for s in [(Float(-0.38), Float(-0.3), Float(0.5), Float(0.4)), (0.42, 0.4, 0.4, 0.3), (0.15, -0.65, 0.3, 0.22), (-0.3, 0.55, 0.3, 0.22)] {
                p.add(CrewGeo.plane, placed(s.0, s.1, 0.014) * crewMatrix(.zero, Self.id, F3(s.2, s.3, 1)),
                      CrewMat(color: 0xffffff, tex: "soot", unlit: true, alphaTex: true))
            }
            return p
        }
        soot.addChild(sootPiece)
        soot.isEnabled = false
        face.addChild(soot)
        for _ in 0..<2 {
            let s = CrewPieces.entity("sweat") {
                var p = CrewPiece()
                p.add(Self.mid, crewMatrix(.zero, Self.id, F3(0.055, 0.07, 0.04)), Self.waterM)
                p.add(Self.mid, crewMatrix(F3(0, 0.05, 0), Self.id, F3(0.035, 0.06, 0.028)), Self.waterM)
                return p
            }
            s.isEnabled = false
            face.addChild(s)
            sweat.append(s)
        }
        // Торчащие зубы Гоши и высунутый язык — положения от формы рта.
        if look.kind == .gosha, let tooth = CrewMeshCache.mesh("goshaTooth", { CrewGeo.roundedBox(0.085, 0.1, 0.035, 0.02) }) {
            for _ in 0..<2 {
                let t = ModelEntity(mesh: tooth, materials: [a.material(CrewMat(color: 0xfffaf0, rough: 0.25, coat: 0.6, coatRough: 0.2))])
                face.addChild(t)
                goshaTeeth.append(t)
            }
        }
        if let sphere = CrewMeshCache.mesh("sphereMid", { Self.mid }) {
            let t = ModelEntity(mesh: sphere, materials: [a.material(CrewMat(color: 0xe0606f, rough: 0.4))])
            t.scale = F3(0.07, 0.08, 0.035)
            tongueOut.addChild(t)
        }
        tongueOut.isEnabled = false
        face.addChild(tongueOut)
    }

    // MARK: Шлем и эффекты

    private func buildHelmet() {
        let a = CrewAssets.shared
        let helmet = Entity()
        upper.addChild(helmet)
        helmet.addChild(CrewPieces.entity("helmet") {
            var p = CrewPiece()
            p.add(CrewGeo.sphere(48, 16, thetaLen: .pi * 0.3), crewMatrix(F3(0, 0.2, 0), simd_quatf(angle: -0.75, axis: F3(1, 0, 0)), F3(repeating: 2.03)),
                  CrewMat(color: 0xe2b04a, rough: 0.18, metal: 0.9))
            p.add(CrewGeo.rim, crewMatrix(F3(0, -1.62, 0), simd_quatf(angle: .pi / 2, axis: F3(1, 0, 0)), F3(1.38, 1.38, 1.6)), Self.metalM)
            for i in 0..<14 {
                let an = Float(i) / 14 * CrewGeo.tau
                p.add(CrewGeo.sphereLo, crewMatrix(F3(sin(an) * 1.38, -1.46, cos(an) * 1.38), Self.id, F3(0.045, 0.03, 0.045)), Self.darkMetalM)
            }
            p.add(CrewGeo.roundedBox(0.26, 0.2, 0.14, 0.06), crewMatrix(F3(-0.95, -1.62, 1.08)), Self.darkMetalM)
            for sd: Float in [-1, 1] {
                p.add(CrewGeo.cylinder(1, 1, 1, radial: 16), crewMatrix(F3(sd * 1.15, -1.48, 1.0), simd_quatf(angle: .pi / 2.6, axis: F3(1, 0, 0)), F3(repeating: 0.07)),
                      CrewMat(color: 0xfff1b0, rough: 0.6, emissive: 0xffe680, glow: 1.2))
            }
            return p
        })
        // Стекло: прозрачная сфера с бликами + кромка по Френелю (камера всегда спереди — запечено в текстуру).
        // Видна только передняя полусфера (задние грани отсекаются). Начало сущности вынесено вперёд:
        // прозрачное рисуется от дальнего к ближнему, стекло должно идти после румянца, копоти, слёз и пота.
        for (k, lift) in [(0, Float(3.0)), (1, Float(3.2))] {
            let r: Float = k == 0 ? 2.0 : 2.005
            guard let mesh = CrewMeshCache.mesh("glass\(k)", { Self.glassMesh(offset: lift / r) }) else { continue }
            let m = k == 0 ? CrewMat(color: 0xeaf4ff, opacity: 0.03, unlit: true)
                : CrewMat(color: 0xd8ecff, tex: "fresnel", unlit: true, alphaTex: true)
            let g = ModelEntity(mesh: mesh, materials: [a.material(m)])
            g.position = F3(0, 0.2, lift)
            g.scale = F3(repeating: r)
            helmet.addChild(g)
        }
        helmet.addChild(CrewPieces.entity("helmetShine") {
            var p = CrewPiece()
            let shine = CrewMat(color: 0xffffff, opacity: 0.5, unlit: true)
            let pts: [F3] = [Self.onGlass(-1.45, 0.9, 2.01), Self.onGlass(-1.15, 1.45, 2.01), Self.onGlass(-0.55, 1.8, 2.01)]
            p.add(CrewGeo.strand(pts, 0.06, seg: 16, rad: 8), nil, shine)
            p.add(CrewGeo.sphereLo, crewMatrix(F3(1.2, -0.55, 1.45), Self.id, F3(repeating: 0.07)), shine)
            return p
        })
        // Трещина на стекле (авария).
        crack.addChild(CrewPieces.entity("crack") {
            var p = CrewPiece()
            let xy: [SIMD2<Float>] = [SIMD2(0.7, 1.2), SIMD2(0.45, 0.75), SIMD2(0.75, 0.5), SIMD2(0.35, 0.1),
                                      SIMD2(0.45, 0.75), SIMD2(0.08, 0.7), SIMD2(0.75, 0.5), SIMD2(1.05, 0.25)]
            let pts: [F3] = xy.map { Self.onGlass($0.x, $0.y, 2.0) + F3(0, 0, 0.01) }
            let m = CrewMat(color: 0xf2f6fb, unlit: true)
            for (i, j) in [(0, 1), (1, 2), (2, 3), (4, 5), (6, 7)] {
                p.add(CrewGeo.tube([pts[i], pts[j]], rad: 4) { _ in 0.012 }, nil, m)
            }
            return p
        })
        crack.isEnabled = false
        helmet.addChild(crack)
    }

    /// Передняя полусфера стекла (UV по φ 0…π — под текстуру Френеля), сдвинутая назад на `offset`
    /// (в единицах радиуса); крошечный треугольник у начала координат держит центр границ впереди.
    private static func glassMesh(offset: Float) -> MeshBuilder {
        var b = CrewGeo.sphere(48, 32, phiLen: .pi).transformed(crewMatrix(F3(0, 0, -offset)))
        let n = F3(0, 0, -1)
        let i0 = b.vertex(.zero, n), i1 = b.vertex(F3(0.001, 0, 0), n), i2 = b.vertex(F3(0, 0.001, 0), n)
        b.tri(i0, i1, i2, facing: n)
        return b
    }

    /// Точка на стекле шлема (центр (0, 0.2, 0), радиус r) по x, y спереди.
    private static func onGlass(_ x: Float, _ y: Float, _ r: Float) -> F3 {
        let dy = y - 0.2
        let z2: Float = r * r - x * x - dy * dy
        return F3(x, y, max(0, z2).squareRoot())
    }

    private func buildFX() {
        let a = CrewAssets.shared
        if let star = CrewMeshCache.mesh("star", { CrewGeo.star }) {
            for _ in 0..<3 {
                let s = ModelEntity(mesh: star, materials: [a.material(CrewMat(color: 0xffd54a, emissive: 0x9a7010, glow: 1))])
                s.scale = F3(repeating: 0.1)
                s.isEnabled = false
                root.addChild(s)
                stars.append(s)
            }
        }
        if let plane = CrewMeshCache.mesh("plane", { CrewGeo.plane }) {
            for _ in 0..<3 {
                let s = ModelEntity(mesh: plane, materials: [smokeMaterial(4)])
                s.isEnabled = false
                root.addChild(s)
                smoke.append(s)
            }
        }
        heat.light.color = CrewColor(0xff5a1f).ui
        heat.light.intensity = 0
        heat.light.attenuationRadius = 3.2
        heat.position = F3(0, -1.2, 2.6)
        heat.isEnabled = false
        root.addChild(heat)
    }

    private func buttonMaterial(_ c: UInt32, _ glow: Float) -> any Material {
        CrewAssets.shared.material(CrewMat(color: c, rough: 0.3, emissive: c, glow: glow))
    }
    private func blushMaterial(_ level: Int) -> any Material {
        CrewAssets.shared.material(CrewMat(color: 0xff5468, opacity: 0.05 * Float(level), tex: "spot", unlit: true, alphaTex: true))
    }
    private func smokeMaterial(_ level: Int) -> any Material {
        CrewAssets.shared.material(CrewMat(color: 0x8d939b, opacity: 0.05 * Float(level), tex: "spot", unlit: true, alphaTex: true))
    }

    // MARK: - Анимация

    private static func n1(_ t: Double, _ k: Double) -> Double {
        sin(t * 1.7 + k) * 0.5 + sin(t * 3.1 + k * 2.3) * 0.3 + sin(t * 5.9 + k * 0.7) * 0.2
    }
    private static func frac(_ x: Double) -> Double { x - x.rounded(.down) }
    private static func show(_ e: Entity, _ on: Bool) { if e.isEnabled != on { e.isEnabled = on } }

    /// Кадр анимации (время `t` в секундах; вызывается не чаще 30 Гц).
    func update(time t: Double) {
        let lin = min(1, max(0, (t - moodStart) / 0.3))
        let p = from.lerp(target, lin * lin * (3 - 2 * lin))
        current = p
        let k = Double(member.id.count) * 1.37 + seed

        // Тело: тряска, дыхание, невесомость, прыжки.
        let sh = p.shake * 0.07
        let bx = sh > 0 ? (sin(t * p.freq + k) * 0.6 + Self.n1(t * 6, k) * 0.4) * sh : 0
        let by = sin(t * 1.5 + k) * 0.018 + (sh > 0 ? cos(t * p.freq * 1.13 + k) * 0.6 * sh : 0)
            + p.float * (sin(t * 1.3 + k) * 0.18 + 0.12) + p.bounce * abs(sin(t * 5 + k)) * 0.22
        let roll = p.float * sin(t * 0.8 + k) * 0.14 + (1 - p.float) * (p.shake > 0 ? Self.n1(t * 4, k) * p.shake * 0.05 : 0)
        body.position = F3(Float(bx), Float(by), 0)
        // Торс кренится меньше головы: соседние ячейки стоят вплотную.
        body.orientation = simd_quatf(angle: Float(roll * 0.35), axis: F3(0, 0, 1))
        upper.orientation = simd_quatf(angle: Float(roll * 0.65), axis: F3(0, 0, 1))

        // Голова и взгляд.
        let gx = Self.n1(t * 0.6, k) * 0.6 * (1 - p.dart) + Self.n1(t * 7, k) * p.dart
        let gy = Self.n1(t * 0.5, k + 2) * 0.3 * (1 - p.dart) + Self.n1(t * 6, k + 4) * 0.7 * p.dart
        let hz = p.float * sin(t * 1.1 + k) * 0.08 - 0.12 * p.soot * (1 - p.float)
        headG.orientation = crewEuler(Float(-gy * 0.1 + p.squash * 0.9), Float(gx * (0.16 + 0.06 * p.dart)), Float(hz))
        headG.position = F3(0, Float(0.12 - p.squash * 0.25 + p.float * sin(t * 1.7 + k) * 0.05), 0)
        let hs = Self.head
        face.scale = F3(hs * Float(1 + p.squash * 0.2), hs * Float(1 - p.squash * 0.5), hs)

        // Глаза: моргание, взгляд, косоглазие, веки, блики, слёзы.
        let period = mood == .panic ? 1.3 : 2.6 + k.truncatingRemainder(dividingBy: 2)
        let ph = ((t + k).truncatingRemainder(dividingBy: period)) / period
        let blink = ph > 0.93 ? sin((ph - 0.93) / 0.07 * .pi) : 0
        let o = max(0, p.open * (1 - blink))
        let lowLid = mood == .strain ? 0.3 : mood == .crash ? 0.25 : 0
        let showEyes = p.happy < 0.5
        let pupilKey = Int((0.2 * p.pupil * 40).rounded())
        for (i, e) in eyes.enumerated() {
            Self.show(e.g, showEyes)
            Self.show(e.arc, !showEyes)
            e.g.scale = F3(repeating: Float(p.eye))
            e.ball.orientation = crewEuler(Float(-gy * 0.3), Float(gx * 0.35 + p.cross * -Double(e.sd) * 0.3), 0)
            if pupilKey != self.pupilKey[i] {
                self.pupilKey[i] = pupilKey
                if let m = CrewMeshCache.mesh("cap\(pupilKey)", { CrewGeo.cap(Float(pupilKey) / 40) }) { e.pupil.model?.mesh = m }
            }
            let up = o < 0.6 ? 1.57 - o * 3.0 : -0.11 - (o - 0.6) * 0.8
            e.upperLid.orientation = simd_quatf(angle: Float(min(1.57, max(-1.15, up))), axis: F3(1, 0, 0))
            e.lowerLid.orientation = simd_quatf(angle: Float(1.3 - lowLid * 1.1), axis: F3(1, 0, 0))
            let sp = Float(p.sparkle)
            e.glint.scale = F3(e.r * (0.11 + 0.06 * sp), e.r * (0.14 + 0.06 * sp), e.r * 0.05)
            Self.show(e.glint, o > 0.35)
            Self.show(e.glint2, o > 0.35)
            let tearOn = p.tear > 0.1 && e.sd < 0
            Self.show(e.tear, tearOn)
            if tearOn {
                let d = Float(Self.frac(t * 0.7 + k))
                setPlaced(e.tear, e.sd * 0.38, -0.08 - d * 0.45, 0.025)
            }
        }
        for b in brows {
            let y = Float(0.5 + p.brow * 0.1 + (p.eye - 1) * 0.2)
            setPlaced(b.g, b.sd * 0.34, y, 0.03)
            b.m.orientation = simd_quatf(angle: b.sd * Float(-p.tilt * 0.42), axis: F3(0, 0, 1))
        }
        for (i, w) in wrinkles.enumerated() {
            Self.show(w, (p.tilt > 0.5 || p.brow > 0.7) && Double(i) < 1 + (p.brow * 2).rounded())
        }
        let flare: Float = mood == .panic || mood == .strain ? 1.6 : 1
        for n in nostrils { n.e.scale = F3(n.base.x * flare, n.base.y * flare, n.base.z) }

        // Рот: меш меняется только при смене формы (кэш по ключу).
        let m = CrewMouth.shape(look: look, silly: member.silliness, mood: mood, p: p, t: t)
        if m.mesh !== mouthMesh {
            mouthMesh = m.mesh
            if let mesh = m.mesh {
                mouth.model = ModelComponent(mesh: mesh, materials: CrewMouth.materials(look))
            } else {
                mouth.model = nil
            }
            for (i, tooth) in goshaTeeth.enumerated() where i < m.goshaTeeth.count { tooth.position = m.goshaTeeth[i] }
            Self.show(tongueOut, m.tongueOut != nil)
            if let q = m.tongueOut { tongueOut.position = q }
        }

        // Румянец, копоть, трещина, пот.
        let bl = p.blush > 0.05 ? max(1, min(10, Int((p.blush * 10).rounded()))) : 0
        if bl != blushLevel {
            blushLevel = bl
            for b in blush {
                Self.show(b, bl > 0)
                if bl > 0 { b.model?.materials = [blushMaterial(bl)] }
            }
        }
        Self.show(soot, p.soot > 0.5)
        Self.show(crack, p.soot > 0.5)
        for (i, s) in sweat.enumerated() {
            let on = p.sweat > 0.05 && (i == 0 || p.sweat > 0.7)
            Self.show(s, on)
            guard on else { continue }
            let d = Float(Self.frac(t * 1.1 + k + Double(i) * 0.5))
            let pl = S.place((i == 1 ? -1 : 1) * (0.7 - d * 0.06), 0.5 - d * 0.55, lift: 0.035)
            s.position = pl.p
        }
        let swayK = max(0.35, 1.6 * p.float, min(1, p.shake * 10))
        for (i, s) in sway.enumerated() {
            let fi = Double(i)
            let z = sin(t * (s.fast ? 6 : 2.2) + fi) * Double(s.amp) * swayK
            let x = p.float * sin(t * 1.4 + fi) * Double(s.amp) * 0.6
            s.e.orientation = crewEuler(Float(x), 0, Float(z))
        }

        // Звёздочки над головой, дым, отсвет нагрева.
        for (i, s) in stars.enumerated() {
            Self.show(s, p.dizzy > 0.3)
            guard p.dizzy > 0.3 else { continue }
            let an = t * 2.5 + Double(i) * 2.09
            s.position = F3(Float(cos(an) * 1.25), Float(1.7 + sin(an) * 0.12 + by), Float(sin(an) * 1.0))
            s.orientation = simd_quatf(angle: Float(t * 3), axis: F3(0, 1, 0))
        }
        for (i, s) in smoke.enumerated() {
            let on = p.soot > 0.5
            Self.show(s, on)
            guard on else { continue }
            let d = Self.frac(t * 0.3 + Double(i) / 3)
            s.position = F3(Float(-1.1 + Double(i) * 1.1 + sin(t + Double(i)) * 0.1), Float(0.8 + d * 1.6), 0.9)
            s.scale = F3(repeating: Float(0.6 + d))
            let lvl = max(0, min(8, Int((0.4 * (1 - d) / 0.05).rounded())))
            if lvl != smokeLevels[i] {
                smokeLevels[i] = lvl
                s.model?.materials = [smokeMaterial(lvl)]
            }
        }
        Self.show(heat, p.heat > 0.05)
        if p.heat > 0.05 { heat.light.intensity = Float((3 + sin(t * 9)) * p.heat * 9_000) }

        // Кабина: лампочки и кнопки пульта (в панике мигают).
        if let lamps = cabin?.lamps {
            for (i, l) in lamps.enumerated() {
                let fi = Double(i)
                Self.show(l, mood == .panic ? sin(t * 8 + fi) > 0 : sin(t * 0.7 + fi * 1.3) > -0.6)
            }
        }
        let bs: Int
        if mood == .panic {
            bs = (sin(t * 10) > 0 ? 1 : 0) | (sin(t * 10 + 2) > 0 ? 2 : 0) | (sin(t * 10 + 4) > 0 ? 4 : 0)
        } else {
            bs = 8
        }
        if bs != buttonState {
            buttonState = bs
            for (i, b) in buttons.enumerated() {
                let c: UInt32 = [0xff5b5b, 0x7ce38b, 0xf2a03d][i]
                let glow: Float = bs == 8 ? 0.4 : (bs & (1 << i) != 0 ? 1.5 : 0.1)
                b.model?.materials = [buttonMaterial(c, glow)]
            }
        }
    }
}
