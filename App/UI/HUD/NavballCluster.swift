import OrbitPhysics
import SwiftUI

/// Сторона дугового прибора вокруг навбола.
enum GaugeSide {
    case left, right
}

/// Геометрия дуг-приборов: значение 0…1 откладывается снизу вверх по полуокружности.
/// Углы — в экранных координатах (y вниз): 90° — низ, 180° — лево, 0° — право, 270° — верх.
enum GaugeMath {
    static func degrees(side: GaugeSide, fraction: Double) -> Double {
        let f = min(max(fraction, 0), 1)
        switch side {
        case .left: return 90 + 180 * f
        case .right: return 90 - 180 * f
        }
    }

    static func point(center: CGPoint, radius: CGFloat, side: GaugeSide, fraction: Double) -> CGPoint {
        let radians = degrees(side: side, fraction: fraction) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(radians)),
                       y: center.y + radius * CGFloat(sin(radians)))
    }

    /// Значение левой дуги по точке касания: угол вокруг центра дуги. Касание правее центра прижимается к краю.
    static func fraction(forTouch point: CGPoint, center: CGPoint) -> Double {
        var degrees = atan2(Double(point.y - center.y), Double(point.x - center.x)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return min(max((degrees - 90) / 180, 0), 1)
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
        let steps = max(2, Int(((to - from) * 48).rounded(.up)))
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

/// Корпус навбола: полукруглая панель шириной 270 pt, низ уходит за край экрана. Внутри: навбол,
/// табло скорости, курс, дуга тяги слева (тянется пальцем), дуга перегрузки справа, переключатель SAS.
struct NavballConsole: View {
    let model: FlightHUDModel
    /// Помощник подъёма включён: на сфере рисуется маркер цели.
    var ascentEnabled = true

    static let width: CGFloat = 270
    static let height: CGFloat = 170
    /// Насколько нижняя часть корпуса уходит за край экрана.
    static let overhang: CGFloat = 12
    static let ballDiameter: CGFloat = 112
    static let ballCenter = CGPoint(x: 135, y: 86)
    static let arcRadius: CGFloat = 46
    static let leftArcCenter = CGPoint(x: 62, y: 86)
    static let rightArcCenter = CGPoint(x: 208, y: 86)

    var body: some View {
        let t = model.telemetry
        let frame = model.speedFrame(for: t)
        ZStack(alignment: .topLeading) {
            ConsoleBackdrop()
            ThrottleGauge(model: model)
            GForceGauge(gForce: t.gForce)
            NavballSphere(telemetry: t, frame: frame,
                          targetPitch: ascentEnabled ? AscentGuide.advice(t)?.targetPitch : nil)
                .frame(width: Self.ballDiameter, height: Self.ballDiameter)
                .position(Self.ballCenter)
            Text(HUDFormat.heading(t.heading))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(HUDPalette.text)
                .position(x: Self.ballCenter.x, y: 150)
                .allowsHitTesting(false)
            SpeedLCD(telemetry: t, frame: frame) { model.toggleSpeedFrame() }
                .position(x: Self.width / 2, y: 17)
            ConsoleSASSwitch(model: model)
                .position(x: 52, y: 17)
        }
        .frame(width: Self.width, height: Self.height)
    }
}

/// Подложка корпуса: градиент, рамка и блик по верхнему краю.
struct ConsoleBackdrop: View {
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 135, bottomLeadingRadius: 0,
                               bottomTrailingRadius: 0, topTrailingRadius: 135, style: .continuous)
    }

    var body: some View {
        shape
            .fill(LinearGradient(colors: [HUDPalette.consoleTop, HUDPalette.consoleBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(HUDPalette.strokeBright, lineWidth: 1))
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.2), Color.clear],
                                                  startPoint: .top, endPoint: .center), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.45), radius: 9, y: -4)
    }
}

/// Табло скорости в стиле зелёного ЖК: «Орбита 7 543 м/с» / «Поверхность 543 м/с». Тап — переключение.
struct SpeedLCD: View {
    let telemetry: FlightTelemetry
    let frame: SpeedFrame
    let onTap: () -> Void

    var body: some View {
        let speed = frame == .orbit ? telemetry.speed : telemetry.surfaceSpeed
        let name = frame == .orbit ? "Орбита" : "Поверхность"
        Button(action: onTap) {
            Text(name + " " + HUDFormat.speed(speed))
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(HUDPalette.lcd)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .frame(width: 132, height: 22)
                .background(Color(red: 0.04, green: 0.1, blue: 0.063), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(HUDPalette.strokeBright, lineWidth: 1))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(HUDPalette.green.opacity(0.25), lineWidth: 3)
                        .blur(radius: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                )
                .padding(.vertical, 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(frame == .orbit ? "Орбитальная скорость \(HUDFormat.speed(speed))"
                                            : "Скорость относительно поверхности \(HUDFormat.speed(speed))")
        .accessibilityHint("Переключить орбита или поверхность")
    }
}

/// Переключатель SAS в левом верхнем углу корпуса: зелёный, когда включён. RCS в игре пока нет — не рисуется.
struct ConsoleSASSwitch: View {
    let model: FlightHUDModel

    var body: some View {
        let on = model.sas != .off
        Button {
            model.toggleSAS()
        } label: {
            Text("SAS")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(on ? Color.white : HUDPalette.muted)
                .frame(width: 34, height: 20)
                .background(on ? HUDPalette.greenDark : Color.white.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(on ? "Выключить SAS" : "Включить SAS")
    }
}

/// Дуга тяги слева от навбола: оранжевое заполнение и кружок-ручка. Тяга задаётся перетаскиванием по дуге
/// (вверх — больше). РДТТ горит на 100 % и не регулируется.
struct ThrottleGauge: View {
    let model: FlightHUDModel

    private static let touchSize = CGSize(width: 62, height: 112)

    var body: some View {
        let locked = model.solidLocked
        let value: Double = locked ? 1 : min(max(model.throttle, 0), 1)
        let center = NavballConsole.leftArcCenter
        let radius = NavballConsole.arcRadius
        let frameSide = 2 * (radius + 10)
        let knob = GaugeMath.point(center: center, radius: radius, side: .left, fraction: value)
        // Левый верхний угол зоны касания в координатах корпуса и центр дуги внутри неё.
        let origin = CGPoint(x: center.x - 56, y: center.y - 56)
        let touchCenter = CGPoint(x: center.x - origin.x, y: center.y - origin.y)
        ZStack {
            GaugeTicksShape(side: .left, count: 15, inner: radius + 4, outer: radius + 8)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: frameSide, height: frameSide)
                .position(center)
            GaugeArcShape(side: .left, to: 1, radius: radius)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: frameSide, height: frameSide)
                .position(center)
            GaugeArcShape(side: .left, to: value, radius: radius)
                .stroke(HUDPalette.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: frameSide, height: frameSide)
                .position(center)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(HUDPalette.accent, lineWidth: 2))
                .frame(width: 14, height: 14)
                .position(knob)
            Text((locked ? "РДТТ " : "ТЯГА ") + HUDFormat.percent(value))
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(HUDPalette.muted)
                .lineLimit(1)
                .position(x: 42, y: 142)
            Color.clear
                .frame(width: Self.touchSize.width, height: Self.touchSize.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard !locked else { return }
                            model.throttle = GaugeMath.fraction(forTouch: drag.location, center: touchCenter)
                        }
                )
                .position(x: origin.x + Self.touchSize.width / 2, y: origin.y + Self.touchSize.height / 2)
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

/// Дуга перегрузки справа от навбола: заполнение до 6 g, цвет растёт от зелёного к красному.
struct GForceGauge: View {
    let gForce: Double

    static let fullScale = 6.0

    static func fraction(_ g: Double) -> Double {
        g.isFinite ? min(max(g / fullScale, 0), 1) : 0
    }

    var body: some View {
        let center = NavballConsole.rightArcCenter
        let radius = NavballConsole.arcRadius
        let frameSide = 2 * (radius + 10)
        let value = Self.fraction(gForce)
        let color: Color = gForce >= 5 ? .red : (gForce >= 3 ? HUDPalette.advice : HUDPalette.green)
        ZStack {
            GaugeTicksShape(side: .right, count: 15, inner: radius + 4, outer: radius + 8)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .frame(width: frameSide, height: frameSide)
                .position(center)
            GaugeArcShape(side: .right, to: 1, radius: radius)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: frameSide, height: frameSide)
                .position(center)
            GaugeArcShape(side: .right, to: value, radius: radius)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: frameSide, height: frameSide)
                .position(center)
            Text("G " + HUDFormat.fixed(gForce.isFinite ? gForce : 0, digits: 1))
                .font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(HUDPalette.muted)
                .lineLimit(1)
                .position(x: 228, y: 142)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Перегрузка \(HUDFormat.fixed(gForce.isFinite ? gForce : 0, digits: 1)) g")
    }
}
