import RealityKit
import simd

// Геометрия портретов экипажа: порт построителей из макета (`docs/mockups/crew-portraits.html`):
// сегменты сфер как THREE.SphereGeometry, трубки по сплайну Кэтмулла — Рома, торы, цилиндры,
// скруглённые бруски, звёздочки. Всё собирается в `MeshBuilder` (CPU), в `MeshResource` — через кэш.

extension MeshBuilder {
    /// Треугольники регулярной сетки (rows + 1) × (cols + 1) вершин, начиная с `base`; лицевая сторона — по нормалям вершин.
    mutating func gridFaces(rows: Int, cols: Int, base: UInt32) {
        let stride = UInt32(cols + 1)
        for i in 0..<rows {
            for j in 0..<cols {
                let a = base + UInt32(i) * stride + UInt32(j)
                let b = a + stride
                let n = normals[Int(a)] + normals[Int(b)] + normals[Int(b + 1)] + normals[Int(a + 1)]
                tri(a, b, b + 1, facing: n)
                tri(a, b + 1, a + 1, facing: n)
            }
        }
    }

    /// Копия, перенесённая матрицей `m` (нормали — обратной транспонированной).
    func transformed(_ m: float4x4) -> MeshBuilder {
        var out = self
        let m3 = float3x3(F3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                          F3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                          F3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let nm = m3.inverse.transpose
        for k in 0..<positions.count {
            let p = m * SIMD4<Float>(positions[k], 1)
            out.positions[k] = F3(p.x, p.y, p.z)
            let n = nm * normals[k]
            let l = simd_length(n)
            out.normals[k] = l > 1e-8 ? n / l : normals[k]
        }
        if m3.determinant < 0 {
            var k = 0
            while k + 2 < out.indices.count {
                out.indices.swapAt(k + 1, k + 2)
                k += 3
            }
        }
        return out
    }
}

/// Матрица из масштаба, поворота и сдвига (порядок как у `Transform`).
func crewMatrix(_ t: F3 = .zero, _ r: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), _ s: F3 = F3(1, 1, 1)) -> float4x4 {
    Transform(scale: s, rotation: r, translation: t).matrix
}

/// Поворот по углам Эйлера в порядке three.js «XYZ» (матрица Rx·Ry·Rz).
func crewEuler(_ x: Float, _ y: Float, _ z: Float) -> simd_quatf {
    simd_quatf(angle: x, axis: F3(1, 0, 0)) * simd_quatf(angle: y, axis: F3(0, 1, 0)) * simd_quatf(angle: z, axis: F3(0, 0, 1))
}

/// Поворот, переводящий единичный `a` в единичный `b` (как Quaternion.setFromUnitVectors).
func crewFromTo(_ a: F3, _ b: F3) -> simd_quatf {
    let d = simd_dot(a, b)
    if d > 0.99999 { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
    if d < -0.99999 {
        let ax: F3 = abs(a.x) < 0.9 ? simd_normalize(simd_cross(a, F3(1, 0, 0))) : simd_normalize(simd_cross(a, F3(0, 1, 0)))
        return simd_quatf(angle: .pi, axis: ax)
    }
    return simd_quatf(from: a, to: b)
}

/// Несколько кусков геометрии с номерами материалов → один меш с частями (одна сущность на группу).
struct MeshBatch {
    private(set) var parts: [Int: MeshBuilder] = [:]

    mutating func add(_ b: MeshBuilder, _ m: float4x4? = nil, mat: Int) {
        let piece = m.map { b.transformed($0) } ?? b
        parts[mat, default: MeshBuilder()].append(piece)
    }

    @MainActor
    func makeMesh(name: String) -> MeshResource? {
        var descs: [MeshDescriptor] = []
        for (mat, b) in parts.sorted(by: { $0.key < $1.key }) where !b.isEmpty {
            var d = MeshDescriptor(name: "\(name)-\(mat)")
            d.positions = MeshBuffers.Positions(b.positions)
            d.normals = MeshBuffers.Normals(b.normals)
            d.textureCoordinates = MeshBuffers.TextureCoordinates(b.uvs)
            d.primitives = .triangles(b.indices)
            d.materials = .allFaces(UInt32(mat))
            descs.append(d)
        }
        guard !descs.isEmpty else { return nil }
        return try? MeshResource.generate(from: descs)
    }
}

/// Кэш мешей портретов (общий для всех вьюх и персонажей).
@MainActor
enum CrewMeshCache {
    private static var meshes: [String: MeshResource] = [:]

    static func mesh(_ key: String, _ make: () -> MeshBuilder) -> MeshResource? {
        if let m = meshes[key] { return m }
        guard let m = make().makeMesh(name: key) else { return nil }
        meshes[key] = m
        return m
    }

    static func batch(_ key: String, _ make: () -> MeshBatch) -> MeshResource? {
        if let m = meshes[key] { return m }
        guard let m = make().makeMesh(name: key) else { return nil }
        meshes[key] = m
        return m
    }
}

enum CrewGeo {
    static let tau = Float.pi * 2

    // MARK: - Сферы

    /// Как THREE.SphereGeometry(1, w, h, φ0, Δφ, θ0, Δθ): UV — (j/w, 1 − i/h).
    static func sphere(_ w: Int, _ h: Int, phi0: Float = 0, phiLen: Float = tau,
                       theta0: Float = 0, thetaLen: Float = .pi) -> MeshBuilder {
        var b = MeshBuilder()
        for i in 0...h {
            let v = Float(i) / Float(h)
            let th = theta0 + v * thetaLen
            for j in 0...w {
                let u = Float(j) / Float(w)
                let ph = phi0 + u * phiLen
                let p = F3(-cos(ph) * sin(th), cos(th), sin(ph) * sin(th))
                b.vertex(p, p, SIMD2(u, 1 - v))
            }
        }
        b.gridFaces(rows: h, cols: w, base: 0)
        return b
    }

    static let sphereHi = sphere(32, 22)
    static let sphereLo = sphere(14, 10)

    /// Шапочка сферы с полюсом на +Z (радужка, зрачок, роговица): сегмент θ ≤ `theta`, повёрнутый на π/2 по X.
    static func cap(_ theta: Float) -> MeshBuilder {
        sphere(40, 10, thetaLen: theta).transformed(crewMatrix(.zero, simd_quatf(angle: .pi / 2, axis: F3(1, 0, 0))))
    }

    // MARK: - Сплайн и трубки

    /// Центростремительный сплайн Кэтмулла — Рома (как THREE.CatmullRomCurve3), точки по длине дуги.
    static func path(_ pts: [F3], segments seg: Int) -> [F3] {
        let l = pts.count
        guard l >= 2 else { return pts }
        func point(_ t: Float) -> F3 {
            let p = Float(l - 1) * t
            var ip = Int(p.rounded(.down))
            var w = p - Float(ip)
            if ip >= l - 1 { ip = l - 2; w = 1 }
            let p0 = ip > 0 ? pts[ip - 1] : pts[0] * 2 - pts[1]
            let p1 = pts[ip], p2 = pts[ip + 1]
            let p3 = ip + 2 < l ? pts[ip + 2] : pts[l - 1] * 2 - pts[l - 2]
            var dt0 = pow(simd_length_squared(p1 - p0), 0.25)
            var dt1 = pow(simd_length_squared(p2 - p1), 0.25)
            var dt2 = pow(simd_length_squared(p3 - p2), 0.25)
            if dt1 < 1e-4 { dt1 = 1 }
            if dt0 < 1e-4 { dt0 = dt1 }
            if dt2 < 1e-4 { dt2 = dt1 }
            let a1: F3 = (p1 - p0) / dt0
            let a2: F3 = (p2 - p0) / (dt0 + dt1)
            let a3: F3 = (p2 - p1) / dt1
            let b1: F3 = (p3 - p1) / (dt1 + dt2)
            let b2: F3 = (p3 - p2) / dt2
            let t1: F3 = (a1 - a2 + a3) * dt1
            let t2: F3 = (a3 - b1 + b2) * dt1
            let d21: F3 = p2 - p1
            let c2: F3 = d21 * 3 - t1 * 2 - t2
            let c3: F3 = t1 + t2 - d21 * 2
            let w2 = w * w, w3 = w2 * w
            return p1 + t1 * w + c2 * w2 + c3 * w3
        }
        // Таблица длин (200 делений, как в three.js) → точки через равные длины.
        let div = 200
        var samples: [F3] = []
        var lens: [Float] = [0]
        samples.reserveCapacity(div + 1)
        for k in 0...div {
            let q = point(Float(k) / Float(div))
            if let last = samples.last { lens.append(lens[lens.count - 1] + simd_length(q - last)) }
            samples.append(q)
        }
        let total = max(lens[div], 1e-6)
        var out: [F3] = []
        var k = 0
        for i in 0...seg {
            let target = total * Float(i) / Float(seg)
            while k < div - 1 && lens[k + 1] < target { k += 1 }
            let span = max(lens[k + 1] - lens[k], 1e-9)
            let f = min(1, max(0, (target - lens[k]) / span))
            out.append(samples[k] + (samples[k + 1] - samples[k]) * f)
        }
        return out
    }

    /// Трубка вдоль точек `path` с радиусом `radius(u)`, u = 0…1. Концы открыты (их закрывают шарики).
    static func tube(_ path: [F3], rad: Int = 10, radius: (Float) -> Float) -> MeshBuilder {
        var b = MeshBuilder()
        let n = path.count
        guard n >= 2 else { return b }
        var tangents: [F3] = []
        for i in 0..<n {
            let d = path[min(n - 1, i + 1)] - path[max(0, i - 1)]
            tangents.append(simd_length(d) > 1e-9 ? simd_normalize(d) : (tangents.last ?? F3(0, 1, 0)))
        }
        // Начальная нормаль — как в three.js (ось с наименьшей компонентой касательной), дальше — перенос.
        let t0 = tangents[0]
        let a = F3(abs(t0.x), abs(t0.y), abs(t0.z))
        let axis: F3 = a.x <= a.y && a.x <= a.z ? F3(1, 0, 0) : (a.y <= a.z ? F3(0, 1, 0) : F3(0, 0, 1))
        var nrm = simd_normalize(simd_cross(t0, simd_normalize(simd_cross(t0, axis))))
        for i in 0..<n {
            let t = tangents[i]
            var p = nrm - t * simd_dot(nrm, t)
            if simd_length(p) < 1e-6 { p = nrm }
            nrm = simd_normalize(p)
            let bin = simd_cross(t, nrm)
            let u = Float(i) / Float(n - 1)
            let r = radius(u)
            for j in 0...rad {
                let v = Float(j) / Float(rad) * tau
                let dir = nrm * -cos(v) + bin * sin(v)
                b.vertex(path[i] + dir * r, dir, SIMD2(u, Float(j) / Float(rad)))
            }
        }
        b.gridFaces(rows: n - 1, cols: rad, base: 0)
        return b
    }

    /// Прядь/шланг как `strand` макета: сужение r0 → r1 (степень 1.3), гофра `ripple`.
    static func strand(_ pts: [F3], _ r0: Float, _ r1: Float? = nil, seg: Int = 24, rad: Int = 10, ripple: Float = 0) -> MeshBuilder {
        let r1 = r1 ?? r0
        return tube(path(pts, segments: seg), rad: rad) { u in
            (r0 + (r1 - r0) * pow(u, 1.3)) * (1 + (ripple > 0 ? sin(u * ripple * tau) * 0.18 : 0))
        }
    }

    // MARK: - Тела вращения и прочее

    /// Как THREE.TorusGeometry(R, r, radial, tubular, arc): кольцо в плоскости XY.
    static func torus(_ R: Float, _ r: Float, radial: Int, tubular: Int, arc: Float = tau) -> MeshBuilder {
        var b = MeshBuilder()
        for j in 0...radial {
            let v = Float(j) / Float(radial) * tau
            for i in 0...tubular {
                let u = Float(i) / Float(tubular) * arc
                let p = F3((R + r * cos(v)) * cos(u), (R + r * cos(v)) * sin(u), r * sin(v))
                let c = F3(R * cos(u), R * sin(u), 0)
                b.vertex(p, simd_normalize(p - c), SIMD2(Float(i) / Float(tubular), Float(j) / Float(radial)))
            }
        }
        b.gridFaces(rows: radial, cols: tubular, base: 0)
        return b
    }

    static let rim = torus(1, 0.1, radial: 14, tubular: 48)

    /// Как THREE.CylinderGeometry(rTop, rBottom, h, radial, 1, open): ось Y, центр в нуле.
    static func cylinder(_ rt: Float, _ rb: Float, _ h: Float, radial: Int, open: Bool = false) -> MeshBuilder {
        var b = MeshBuilder()
        let slope = (rb - rt) / h
        for y in 0...1 {
            let v = Float(y)
            let r = v * (rb - rt) + rt
            for x in 0...radial {
                let u = Float(x) / Float(radial)
                let th = u * tau
                let n = simd_normalize(F3(sin(th), slope, cos(th)))
                b.vertex(F3(r * sin(th), -v * h + h / 2, r * cos(th)), n, SIMD2(u, 1 - v))
            }
        }
        b.gridFaces(rows: 1, cols: radial, base: 0)
        if !open {
            for (y, r, s) in [(h / 2, rt, Float(1)), (-h / 2, rb, Float(-1))] where r > 0 {
                let n = F3(0, s, 0)
                let c = b.vertex(F3(0, y, 0), n, SIMD2(0.5, 0.5))
                var ring: [UInt32] = []
                for x in 0..<radial {
                    let th = Float(x) / Float(radial) * tau
                    ring.append(b.vertex(F3(r * sin(th), y, r * cos(th)), n, SIMD2(0.5 + 0.5 * sin(th), 0.5 + 0.5 * cos(th))))
                }
                for x in 0..<radial { b.tri(c, ring[x], ring[(x + 1) % radial], facing: n) }
            }
        }
        return b
    }

    /// Скруглённый брусок w × h × d с радиусом скругления r (без острых рёбер), центр в нуле.
    static func roundedBox(_ w: Float, _ h: Float, _ d: Float, _ r0: Float) -> MeshBuilder {
        let half = F3(w, h, d) / 2
        let r = max(0.0005, min(r0, half.x - 0.001, half.y - 0.001, half.z - 0.001))
        let e = half - F3(repeating: r)
        // Координаты сетки по оси: плоская часть и полосы скругления (по 3 шага).
        func coords(_ k: Int) -> [Float] {
            let ek = e[k] / half[k]
            var c: [Float] = []
            for s in 0...3 { c.append(-1 + (1 - ek) * Float(s) / 3) }
            for s in 0...3 { c.append(ek + (1 - ek) * Float(s) / 3) }
            return c
        }
        var b = MeshBuilder()
        for axis in 0..<3 {
            let ua = (axis + 1) % 3, va = (axis + 2) % 3
            let cu = coords(ua), cv = coords(va)
            for s: Float in [1, -1] {
                let base = UInt32(b.positions.count)
                for i in 0..<cv.count {
                    for j in 0..<cu.count {
                        var c = F3.zero
                        c[axis] = s
                        c[ua] = cu[j]
                        c[va] = cv[i]
                        let q = c * half
                        let inner = simd_clamp(q, -e, e)
                        var n = q - inner
                        n = simd_length(n) > 1e-7 ? simd_normalize(n) : F3.zero
                        if n == .zero { n[axis] = s }
                        b.vertex(inner + n * r, n, SIMD2((cu[j] + 1) / 2, (cv[i] + 1) / 2))
                    }
                }
                b.gridFaces(rows: cv.count - 1, cols: cu.count - 1, base: base)
            }
        }
        return b
    }

    /// Плоскость 1 × 1 в XY, нормаль +Z, UV 0…1.
    static let plane: MeshBuilder = {
        var b = MeshBuilder()
        let n = F3(0, 0, 1)
        let a = b.vertex(F3(-0.5, -0.5, 0), n, SIMD2(0, 0))
        let c = b.vertex(F3(0.5, -0.5, 0), n, SIMD2(1, 0))
        let d = b.vertex(F3(0.5, 0.5, 0), n, SIMD2(1, 1))
        let e = b.vertex(F3(-0.5, 0.5, 0), n, SIMD2(0, 1))
        b.quad(a, c, d, e, facing: n)
        return b
    }()

    /// Круг/сектор (как THREE.CircleGeometry) в XY, UV по описанному квадрату.
    static func circle(_ r: Float, segments: Int, start: Float = 0, length: Float = tau) -> MeshBuilder {
        var b = MeshBuilder()
        let n = F3(0, 0, 1)
        let c = b.vertex(.zero, n, SIMD2(0.5, 0.5))
        var ring: [UInt32] = []
        for s in 0...segments {
            let a = start + Float(s) / Float(segments) * length
            ring.append(b.vertex(F3(cos(a) * r, sin(a) * r, 0), n, SIMD2(0.5 + 0.5 * cos(a), 0.5 + 0.5 * sin(a))))
        }
        for s in 0..<segments { b.tri(c, ring[s], ring[s + 1], facing: n) }
        return b
    }

    /// Пятиконечная звёздочка с толщиной (вместо выдавливания с фаской), радиус ~1.15.
    static let star: MeshBuilder = {
        var poly: [SIMD2<Float>] = []
        for i in 0..<10 {
            let a = Float(i) / 10 * tau + .pi / 2
            let r: Float = i % 2 == 1 ? 0.55 : 1.15
            poly.append(SIMD2(cos(a) * r, sin(a) * r))
        }
        var b = MeshBuilder()
        let t: Float = 0.28
        for s: Float in [1, -1] {
            let n = F3(0, 0, s)
            let c = b.vertex(F3(0, 0, s * t * 1.3), n)
            let ids = poly.map { b.vertex(F3($0.x, $0.y, s * t), n) }
            for k in 0..<10 { b.tri(c, ids[k], ids[(k + 1) % 10], facing: n) }
        }
        for k in 0..<10 {
            let p = poly[k], q = poly[(k + 1) % 10]
            let e = q - p
            let nn = simd_normalize(F3(e.y, -e.x, 0))
            let i0 = b.vertex(F3(p.x, p.y, -t), nn), i1 = b.vertex(F3(q.x, q.y, -t), nn)
            let i2 = b.vertex(F3(q.x, q.y, t), nn), i3 = b.vertex(F3(p.x, p.y, t), nn)
            let mid = (p + q) / 2
            let out = F3(mid.x, mid.y, 0)
            b.quad(i0, i1, i2, i3, facing: simd_dot(nn, out) >= 0 ? nn : -nn)
        }
        return b
    }()

    /// Узел-жгут (THREE.TorusKnotGeometry(R, r, 120, 16, p, q)) — пучок Миры.
    static func torusKnot(_ R: Float, _ r: Float, p: Float, q: Float) -> MeshBuilder {
        var pts: [F3] = []
        let seg = 120
        for i in 0...seg {
            let u = Float(i) / Float(seg) * p * tau
            let qu = q / p * u
            let cs = cos(qu)
            pts.append(F3(R * (2 + cs) * 0.5 * cos(u), R * (2 + cs) * sin(u) * 0.5, R * sin(qu) * 0.5))
        }
        return tube(pts, rad: 16) { _ in r }
    }
}
