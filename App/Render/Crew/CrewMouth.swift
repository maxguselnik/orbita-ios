import OrbitPhysics
import RealityKit
import simd

/// Готовый рот (кэшируется по форме): один меш из частей с материалами `CrewMouth.Part` и положения отдельных деталей.
struct CrewMouthShape {
    let mesh: MeshResource?
    /// Торчащие зубы Гоши (поверх нижней губы, даже при закрытом рте).
    let goshaTeeth: [F3]
    /// Высунутый язык при закрытом рте.
    let tongueOut: F3?
}

/// Рот по `buildMouth` макета. Всё лежит на поверхности лица (z из `faceZ`). В RealityKit нет трафарета,
/// поэтому зубы и язык — не объёмы внутри головы, а области лица между кромками рта (чуть выше полости):
/// за губы они не вылезают по построению.
@MainActor
enum CrewMouth {
    /// Номера материалов частей меша.
    enum Part: Int, CaseIterable {
        case hole, tongue, tongueLine, teeth, gum, lip, crease
    }

    nonisolated static let mouthY: Float = -0.42
    private static var cache: [String: CrewMouthShape] = [:]

    /// Форма рта по параметрам мимики. `t` — время (дрожь рта в панике).
    static func shape(look: CrewLook, silly: Double, mood: CrewMood, p: CrewFace, t: Double) -> CrewMouthShape {
        func q(_ v: Float, _ step: Float = 0.006) -> Float { (v / step).rounded() * step }
        let round: Float = mood == .awe ? 0.5 : mood == .panic ? 0.25 : mood == .crash ? 0.3 : 0
        let mouth = Float(p.mouth), smile = Float(p.smile)
        let dart = p.dart > 0.01 ? Float(abs(sin(t * 11)) * 0.03 * p.dart) : 0
        let open = q((mood == .strain ? max(mouth, 0.45) : mouth) * 0.3 + dart, 0.004)
        let w = q(0.36 + 0.1 * max(0, smile) + 0.04 * mouth - 0.14 * round)
        let cy = 0.1 * smile
        let s = Float(silly)
        let skew = s > 0.4 && abs(smile) > 0.2 ? (s - 0.4) * 0.08 * (smile > 0 ? 1 : -1) : 0
        let cl = q(cy - skew), cr = q(cy + skew)
        let gap = max(open, 0.012)
        let yu = q(cy * 0.15 + gap * (0.22 + round * 0.5))
        let yl = q(cy * 0.15 - gap * (0.78 + round * 0.3) - max(0, smile) * gap * 0.55)
        let teeth = p.teeth > 0.5, tongue = p.tongue > 0.5
        let grit = mood == .strain
        let crease: Int = abs(smile) > 0.35 ? (smile > 0 ? 1 : -1) : 0
        let key = "\(look.kind.rawValue)|\(w)|\(cl)|\(cr)|\(yu)|\(yl)|\(open)|\(teeth)|\(tongue)|\(grit)|\(crease)|\(q(skew, 0.004))|\(smile > 0.3)"
        if let m = cache[key] { return m }
        let g = Geometry(S: look.shape, w: w, cl: cl, cr: cr, yu: yu, yl: yl)
        let shape = build(g, look: look, open: open, skew: q(skew, 0.004), smile: smile, teeth: teeth, tongue: tongue,
                          grit: grit, crease: crease, key: key)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = shape
        return shape
    }

    /// Кромки рта: квадратичные Безье от уголка к уголку.
    private struct Geometry {
        let S: CrewShape
        let w, cl, cr, yu, yl: Float

        static func qb(_ y0: Float, _ yc: Float, _ y1: Float, _ u: Float) -> Float {
            let c = 2 * yc - (y0 + y1) / 2
            return (1 - u) * (1 - u) * y0 + 2 * (1 - u) * u * c + u * u * y1
        }
        func xu(_ u: Float) -> Float { -w + 2 * w * u }
        func uOf(_ x: Float) -> Float { (x + w) / (2 * w) }
        func upper(_ u: Float) -> Float { Self.qb(cl, yu, cr, u) }
        func lower(_ u: Float) -> Float { Self.qb(cl, yl, cr, u) }
        func onFace(_ x: Float, _ y: Float, _ lift: Float = 0) -> F3 {
            let Y = CrewMouth.mouthY + y
            return F3(x, Y, S.faceZ(x, Y) + lift)
        }
        func normal(_ x: Float, _ y: Float) -> F3 { S.surface(x, CrewMouth.mouthY + y).n }

        /// Область лица между `lo(x)` и `hi(x)` (y рта) для x0…x1, обрезанная кромками рта.
        func region(_ x0: Float, _ x1: Float, cols: Int, rows: Int, lift: Float,
                    lo: (Float) -> Float, hi: (Float) -> Float, bend: (Float, Float) -> F3 = { _, _ in .zero }) -> MeshBuilder {
            var b = MeshBuilder()
            let a = max(x0, -w), c = min(x1, w)
            guard c > a else { return b }
            for i in 0...cols {
                let x = a + (c - a) * Float(i) / Float(cols)
                let u = uOf(x)
                let l = max(lo(x), lower(u)), h = max(l, min(hi(x), upper(u)))
                for j in 0...rows {
                    let y = l + (h - l) * Float(j) / Float(rows)
                    let n = simd_normalize(normal(x, y) + bend(x, y))
                    b.vertex(onFace(x, y, lift), n, SIMD2(Float(i) / Float(cols), Float(j) / Float(rows)))
                }
            }
            b.gridFaces(rows: cols, cols: rows, base: 0)
            return b
        }

        /// Ряд зубов: проекция дуги-трубки радиуса r(u) вокруг кромки `yOf + dy`, видимая в проёме.
        func teethRow(_ yOf: (Float) -> Float, dy: Float, r: Float, lift: Float, into batch: inout MeshBatch) {
            let rr: (Float) -> Float = { u in r * (0.75 + 0.25 * sin(.pi * u)) }
            let x0 = xu(0.04), x1 = xu(0.96)
            let row = region(x0, x1, cols: 32, rows: 4, lift: lift,
                             lo: { x in let u = uOf(x); return yOf(u) + dy - rr(u) },
                             hi: { x in let u = uOf(x); return yOf(u) + dy + rr(u) },
                             bend: { x, y in
                                 let u = uOf(x)
                                 return F3(0, (y - (yOf(u) + dy)) / max(rr(u), 1e-4) * 0.8, 0)
                             })
            batch.add(row, mat: Part.teeth.rawValue)
            // Межзубные бороздки.
            for i in 1..<6 {
                let u = 0.5 + Float(i - 3) * 0.09
                let x = xu(u)
                let yc = yOf(u) + dy
                let lo = max(yc - r * 0.9, yc - rr(u)), hi = min(yc + r * 0.9, yc + rr(u))
                batch.add(region(x - 0.006, x + 0.006, cols: 1, rows: 2, lift: lift + 0.0015,
                                 lo: { _ in lo }, hi: { _ in hi }), mat: Part.gum.rawValue)
            }
        }
    }

    private static func build(_ g: Geometry, look: CrewLook, open: Float, skew: Float, smile: Float, teeth: Bool,
                              tongue: Bool, grit: Bool, crease: Int, key: String) -> CrewMouthShape {
        var batch = MeshBatch()
        // Полость: сетка между кромками, цвет — из запечённой текстуры (темнее под верхней губой).
        var hole = MeshBuilder()
        let n = 28, m = 8
        for i in 0...n {
            let u = Float(i) / Float(n)
            let x = g.xu(u)
            for j in 0...m {
                let v = Float(j) / Float(m)
                let y = g.lower(u) + (g.upper(u) - g.lower(u)) * v
                hole.vertex(g.onFace(x, y, 0.004), g.normal(x, y), SIMD2(u, v))
            }
        }
        hole.gridFaces(rows: n, cols: m, base: 0)
        batch.add(hole, mat: Part.hole.rawValue)

        let hOpen = g.yu - g.yl
        if open > 0.03 {
            // Язык снизу: эллипс, выпуклый (нормали наклонены от центра).
            let tx = skew * 2 + (tongue ? 0.05 : 0)
            let ty = g.yl + min(0.06, hOpen * 0.18)
            let a = g.w * 0.5, bb = min(0.1, hOpen * 0.35)
            let half: (Float) -> Float = { x in
                let k = (x - tx) / a
                return bb * max(0, 1 - k * k).squareRoot()
            }
            batch.add(g.region(tx - a, tx + a, cols: 18, rows: 6, lift: 0.006,
                               lo: { x in ty - half(x) }, hi: { x in ty + half(x) },
                               bend: { x, y in F3((x - tx) / a * 0.6, (y - ty) / max(bb, 1e-4) * 0.6, 0) }),
                      mat: Part.tongue.rawValue)
            let lh = min(0.06, hOpen * 0.25)
            batch.add(g.region(tx - 0.006, tx + 0.006, cols: 1, rows: 3, lift: 0.007,
                               lo: { x in max(ty + 0.01 - lh, ty - half(x)) },
                               hi: { x in min(ty + 0.01 + lh, ty + half(x)) }),
                      mat: Part.tongueLine.rawValue)
        }
        let showUpper = teeth || (smile > 0.3 && open > 0.05) || open > 0.12
        if grit {
            g.teethRow(g.upper, dy: -hOpen * 0.27, r: hOpen * 0.32, lift: 0.008, into: &batch)
            g.teethRow(g.lower, dy: hOpen * 0.27, r: hOpen * 0.3, lift: 0.0085, into: &batch)
        } else {
            if showUpper && open > 0.02 { g.teethRow(g.upper, dy: -0.022, r: min(0.042, hOpen * 0.3), lift: 0.008, into: &batch) }
            if teeth && open > 0.02 { g.teethRow(g.lower, dy: 0.02, r: min(0.034, hOpen * 0.25), lift: 0.0085, into: &batch) }
        }

        // Губы с объёмом (толще к середине), уголки — мягкие шарики.
        func lipPts(_ yOf: (Float) -> Float, _ off: Float) -> [F3] {
            (0...20).map { i in
                let u = Float(i) / 20
                return g.onFace(g.xu(u), yOf(u) + off * sin(.pi * u), 0.006)
            }
        }
        let up = CrewGeo.tube(CrewGeo.path(lipPts(g.upper, 0.012), segments: 40), rad: 12) { u in
            0.018 + 0.022 * pow(sin(.pi * u), 0.8)
        }
        let lo = CrewGeo.tube(CrewGeo.path(lipPts(g.lower, -0.016), segments: 40), rad: 12) { u in
            0.02 + 0.03 * pow(sin(.pi * u), 0.8)
        }
        batch.add(up, mat: Part.lip.rawValue)
        batch.add(lo, mat: Part.lip.rawValue)
        for (x, y) in [(-g.w, g.cl), (g.w, g.cr)] {
            batch.add(CrewGeo.sphereLo, crewMatrix(g.onFace(x, y, 0.004), simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), F3(repeating: 0.024)),
                      mat: Part.lip.rawValue)
        }
        // Ямочки и складки у уголков при улыбке, складки вниз при грусти.
        if crease != 0 {
            let dir = Float(crease)
            for (sd, y) in [(Float(-1), g.cl), (Float(1), g.cr)] {
                let pts = [g.onFace(sd * (g.w + 0.05), y + 0.07 * dir, 0.003), g.onFace(sd * (g.w + 0.085), y, 0.003),
                           g.onFace(sd * (g.w + 0.06), y - 0.07 * dir, 0.003)]
                batch.add(CrewGeo.tube(CrewGeo.path(pts, segments: 16), rad: 8) { u in 0.012 * sin(.pi * u) + 0.003 },
                          mat: Part.crease.rawValue)
            }
        }
        var gosha: [F3] = []
        if look.kind == .gosha {
            for sd: Float in [-1, 1] {
                gosha.append(g.onFace(sd * 0.048 + skew, Geometry.qb(g.cl, g.yu, g.cr, 0.5) - 0.045, 0.012))
            }
        }
        let out: F3? = tongue && open < 0.03 ? g.onFace(0.08 + skew, g.lower(0.62) - 0.05, 0.01) : nil
        return CrewMouthShape(mesh: batch.makeMesh(name: "mouth"), goshaTeeth: gosha, tongueOut: out)
    }

    /// Материалы частей рта персонажа (по порядку `Part`).
    static func materials(_ look: CrewLook) -> [any Material] {
        let a = CrewAssets.shared
        let lip = look.skin.mixed(CrewColor(0xc0505a), 0.32)
        return [
            a.material(CrewMat(color: 0xffffff, tex: "hole", unlit: true)),
            a.material(CrewMat(color: 0xe0606f, rough: 0.4, coat: 0.3, coatRough: 0.3)),
            a.material(CrewMat(color: 0xb84453, rough: 0.6)),
            a.material(CrewMat(color: 0xfffaf0, rough: 0.25, coat: 0.6, coatRough: 0.2)),
            a.material(CrewMat(color: 0xd8707a, rough: 0.5)),
            a.material(CrewMat(color: lip.hex, rough: 0.45, coat: 0.35, coatRough: 0.4)),
            a.material(CrewMat(color: look.skin.scaled(0.78).hex, rough: 0.7)),
        ]
    }
}
