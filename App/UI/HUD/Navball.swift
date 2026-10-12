import OrbitPhysics
import simd
import SwiftUI

/// Навбол снизу по центру: шкала скорости/курса (тап — орбита/поверхность), 3D-сфера,
/// слева от сферы — переключатель режима камеры и плашка узла манёвра.
struct NavballView: View {
    let model: FlightHUDModel

    static let diameter: CGFloat = 124

    var body: some View {
        let t = model.telemetry
        let frame = model.speedFrame(for: t)
        VStack(spacing: 4) {
            NavballReadout(telemetry: t, frame: frame) {
                model.toggleSpeedFrame()
            }
            NavballSphere(telemetry: t, frame: frame)
                .frame(width: Self.diameter, height: Self.diameter)
                .overlay(alignment: .bottomLeading) {
                    // Слева от сферы: плашка узла манёвра (если есть) над кнопкой камеры.
                    VStack(alignment: .trailing, spacing: 6) {
                        if let status = t.maneuver {
                            ManeuverBadge(status: status) { model.toggleMap() }
                        }
                        CameraModeButton(model: model)
                    }
                    .fixedSize()
                    .alignmentGuide(.leading) { $0[.trailing] + 12 }
                }
        }
    }
}

/// Скорость в выбранной системе и курс. Тап — орбита ↔ поверхность.
struct NavballReadout: View {
    let telemetry: FlightTelemetry
    let frame: SpeedFrame
    let onTap: () -> Void

    var body: some View {
        let speed = frame == .orbit ? telemetry.speed : telemetry.surfaceSpeed
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(frame == .orbit ? "ОРБ" : "ПОВ")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(frame == .orbit ? HUDStyle.active : NavballPalette.prograde,
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(HUDFormat.speed(speed))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                Text(HUDFormat.heading(telemetry.heading))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(HUDStyle.secondaryText)
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minWidth: 150, minHeight: 30)
            .hudBackground(corner: 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(frame == .orbit ? "Орбитальная скорость \(HUDFormat.speed(speed))"
                                            : "Скорость относительно поверхности \(HUDFormat.speed(speed))")
        .accessibilityHint("Переключить орбита или поверхность")
    }
}

/// Кнопка режима камеры: одно нажатие — следующий режим по кругу.
struct CameraModeButton: View {
    let model: FlightHUDModel

    static let width: CGFloat = 52

    var body: some View {
        let mode = model.cameraMode
        Button {
            model.cycleCameraMode()
        } label: {
            VStack(spacing: 1) {
                Image(systemName: Self.symbol(mode))
                    .font(.system(size: 16, weight: .semibold))
                Text(Self.shortName(mode))
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
            }
            .frame(width: Self.width, height: 48)
        }
        .buttonStyle(HUDButtonStyle())
        .accessibilityLabel("Камера: \(Self.fullName(mode))")
        .accessibilityHint("Переключить режим камеры")
    }

    static func symbol(_ mode: CameraMode) -> String {
        switch mode {
        case .free: "rotate.3d"
        case .follow: "scope"
        case .heading: "location.north.line"
        }
    }

    static func shortName(_ mode: CameraMode) -> String {
        switch mode {
        case .free: "СВОБ"
        case .follow: "СЛЕД"
        case .heading: "КУРС"
        }
    }

    static func fullName(_ mode: CameraMode) -> String {
        switch mode {
        case .free: "свободная"
        case .follow: "следование"
        case .heading: "по курсу"
        }
    }
}

enum NavballPalette {
    static let sky = Color(red: 0.20, green: 0.46, blue: 0.80)
    static let ground = Color(red: 0.58, green: 0.36, blue: 0.18)
    static let prograde = Color(red: 0.85, green: 0.95, blue: 0.2)
    static let normal = Color(red: 0.90, green: 0.45, blue: 1.0)
    static let radial = Color(red: 0.35, green: 0.88, blue: 1.0)
    static let maneuver = Color(red: 0.25, green: 0.55, blue: 1.0)
}

// MARK: - Сфера

/// 3D-навбол: сфера горизонта (небо/земля), сетка тангажа и курса, маркеры направлений.
/// Ортографическая проекция видимой полусферы, вид вдоль носа: вправо — правый борт (+X),
/// вверх — спина (+Z). Рисуется одним Canvas, без 3D-движка.
struct NavballSphere: View {
    let telemetry: FlightTelemetry
    let frame: SpeedFrame

    var body: some View {
        let basis = NavballGeometry.Basis(pitch: telemetry.pitch, heading: telemetry.heading, roll: telemetry.roll)
        let markers = Self.markers(telemetry, frame: frame)
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                Canvas { context, size in
                    NavballGeometry.draw(in: &context, size: size, basis: basis)
                }

                // Объём: блик сверху-слева и затемнение к краю.
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.45)],
                                         center: UnitPoint(x: 0.38, y: 0.32),
                                         startRadius: 0, endRadius: r * 1.15))

                ForEach(markers, id: \.mode) { marker in
                    SASIcon(mode: marker.mode)
                        .foregroundStyle(marker.color)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black, radius: 1.5)
                        .offset(x: r * CGFloat(marker.vector.x), y: -r * CGFloat(marker.vector.z))
                }

                NoseMarker()
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.8), radius: 1.5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 2))
        .background(Circle().fill(.black.opacity(0.55)).padding(-5))
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Навбол: тангаж \(Int((telemetry.pitch * 180 / .pi).rounded()))°, курс \(HUDFormat.heading(telemetry.heading)), крен \(Int((telemetry.roll * 180 / .pi).rounded()))°")
    }

    struct Marker {
        let mode: SASMode
        let vector: Vec3
        let color: Color
    }

    /// Маркеры на видимой (передней) полусфере.
    static func markers(_ t: FlightTelemetry, frame: SpeedFrame) -> [Marker] {
        let n = t.navball
        let speedVector = frame == .surface ? (n.surfacePrograde ?? n.prograde) : n.prograde
        let candidates: [(SASMode, Vec3?, Color)] = [
            (.prograde, speedVector, NavballPalette.prograde),
            (.retrograde, speedVector.map { -$0 }, NavballPalette.prograde),
            (.normal, n.normal, NavballPalette.normal),
            (.antiNormal, n.normal.map { -$0 }, NavballPalette.normal),
            (.radialOut, n.radialOut, NavballPalette.radial),
            (.radialIn, n.radialOut.map { -$0 }, NavballPalette.radial),
            (.maneuver, n.maneuver, NavballPalette.maneuver),
        ]
        return candidates.compactMap { mode, vector, color in
            guard let vector, vector.y > 0.02 else { return nil }
            return Marker(mode: mode, vector: vector, color: color)
        }
    }
}

/// Неподвижный значок носа: «крылья» и галочка в центре.
struct NoseMarker: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: CGPoint(x: c.x - 22, y: c.y))
        p.addLine(to: CGPoint(x: c.x - 9, y: c.y))
        p.addLine(to: CGPoint(x: c.x - 4, y: c.y + 6))
        p.addLine(to: CGPoint(x: c.x, y: c.y))
        p.addLine(to: CGPoint(x: c.x + 4, y: c.y + 6))
        p.addLine(to: CGPoint(x: c.x + 9, y: c.y))
        p.addLine(to: CGPoint(x: c.x + 22, y: c.y))
        p.move(to: CGPoint(x: c.x, y: c.y - 3))
        p.addLine(to: CGPoint(x: c.x, y: c.y - 3))
        return p
    }
}

// MARK: - Геометрия

/// Проекция сферы горизонта. Мировые направления — в осях (восток, север, вверх),
/// эта тройка правая (E × N = U), как в физике (east = north × up).
enum NavballGeometry {
    typealias V = SIMD3<Double>

    /// Оси корабля в осях (E, N, U) по тангажу, курсу и крену — те же формулы, что в физике.
    struct Basis {
        let right: V
        let nose: V
        let top: V

        init(pitch: Double, heading: Double, roll: Double) {
            let cp = cos(pitch)
            let nose = simd_normalize(V(cp * sin(heading), cp * cos(heading), sin(pitch)))
            let up = V(0, 0, 1)
            let horizUp0 = up - nose * simd_dot(nose, up)
            // Нос вертикален: опора — юг (на площадке крен 0).
            let horizUp = simd_length(horizUp0) > 1e-3 ? simd_normalize(horizUp0) : V(0, -1, 0)
            // roll > 0 — правый борт вниз: спина поворачивается к правому борту.
            let top = horizUp * cos(roll) + simd_cross(nose, horizUp) * sin(roll)
            self.nose = nose
            self.top = top
            self.right = simd_cross(nose, top)
        }

        /// Направление в осях корабля: (правый борт, нос, спина).
        func local(_ w: V) -> V {
            V(simd_dot(w, right), simd_dot(w, nose), simd_dot(w, top))
        }
    }

    static func direction(latitude: Double, heading: Double) -> V {
        let c = cos(latitude)
        return V(c * sin(heading), c * cos(heading), sin(latitude))
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, basis: Basis) {
        let r = min(size.width, size.height) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func project(_ l: V) -> CGPoint {
            CGPoint(x: c.x + r * CGFloat(l.x), y: c.y - r * CGFloat(l.z))
        }
        let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))

        // Небо и земля.
        context.fill(disc, with: .color(NavballPalette.sky))
        if let ground = groundPath(basis: basis, project: project, center: c, radius: r) {
            context.fill(ground, with: .color(NavballPalette.ground))
        } else if basis.nose.z < 0 {
            context.fill(disc, with: .color(NavballPalette.ground))
        }

        // Параллели тангажа каждые 10°, крупные — 30°.
        for deg in stride(from: -80, through: 80, by: 10) where deg != 0 {
            let lat = Double(deg) * .pi / 180
            let line = polyline(count: 96, basis: basis, project: project) { i in
                direction(latitude: lat, heading: Double(i) / 96 * 2 * .pi)
            }
            let major = deg % 30 == 0
            context.stroke(line, with: .color(.white.opacity(major ? 0.55 : 0.25)), lineWidth: major ? 1.2 : 0.7)
        }
        // Меридианы курса каждые 30°, стороны света ярче.
        for deg in stride(from: 0, to: 360, by: 30) {
            let h = Double(deg) * .pi / 180
            let line = polyline(count: 48, basis: basis, project: project, closed: false) { i in
                direction(latitude: -.pi / 2 + Double(i) / 48 * .pi, heading: h)
            }
            let cardinal = deg % 90 == 0
            context.stroke(line, with: .color(.white.opacity(cardinal ? 0.55 : 0.3)), lineWidth: cardinal ? 1.2 : 0.7)
        }
        // Горизонт.
        let horizon = polyline(count: 128, basis: basis, project: project) { i in
            direction(latitude: 0, heading: Double(i) / 128 * 2 * .pi)
        }
        context.stroke(horizon, with: .color(.white), lineWidth: 2)

        // Подписи курса на горизонте и тангажа на меридиане текущего курса.
        let labelFont = Font.system(size: 9, weight: .heavy).monospacedDigit()
        for deg in stride(from: 0, to: 360, by: 30) {
            let l = basis.local(direction(latitude: 4 * .pi / 180, heading: Double(deg) * .pi / 180))
            guard l.y > 0.3 else { continue }
            let text = Text(headingLabel(deg)).font(labelFont).foregroundStyle(.white)
            context.draw(text, at: project(l))
        }
        let noseHeading = atan2(basis.nose.x, basis.nose.y)
        for deg in [-60, -30, 30, 60] {
            let l = basis.local(direction(latitude: Double(deg) * .pi / 180, heading: noseHeading + 8 * .pi / 180))
            guard l.y > 0.3 else { continue }
            let text = Text("\(deg)").font(labelFont).foregroundStyle(.white.opacity(0.9))
            context.draw(text, at: project(l))
        }
    }

    static func headingLabel(_ deg: Int) -> String {
        switch deg {
        case 0: "С"
        case 90: "В"
        case 180: "Ю"
        case 270: "З"
        default: "\(deg / 10)"
        }
    }

    /// Ломаная по точкам сферы, только видимая часть (нос·w > 0); на краю диска обрезается.
    static func polyline(count: Int, basis: Basis, project: (V) -> CGPoint, closed: Bool = true,
                         point: (Int) -> V) -> Path {
        var path = Path()
        var prev = basis.local(point(0))
        if prev.y > 0 { path.move(to: project(prev)) }
        for i in 1...count {
            let cur = basis.local(point(closed ? i % count : i))
            switch (prev.y > 0, cur.y > 0) {
            case (true, true):
                path.addLine(to: project(cur))
            case (true, false):
                path.addLine(to: project(rimPoint(prev, cur)))
            case (false, true):
                path.move(to: project(rimPoint(prev, cur)))
                path.addLine(to: project(cur))
            case (false, false):
                break
            }
            prev = cur
        }
        return path
    }

    /// Точка пересечения отрезка с краем видимой полусферы (y = 0), на единичной сфере.
    static func rimPoint(_ a: V, _ b: V) -> V {
        let t = a.y / (a.y - b.y)
        var p = a + (b - a) * t
        p.y = 0
        let len = simd_length(p)
        return len > 1e-9 ? p / len : p
    }

    /// Область земли (u < 0) на видимом диске: видимая дуга горизонта и край диска со стороны земли.
    /// nil — горизонт не виден (нос строго вверх или вниз).
    static func groundPath(basis: Basis, project: (V) -> CGPoint, center: CGPoint, radius: CGFloat) -> Path? {
        let n = 128
        // Порог отсекает шум округления, когда горизонт совпадает с краем диска.
        let eps = 1e-6
        let pts = (0..<n).map { i in basis.local(direction(latitude: 0, heading: Double(i) / Double(n) * 2 * .pi)) }
        guard let start = (0..<n).first(where: { pts[($0 + n - 1) % n].y <= eps && pts[$0].y > eps }) else { return nil }

        var arc: [CGPoint] = [project(rimPoint(pts[(start + n - 1) % n], pts[start]))]
        var i = start
        var steps = 0
        while pts[i % n].y > eps && steps < n {
            arc.append(project(pts[i % n]))
            i += 1
            steps += 1
        }
        arc.append(project(rimPoint(pts[(i - 1) % n], pts[i % n])))

        // Углы концов дуги на краю диска (экранные: x вправо, y вниз).
        func angle(_ p: CGPoint) -> Double { atan2(Double(p.y - center.y), Double(p.x - center.x)) }
        let a = angle(arc[0])
        let b = angle(arc[arc.count - 1])
        // Мировое направление точки края под экранным углом θ: правый борт·cosθ − спина·sinθ.
        func rimUp(_ theta: Double) -> Double { basis.right.z * cos(theta) - basis.top.z * sin(theta) }
        var forward = a - b
        while forward < 0 { forward += 2 * .pi }
        while forward >= 2 * .pi { forward -= 2 * .pi }
        // От b к a против часовой (рост угла) или по часовой — туда, где земля.
        let increasing = rimUp(b + forward / 2) < 0
        let sweep = increasing ? forward : -(2 * .pi - forward)

        var path = Path()
        path.move(to: arc[0])
        for p in arc.dropFirst() { path.addLine(to: p) }
        let segments = 48
        for k in 1...segments {
            let theta = b + sweep * Double(k) / Double(segments)
            path.addLine(to: CGPoint(x: center.x + radius * CGFloat(cos(theta)),
                                     y: center.y + radius * CGFloat(sin(theta))))
        }
        path.closeSubpath()
        return path
    }
}
