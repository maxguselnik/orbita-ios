import RealityKit
import simd

/// Процедурная сборка мешей: вершины, нормали, UV, треугольники.
/// Ориентация треугольников выбирается по ожидаемой нормали — порядок обхода не важен вызывающему.
struct MeshBuilder: Sendable {
    /// Лицевая сторона RealityKit — обход против часовой стрелки.
    static let frontCCW = true

    var positions: [F3] = []
    var normals: [F3] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []

    var isEmpty: Bool { indices.isEmpty }

    @discardableResult
    mutating func vertex(_ p: F3, _ n: F3, _ uv: SIMD2<Float> = .zero) -> UInt32 {
        positions.append(p)
        normals.append(n)
        uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    /// Треугольник, лицевой стороной к `facing`.
    mutating func tri(_ a: UInt32, _ b: UInt32, _ c: UInt32, facing n: F3) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        let g = simd_cross(pb - pa, pc - pa)
        let ccw = simd_dot(g, n) >= 0
        if ccw == Self.frontCCW {
            indices += [a, b, c]
        } else {
            indices += [a, c, b]
        }
    }

    /// Четырёхугольник a-b-c-d (по контуру), лицевой стороной к `facing`.
    mutating func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, facing n: F3) {
        tri(a, b, c, facing: n)
        tri(a, c, d, facing: n)
    }

    /// Параллелепипед: центр и полуоси.
    mutating func box(center c: F3, x: F3, y: F3, z: F3, uv: SIMD2<Float> = .zero) {
        let axes = [x, y, z]
        for k in 0..<3 {
            let n = axes[k], u = axes[(k + 1) % 3], v = axes[(k + 2) % 3]
            let nn = simd_normalize(n)
            for s: Float in [1, -1] {
                let fc = c + n * s
                let i0 = vertex(fc - u - v, nn * s, uv)
                let i1 = vertex(fc + u - v, nn * s, uv)
                let i2 = vertex(fc + u + v, nn * s, uv)
                let i3 = vertex(fc - u + v, nn * s, uv)
                quad(i0, i1, i2, i3, facing: nn * s)
            }
        }
    }

    /// Брус между точками `a` и `b` квадратного сечения `t`.
    mutating func beam(_ a: F3, _ b: F3, thickness t: Float, uv: SIMD2<Float> = .zero) {
        let d = b - a
        let len = simd_length(d)
        guard len > 1e-4 else { return }
        let ax = d / len
        let hint: F3 = abs(ax.y) < 0.9 ? F3(0, 1, 0) : F3(1, 0, 0)
        let side = simd_normalize(simd_cross(ax, hint))
        let up = simd_cross(side, ax)
        box(center: (a + b) * 0.5, x: ax * (len * 0.5), y: side * (t * 0.5), z: up * (t * 0.5), uv: uv)
    }

    /// Тело вращения вокруг оси Y. `profile` — точки (радиус, высота) снизу вверх.
    /// Нормали — по сегментам профиля (гладко по окружности).
    mutating func lathe(_ profile: [SIMD2<Float>], segments: Int, y0: Float = 0, twoSided: Bool = false,
                        uv: SIMD2<Float>? = nil, segmentFilter: ((Int) -> Bool)? = nil) {
        guard profile.count >= 2 else { return }
        for k in 0..<(profile.count - 1) {
            let p0 = profile[k], p1 = profile[k + 1]
            let t = p1 - p0
            let tl = simd_length(t)
            guard tl > 1e-6 else { continue }
            let n2 = SIMD2<Float>(t.y, -t.x) / tl
            for s in 0..<segments {
                if let f = segmentFilter, !f(s) { continue }
                let a0 = Float(s) / Float(segments) * 2 * .pi
                let a1 = Float(s + 1) / Float(segments) * 2 * .pi
                let c0 = cos(a0), s0 = sin(a0), c1 = cos(a1), s1 = sin(a1)
                let q00 = F3(p0.x * c0, p0.y + y0, p0.x * s0)
                let q01 = F3(p0.x * c1, p0.y + y0, p0.x * s1)
                let q10 = F3(p1.x * c0, p1.y + y0, p1.x * s0)
                let q11 = F3(p1.x * c1, p1.y + y0, p1.x * s1)
                let n0 = F3(n2.x * c0, n2.y, n2.x * s0)
                let n1 = F3(n2.x * c1, n2.y, n2.x * s1)
                let nm = simd_normalize(n0 + n1)
                let uv00 = uv ?? SIMD2(Float(s) / Float(segments), Float(k) / Float(profile.count - 1))
                let uv11 = uv ?? SIMD2(Float(s + 1) / Float(segments), Float(k + 1) / Float(profile.count - 1))
                let i0 = vertex(q00, n0, uv00)
                let i1 = vertex(q01, n1, SIMD2(uv11.x, uv00.y))
                let i2 = vertex(q11, n1, uv11)
                let i3 = vertex(q10, n0, SIMD2(uv00.x, uv11.y))
                // Вырожденные стороны (радиус 0) дают нулевые треугольники — безвредно.
                quad(i0, i1, i2, i3, facing: nm)
                if twoSided {
                    let j0 = vertex(q00, -n0, uv00)
                    let j1 = vertex(q01, -n1, SIMD2(uv11.x, uv00.y))
                    let j2 = vertex(q11, -n1, uv11)
                    let j3 = vertex(q10, -n0, SIMD2(uv00.x, uv11.y))
                    quad(j0, j1, j2, j3, facing: -nm)
                }
            }
        }
    }

    /// Выпуклый многоугольник `poly` (в плоскости XY) с толщиной ±`halfThickness` по Z.
    mutating func prism(_ poly: [SIMD2<Float>], halfThickness t: Float) {
        let n = poly.count
        guard n >= 3 else { return }
        var c = SIMD2<Float>.zero
        for p in poly { c += p }
        c /= Float(n)
        for sgn: Float in [1, -1] {
            let nz = F3(0, 0, sgn)
            let ids = poly.map { vertex(F3($0.x, $0.y, sgn * t), nz) }
            for k in 1..<(n - 1) { tri(ids[0], ids[k], ids[k + 1], facing: nz) }
        }
        for k in 0..<n {
            let a = poly[k], b = poly[(k + 1) % n]
            let e = b - a
            var nrm = SIMD2<Float>(e.y, -e.x)
            if simd_dot(nrm, (a + b) / 2 - c) < 0 { nrm = -nrm }
            let nn = simd_normalize(F3(nrm.x, nrm.y, 0))
            let i0 = vertex(F3(a.x, a.y, -t), nn), i1 = vertex(F3(b.x, b.y, -t), nn)
            let i2 = vertex(F3(b.x, b.y, t), nn), i3 = vertex(F3(a.x, a.y, t), nn)
            quad(i0, i1, i2, i3, facing: nn)
        }
    }

    /// Плоский диск в плоскости XY (нормаль +Z).
    mutating func disc(radius: Float, segments: Int, uv: SIMD2<Float> = .zero) {
        let n = F3(0, 0, 1)
        let c = vertex(.zero, n, uv)
        var ring: [UInt32] = []
        for s in 0..<segments {
            let a = Float(s) / Float(segments) * 2 * .pi
            ring.append(vertex(F3(cos(a) * radius, sin(a) * radius, 0), n, uv))
        }
        for s in 0..<segments {
            tri(c, ring[s], ring[(s + 1) % segments], facing: n)
        }
    }

    func translated(_ t: F3) -> MeshBuilder {
        var out = self
        out.positions = positions.map { $0 + t }
        return out
    }

    mutating func append(_ other: MeshBuilder) {
        let base = UInt32(positions.count)
        positions += other.positions
        normals += other.normals
        uvs += other.uvs
        indices += other.indices.map { $0 + base }
    }

    @MainActor
    func makeMesh(name: String = "mesh") -> MeshResource? {
        guard !indices.isEmpty else { return nil }
        var d = MeshDescriptor(name: name)
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        d.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [d])
    }
}
