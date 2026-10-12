import OrbitPhysics
import SwiftUI

/// Сторона дугового прибора на кольце навбола.
enum GaugeSide {
    case left, right
}

/// Геометрия дуг-приборов на кольце. Углы — в экранных координатах (y вниз): 0° — право, 90° — низ,
/// 180° — лево, 270° — верх. Левая дуга идёт от 145° (низ-лево, у края экрана) до 215° (верх-лево),
/// правая — зеркально: от 35° до −35°. Значение 0…1 откладывается снизу вверх.
enum GaugeMath {
    static let startDegrees = 145.0
    static let spanDegrees = 70.0

    static func degrees(side: GaugeSide, fraction: Double) -> Double {
        let f = min(max(fraction, 0), 1)
        let left = startDegrees + spanDegrees * f
        switch side {
        case .left: return left
        case .right: return 180 - left
        }
    }

    static func point(center: CGPoint, radius: CGFloat, side: GaugeSide, fraction: Double) -> CGPoint {
        let radians = degrees(side: side, fraction: fraction) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(radians)),
                       y: center.y + radius * CGFloat(sin(radians)))
    }

    /// Значение левой дуги по точке касания: угол вокруг центра кольца, вне дуги прижимается к краю.
    static func fraction(forTouch point: CGPoint, center: CGPoint) -> Double {
        var degrees = atan2(Double(point.y - center.y), Double(point.x - center.x)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return min(max((degrees - startDegrees) / spanDegrees, 0), 1)
    }
}

/// Дуга от `from` до `to` (доли 0…1) радиусом `radius` вокруг центра рамки.
struct GaugeArcShape: Shape {
    var side: GaugeSide
    var from: Double = 0
    var to: Double
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard to > from else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let steps = max(2, Int(((to - from) * 32).rounded(.up)))
        for step in 0...steps {
            let f: Double = from + (to - from) * Double(step) / Double(steps)
            let p = GaugeMath.point(center: center, radius: radius, side: side, fraction: f)
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// Деления вдоль дуги: короткие радиальные штрихи.
struct GaugeTicksShape: Shape {
    var side: GaugeSide
    var count: Int
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for k in 0...count {
            let f: Double = Double(k) / Double(count)
            path.move(to: GaugeMath.point(center: center, radius: inner, side: side, fraction: f))
            path.addLine(to: GaugeMath.point(center: center, radius: outer, side: side, fraction: f))
        }
        return path
    }
}

/// Кольцо навбола (макет Б4): круг 184 pt, нижние 34 pt уходят за край экрана. Внутри — навбол, сверху — табло
/// скорости, в верхних углах — RCS (слева) и SAS со стрелкой выбора режима (справа); на кольце слева дуга тяги
/// (тянется пальцем), справа дуга перегрузки.
struct NavballCluster: View {
    let model: FlightHUDModel
    /// Помощник подъёма включён: на сфере рисуется маркер цели.
    var ascentEnabled = true

    static let size: CGFloat = 184
    /// Насколько нижняя часть кольца уходит за край экрана.
    static let overhang: CGFloat = 34
    static let ballDiameter: CGFloat = 116
    static let center = CGPoint(x: 92, y: 92)
    static let arcRadius: CGFloat = 82

    var body: some View {
        let t = model.telemetry
        let frame = model.speedFrame(for: t)
        ZStack(alignment: .topLeading) {
            ClusterRing()
            ThrottleGauge(model: model)
            GForceGauge(gForce: t.gForce)
            NavballSphere(telemetry: t, frame: frame,
                          targetPitch: ascentEnabled ? AscentGuide.advice(t)?.targetPitch : nil)
                .frame(width: Self.ballDiameter, height: Self.ballDiameter)
                .position(Self.center)
            SpeedLCD(telemetry: t, frame: frame) { model.toggleSpeedFrame() }
                .position(x: Self.size / 2, y: 20)
            ClusterRCSButton(model: model)
                .position(x: 26, y: 22)
            ClusterSASButton(model: model)
                .position(x: Self.size - 31, y: 22)
        }
        .frame(width: Self.size, height: Self.size)
    }
}

/// Подложка кольца: градиент, рамка и тень вверх.
struct ClusterRing: View {
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [HUDPalette.consoleTop, HUDPalette.consoleBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(HUDPalette.strokeBright, lineWidth: 1))
            .overlay(Circle().inset(by: 5).strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 8, y: -2)
    }
}

/// Табло скорости в стиле зелёного ЖК: «пов 678 м/с» / «орб 7 543 м/с». Тап — переключение системы отсчёта.
struct SpeedLCD: View {
    let telemetry: FlightTelemetry
    let frame: SpeedFrame
    let onTap: () -> Void

    var body: some View {
        let speed = frame == .orbit ? telemetry.speed : telemetry.surfaceSpeed
        let name = frame == .orbit ? "орб" : "пов"
        Button(action: onTap) {
            Text(name + " " + HUDFormat.speed(speed))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(HUDPalette.lcd)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 5)
                .frame(width: 76, height: 18)
                .background(Color(red: 0.04, green: 0.1, blue: 0.063), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(HUDPalette.strokeBright, lineWidth: 1))
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(frame == .orbit ? "Орбитальная скорость \(HUDFormat.speed(speed))"
                                            : "Скорость относительно поверхности \(HUDFormat.speed(speed))")
        .accessibilityHint("Переключить орбита или поверхность")
    }
}

/// RCS в левом верхнем углу кольца: зелёная, когда включено; серая и с тостом «Нет блоков РСУ», если блоков нет.
/// Под надписью — мини-шкала монотоплива (красная ниже 15 %).
struct ClusterRCSButton: View {
    let model: FlightHUDModel

    var body: some View {
        let rcs = model.rcs
        let on = rcs.enabled
        Button {
            model.toggleRCS()
        } label: {
            Text("RCS")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(on ? Color.white : HUDPalette.muted)
                .offset(y: rcs.available ? -2 : 0)
                .frame(width: 44, height: 22)
                .background(on ? HUDPalette.greenDark : HUDPalette.stroke,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(rcs.firing ? HUDPalette.lcd : Color.clear, lineWidth: 1))
                .overlay(alignment: .bottom) {
                    if rcs.available {
                        MonoStrip(fraction: rcs.monoFraction)
                            .padding(.bottom, 3)
                    }
                }
                .opacity(rcs.available || on ? 1 : 0.55)
                .frame(width: 48, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(on ? "Выключить РСУ" : "Включить РСУ")
        .accessibilityValue(rcs.available ? "монотоплива \(HUDFormat.percent(rcs.monoFraction))" : "нет блоков")
    }
}

/// Шкала монотоплива 28 × 3 pt.
struct MonoStrip: View {
    let fraction: Double

    var body: some View {
        let level = CGFloat(min(max(fraction.isFinite ? fraction : 0, 0), 1))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.18))
            Capsule()
                .fill(fraction < 0.15 ? Color.red : HUDPalette.green)
                .frame(width: 28 * level)
        }
        .frame(width: 28, height: 3)
    }
}

/// SAS в правом верхнем углу кольца: тап по «SAS» — вкл/выкл (зелёная, когда включён; при режиме не «держать»
/// вместо надписи — его краткое имя), стрелка ▾ открывает сетку режимов.
struct ClusterSASButton: View {
    let model: FlightHUDModel

    @State private var picking = false

    var body: some View {
        let current = model.sas
        let on = current != .off
        let title = on && current != .hold ? SASGrid.shortName(current) : "SAS"
        HStack(spacing: 0) {
            Button {
                model.toggleSAS()
            } label: {
                Text(title)
                    .font(.system(size: 9, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(on ? Color.white : HUDPalette.muted)
                    .frame(width: 38, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityLabel(on ? "Выключить SAS, сейчас: " + SASGrid.fullName(current) : "Включить SAS")

            Button {
                picking = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(on ? Color.white : HUDPalette.muted)
                    .frame(width: 24, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityLabel("Режим SAS: " + (on ? SASGrid.fullName(current) : "выключен"))
            .accessibilityHint("Выбрать режим")
            .popover(isPresented: $picking, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("РЕЖИМ SAS")
                        .font(.system(size: 8, weight: .regular))
                        .tracking(1)
                        .foregroundStyle(HUDPalette.muted)
                    SASGrid(model: model) { picking = false }
                }
                .padding(10)
                .presentationCompactAdaptation(.popover)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(on ? HUDPalette.greenDark : HUDPalette.stroke)
                .frame(height: 22)
        }
        .overlay {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: 1, height: 22)
                .offset(x: 7)
                .allowsHitTesting(false)
        }
    }
}

/// Дуга тяги слева на кольце: оранжевое заполнение и кружок-ручка. Тяга задаётся перетаскиванием по дуге
/// (вверх — больше). РДТТ горит на 100 % и не регулируется.
struct ThrottleGauge: View {
    let model: FlightHUDModel

    /// Зона касания в координатах кольца: левая сторона от низа до верхнего угла.
    private static let touchRect = CGRect(x: -4, y: 28, width: 56, height: 124)

    var body: some View {
        let locked = model.solidLocked
        let value: Double = locked ? 1 : min(max(model.throttle, 0), 1)
        let center = NavballCluster.center
        let radius = NavballCluster.arcRadius
        let size = NavballCluster.size
        let knob = GaugeMath.point(center: center, radius: radius, side: .left, fraction: value)
        let touch = Self.touchRect
        let touchCenter = CGPoint(x: center.x - touch.minX, y: center.y - touch.minY)
        ZStack {
            GaugeTicksShape(side: .left, count: 7, inner: radius + 4, outer: radius + 8)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: size, height: size)
                .position(center)
            GaugeArcShape(side: .left, to: 1, radius: radius)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: size, height: size)
                .position(center)
            GaugeArcShape(side: .left, to: value, radius: radius)
                .stroke(HUDPalette.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: size, height: size)
                .position(center)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(HUDPalette.accent, lineWidth: 2))
                .frame(width: 14, height: 14)
                .position(knob)
            VStack(spacing: 0) {
                Text(locked ? "РДТТ" : "ТЯГА")
                    .foregroundStyle(HUDPalette.text)
                Text(HUDFormat.percent(value))
                    .foregroundStyle(HUDPalette.accent)
            }
            .font(.system(size: 9, weight: .heavy).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
            .position(x: -12, y: 124)
            .allowsHitTesting(false)
            Color.clear
                .frame(width: touch.width, height: touch.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard !locked else { return }
                            model.throttle = GaugeMath.fraction(forTouch: drag.location, center: touchCenter)
                        }
                )
                .position(x: touch.midX, y: touch.midY)
                .accessibilityElement()
                .accessibilityLabel("Тяга")
                .accessibilityValue(locked ? "РДТТ работает на полной тяге, регулировка невозможна" : HUDFormat.percent(value))
                .accessibilityAdjustableAction { direction in
                    guard !locked else { return }
                    if direction == .increment {
                        model.throttle = min(1, model.throttle + 0.1)
                    } else if direction == .decrement {
                        model.throttle = max(0, model.throttle - 0.1)
                    }
                }
        }
    }
}

/// Дуга перегрузки справа на кольце: заполнение до 6 g, цвет растёт от зелёного к красному.
struct GForceGauge: View {
    let gForce: Double

    static let fullScale = 6.0

    static func fraction(_ g: Double) -> Double {
        g.isFinite ? min(max(g / fullScale, 0), 1) : 0
    }

    var body: some View {
        let center = NavballCluster.center
        let radius = NavballCluster.arcRadius
        let size = NavballCluster.size
        let value = Self.fraction(gForce)
        let color: Color = gForce >= 5 ? .red : (gForce >= 3 ? HUDPalette.advice : HUDPalette.green)
        ZStack {
            GaugeTicksShape(side: .right, count: 7, inner: radius + 4, outer: radius + 8)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: size, height: size)
                .position(center)
            GaugeArcShape(side: .right, to: 1, radius: radius)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: size, height: size)
                .position(center)
            GaugeArcShape(side: .right, to: value, radius: radius)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: size, height: size)
                .position(center)
            Text("G " + HUDFormat.fixed(gForce.isFinite ? gForce : 0, digits: 1))
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .position(x: size + 12, y: 124)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Перегрузка \(HUDFormat.fixed(gForce.isFinite ? gForce : 0, digits: 1)) g")
    }
}
