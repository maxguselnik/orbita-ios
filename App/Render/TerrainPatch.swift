import OrbitPhysics
import simd

/// Узел квадродерева кубосферы: грань, уровень, координаты на уровне.
struct PatchKey: Hashable, Sendable {
    var body: BodyID
    var face: UInt8
    var level: UInt8
    var x: UInt32
    var y: UInt32

    func child(_ i: Int) -> PatchKey {
        PatchKey(body: body, face: face, level: level + 1,
                 x: x * 2 + UInt32(i & 1), y: y * 2 + UInt32(i >> 1))
    }
}

/// Кубосфера: грань → направление. Перекос `tan` выравнивает размер ячеек.
enum CubeSphere {
    struct Face: Sendable {
        let n: D3
        let u: D3
        let v: D3
    }

    /// u × v = n — правая тройка, нормаль наружу.
    static let faces: [Face] = [
        Face(n: D3(1, 0, 0), u: D3(0, 1, 0), v: D3(0, 0, 1)),
        Face(n: D3(-1, 0, 0), u: D3(0, 0, 1), v: D3(0, 1, 0)),
        Face(n: D3(0, 1, 0), u: D3(0, 0, 1), v: D3(1, 0, 0)),
        Face(n: D3(0, -1, 0), u: D3(1, 0, 0), v: D3(0, 0, 1)),
        Face(n: D3(0, 0, 1), u: D3(1, 0, 0), v: D3(0, 1, 0)),
        Face(n: D3(0, 0, -1), u: D3(0, 1, 0), v: D3(1, 0, 0)),
    ]

    static func direction(face: Int, a: Double, b: Double) -> D3 {
        let f = faces[face]
        let ca = tan(a * .pi / 4), cb = tan(b * .pi / 4)
        return simd_normalize(f.n + ca * f.u + cb * f.v)
    }

    /// Нижний левый угол узла и его сторона в координатах грани [-1, 1].
    static func range(_ k: PatchKey) -> (a0: Double, b0: Double, span: Double) {
        let span = 2 / Double(1 << Int(k.level))
        return (-1 + Double(k.x) * span, -1 + Double(k.y) * span, span)
    }

    static func centerDirection(_ k: PatchKey) -> D3 {
        let r = range(k)
        return direction(face: Int(k.face), a: r.a0 + r.span / 2, b: r.b0 + r.span / 2)
    }

    /// Характерный размер узла по поверхности, м.
    static func size(_ k: PatchKey, radius: Double) -> Double {
        radius * (.pi / 2) / Double(1 << Int(k.level))
    }
}

/// Готовая геометрия патча (вычисляется вне главного потока).
struct PatchGeometry: Sendable {
    var mesh: MeshBuilder
    /// Центр патча в системе, связанной с телом (вершины — относительно него).
    var center: D3
}

enum PatchBuilder {
    /// Ячеек по стороне патча.
    static let cells = 16

    /// Отображаемая высота поверхности: океан Терры — уровень 0.
    static func displayHeight(_ body: BodyID, _ h: Double) -> Double {
        body == .terra ? max(0, h) : h
    }

    static func build(_ key: PatchKey) -> PatchGeometry {
        let body = key.body
        let radius = Bodies.body(body).radius
        let n = cells
        let w = n + 3
        let (a0, b0, span) = CubeSphere.range(key)
        let face = Int(key.face)
        let center = CubeSphere.centerDirection(key) * radius

        var pts = [D3](repeating: .zero, count: w * w)
        var dirs = [D3](repeating: .zero, count: w * w)
        var hts = [Double](repeating: 0, count: w * w)
        for j in 0..<w {
            for i in 0..<w {
                let a = a0 + span * Double(i - 1) / Double(n)
                let b = b0 + span * Double(j - 1) / Double(n)
                let d = CubeSphere.direction(face: face, a: a, b: b)
                let h = Terrain.height(body: body, direction: vec3(d))
                let k = j * w + i
                dirs[k] = d
                hts[k] = h
                pts[k] = d * (radius + displayHeight(body, h))
            }
        }

        var mesh = MeshBuilder()
        mesh.positions.reserveCapacity((n + 1) * (n + 1) + 8 * (n + 1))
        mesh.normals.reserveCapacity(mesh.positions.capacity)
        mesh.uvs.reserveCapacity(mesh.positions.capacity)
        mesh.indices.reserveCapacity(n * n * 6 + 4 * n * 12)
        let noiseScale = radius / (body == .terra ? 900 : 300)
        let cellSize = CubeSphere.size(key, radius: radius) / Double(n)

        for j in 0...n {
            for i in 0...n {
                let k = (j + 1) * w + (i + 1)
                let d = dirs[k], h = hts[k]
                var normal: D3
                if body == .terra && h < 0 {
                    normal = d
                } else {
                    let du = pts[k + 1] - pts[k - 1]
                    let dv = pts[k + w] - pts[k - w]
                    normal = simd_normalize(simd_cross(du, dv))
                    if simd_dot(normal, d) < 0 { normal = -normal }
                }
                let uv = Palette.terrainUV(body: body, direction: d, height: h,
                                           noise: hashNoise(d, scale: noiseScale), cell: cellSize,
                                           slope: 1 - simd_dot(normal, d),
                                           craterShade: body == .luna ? Terrain.craterShade(body: body, direction: vec3(d)) : 0)
                mesh.vertex(f3(pts[k] - center), f3(normal), uv)
            }
        }
        let row = UInt32(n + 1)
        let ccw = MeshBuilder.frontCCW
        for j in 0..<n {
            for i in 0..<n {
                let v00 = UInt32(j) * row + UInt32(i)
                let v10 = v00 + 1, v01 = v00 + row, v11 = v01 + 1
                // u × v смотрит наружу: (v00, v10, v11) — против часовой снаружи.
                if ccw {
                    mesh.indices += [v00, v10, v11, v00, v11, v01]
                } else {
                    mesh.indices += [v00, v11, v10, v00, v01, v11]
                }
            }
        }

        // Юбки по краям против щелей между уровнями детализации.
        let skirt = Float(CubeSphere.size(key, radius: radius) * (body == .terra ? 0.04 : 0.12) + 15)
        var edges: [[UInt32]] = [[], [], [], []]
        for t in 0...n {
            edges[0].append(UInt32(t))                       // низ (j = 0)
            edges[1].append(UInt32(n) * row + UInt32(t))     // верх
            edges[2].append(UInt32(t) * row)                 // левый (i = 0)
            edges[3].append(UInt32(t) * row + UInt32(n))     // правый
        }
        for edge in edges {
            var lowered: [UInt32] = []
            for v in edge {
                let p = mesh.positions[Int(v)]
                let dir = simd_normalize(p + f3(center))
                lowered.append(mesh.vertex(p - dir * skirt, mesh.normals[Int(v)], mesh.uvs[Int(v)]))
            }
            for t in 0..<n {
                let a = edge[t], b = edge[t + 1], c = lowered[t + 1], d = lowered[t]
                // Обе стороны — порядок обхода не важен.
                mesh.indices += [a, b, c, a, c, d, a, c, b, a, d, c]
            }
        }
        return PatchGeometry(mesh: mesh, center: center)
    }
}
