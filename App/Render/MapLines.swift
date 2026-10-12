import OrbitPhysics
import simd

/// Стиль линии карты: текущая орбита / после узла; обычная, встреча с Луной, возврат к Терре.
enum MapLineStyle: Int, CaseIterable, Sendable {
    case current, encounter, back
    case plan, planEncounter, planBack
    /// Служебные: орбита Луны и граница SOI Луны.
    case lunaOrbit, lunaSOI

    var isPlan: Bool { self == .plan || self == .planEncounter || self == .planBack }

    var rgb: SIMD3<Double> {
        switch self {
        case .current: SIMD3(0.45, 0.82, 1.0)
        case .encounter: SIMD3(0.78, 0.40, 1.0)
        case .back: SIMD3(1.0, 0.55, 0.12)
        case .plan: SIMD3(1.0, 0.86, 0.30)
        case .planEncounter: SIMD3(0.92, 0.62, 1.0)
        case .planBack: SIMD3(1.0, 0.42, 0.22)
        case .lunaOrbit: SIMD3(0.50, 0.52, 0.58)
        case .lunaSOI: SIMD3(0.55, 0.38, 0.85)
        }
    }

    /// Толщина линии, экранные точки.
    var width: Double {
        switch self {
        case .current, .encounter, .back: 2.6
        case .plan, .planEncounter, .planBack: 2.2
        case .lunaOrbit, .lunaSOI: 1.3
        }
    }

    /// Стиль участка `index` траектории: первый — обычный, у Луны — встреча, дальше у Терры — возврат.
    static func patch(_ index: Int, body: BodyID, plan: Bool) -> MapLineStyle {
        if index == 0 { return plan ? .plan : .current }
        switch body {
        case .luna: return plan ? .planEncounter : .encounter
        case .terra: return plan ? .planBack : .back
        }
    }
}

/// Ломаная карты: точки в инерциальной системе Терры (единицы карты) и время каждой точки.
struct MapPolyline: Sendable {
    var style: MapLineStyle
    var points: [D3]
    var times: [Double]
    /// Нормаль плоскости линии (для ориентации сечения трубки).
    var normal: D3
}

enum MapLines {
    /// Точек на участок траектории.
    static let pointsPerPatch = 192
    /// Пунктир: точек в штрихе и в промежутке.
    static let dashOn = 4
    static let dashOff = 3

    /// Ломаные участков траектории. `lunaMap` — положение Луны (единицы карты) на время снимка:
    /// участки у Луны рисуются вокруг её текущего положения, как в KSP.
    static func polylines(_ trajectory: Trajectory, plan: Bool, lunaMap: D3) -> [MapPolyline] {
        var out: [MapPolyline] = []
        let unit = MapScale.metersPerUnit
        for (i, p) in trajectory.patches.enumerated() {
            let span: Double
            if p.endTime.isFinite {
                span = p.endTime - p.startTime
            } else if p.elements.period.isFinite {
                span = p.elements.period
            } else {
                span = 6e5
            }
            guard span.isFinite, span > 0 else { continue }
            let n = pointsPerPatch
            let offset = p.body == .luna ? lunaMap : .zero
            var pts: [D3] = []
            var times: [Double] = []
            pts.reserveCapacity(n + 1)
            times.reserveCapacity(n + 1)
            for k in 0...n {
                let t = p.startTime + span * Double(k) / Double(n)
                let s = p.state(at: t)
                let q = s.position.d3 / unit + offset
                guard q.x.isFinite, q.y.isFinite, q.z.isFinite else { break }
                pts.append(q)
                times.append(t)
            }
            guard pts.count >= 2 else { continue }
            let normal = simd_cross(p.start.position.d3, p.start.velocity.d3)
            out.append(MapPolyline(style: MapLineStyle.patch(i, body: p.body, plan: plan), points: pts, times: times,
                                   normal: simd_length_squared(normal) > 0 ? simd_normalize(normal) : D3(0, 0, 1)))
        }
        return out
    }

    /// Окружность в плоскости XY.
    static func circle(radius: Double, segments: Int, style: MapLineStyle) -> MapPolyline {
        var pts: [D3] = []
        pts.reserveCapacity(segments + 1)
        for k in 0...segments {
            let a = 2 * Double.pi * Double(k) / Double(segments)
            pts.append(D3(cos(a), sin(a), 0) * radius)
        }
        return MapPolyline(style: style, points: pts, times: [], normal: D3(0, 0, 1))
    }

    /// Трубка квадратного сечения радиуса `radius` вдоль `line`; пунктир — у орбит после узла.
    static func append(_ line: MapPolyline, radius: Double, to m: inout MeshBuilder) {
        let pts = line.points
        guard pts.count >= 2 else { return }
        if line.style.isPlan {
            var i = 0
            while i < pts.count - 1 {
                tube(pts, from: i, to: min(i + dashOn, pts.count - 1), normal: line.normal, radius: radius, into: &m)
                i += dashOn + dashOff
            }
        } else {
            tube(pts, from: 0, to: pts.count - 1, normal: line.normal, radius: radius, into: &m)
        }
    }

    /// Кольца из 4 вершин в каждой точке, сечение ориентировано по нормали плоскости (без закрутки).
    private static func tube(_ pts: [D3], from i0: Int, to i1: Int, normal n: D3, radius r: Double,
                             into m: inout MeshBuilder) {
        guard i1 > i0 else { return }
        let base = UInt32(m.positions.count)
        for i in i0...i1 {
            let prev = pts[max(i0, i - 1)], next = pts[min(i1, i + 1)]
            var t = next - prev
            let tl = simd_length(t)
            t = tl > 1e-12 ? t / tl : D3(1, 0, 0)
            // a ⟂ t, b = t × a, тогда a × b = t: обход (A, B, C), (A, C, D) — против часовой снаружи.
            let a = perpendicular(n, to: t)
            let b = simd_cross(t, a)
            let p = pts[i]
            func corner(_ dir: D3) {
                m.positions.append(f3(p + dir * r))
                m.normals.append(f3(dir))
                m.uvs.append(.zero)
            }
            corner(a)
            corner(b)
            corner(-a)
            corner(-b)
        }
        for s in 0..<(i1 - i0) {
            let r0 = base + UInt32(s * 4), r1 = r0 + 4
            for k in UInt32(0)..<4 {
                let k1 = (k + 1) % 4
                let a = r0 + k, b = r0 + k1, c = r1 + k1, d = r1 + k
                if MeshBuilder.frontCCW {
                    m.indices += [a, b, c, a, c, d]
                } else {
                    m.indices += [a, c, b, a, d, c]
                }
            }
        }
    }
}
