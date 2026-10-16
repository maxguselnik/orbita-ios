import Foundation
import SwiftUI

/// Кнопки ориентации: тангаж (нос вверх/вниз), рыскание (влево/вправо) и крен (против/по часовой).
enum AttitudeButton: CaseIterable, Sendable {
    case pitchUp, pitchDown, yawLeft, yawRight, rollLeft, rollRight
}

/// Кривая ввода кнопок ориентации: с начального значения плавно до 1 за время разгона; режим «ТОЧНО» масштабирует.
enum AttitudeInputCurve {
    /// Начальное значение при касании: короткий тап даёт небольшую коррекцию.
    static let initial = 0.15
    /// Время нарастания от `initial` до 1, секунды.
    static let rampTime: TimeInterval = 0.8
    /// Множитель режима «ТОЧНО».
    static let fineScale = 0.3

    /// Величина оси 0…1 для кнопки, удерживаемой `heldFor` секунд.
    static func value(heldFor: TimeInterval, fine: Bool) -> Double {
        let k = min(max(heldFor / rampTime, 0), 1)
        let v = initial + (1 - initial) * k
        return fine ? v * fineScale : v
    }
}

/// Сектор круглой крестовины: вверх/вниз — тангаж, влево/вправо — рыскание.
enum DPadSector: CaseIterable, Sendable {
    case up, down, left, right

    /// Доля радиуса в центре, где ни один сектор не нажат.
    static let deadZone = 0.18

    /// Сектор по точке относительно центра круга (y вниз). В центре — `nil`; на диагонали побеждает вертикаль;
    /// за краем круга сектор сохраняется, чтобы палец, ушедший за обод, не «отпускал» кнопку.
    static func sector(for point: CGPoint, radius: CGFloat) -> DPadSector? {
        let distance = (point.x * point.x + point.y * point.y).squareRoot()
        if distance < radius * CGFloat(deadZone) { return nil }
        if abs(point.y) >= abs(point.x) { return point.y < 0 ? .up : .down }
        return point.x < 0 ? .left : .right
    }

    var button: AttitudeButton {
        switch self {
        case .up: .pitchUp
        case .down: .pitchDown
        case .left: .yawLeft
        case .right: .yawRight
        }
    }

    /// Направление сектора на экране (единичный вектор, y вниз).
    var direction: CGVector {
        switch self {
        case .up: CGVector(dx: 0, dy: -1)
        case .down: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        }
    }

    var systemImage: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        }
    }

    var label: String {
        switch self {
        case .up: "Нос вверх"
        case .down: "Нос вниз"
        case .left: "Рыскание влево"
        case .right: "Рыскание вправо"
        }
    }
}

/// Полупрозрачная круглая подложка элементов управления: чёрный ~40 %, тонкая светлая обводка ~35 %.
extension View {
    func glassCircle(highlight: Color? = nil) -> some View {
        background(Circle().fill(highlight?.opacity(0.55) ?? Color.black.opacity(0.4)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }
}

/// Круглая крестовина (D-pad) справа, кнопки крена над «плечами», «ТОЧНО» снизу-слева.
/// Палец можно вести из сектора в сектор без отрыва; второй палец в том же круге игнорируется.
/// Крен — отдельные круглые кнопки со своими жестами, поэтому удерживаются одновременно с крестовиной.
struct AttitudeControls: View {
    let model: FlightHUDModel

    static let radius: CGFloat = 70
    static let rollSize: CGFloat = 52
    static let circleCenter = CGPoint(x: 126, y: 108)
    /// Центры кнопок крена относительно центра круга: над «плечами» под углом ≈ 38° от вертикали, расстояние между
    /// центрами 104 pt ≥ radius + rollSize / 2 + 6 = 102 pt (зазор до круга ≥ 6 pt).
    static let rollOffset = CGSize(width: 64, height: -82)
    static let pillSize = CGSize(width: 56, height: 44)
    /// «ТОЧНО» — снизу-слева от круга, со стороны навбола.
    static let pillCenter = CGPoint(x: circleCenter.x - 98, y: circleCenter.y + 50)
    static let frameSize = CGSize(width: 216, height: 180)
    /// Отступы рамки от физических краёв экрана (боковая безопасная зона игнорируется; Dynamic Island — у бокового края
    /// в середине высоты). Центр круга — 120 pt от низа и 146 pt от правого края; правая кнопка крена — 46 pt от края.
    static let bottomInset: CGFloat = 48
    static let trailingInset: CGFloat = 46

    static var circleRect: CGRect {
        CGRect(x: circleCenter.x - radius, y: circleCenter.y - radius, width: radius * 2, height: radius * 2)
    }
    static var rollLeftRect: CGRect { rollRect(sign: -1) }
    static var rollRightRect: CGRect { rollRect(sign: 1) }
    static var pillRect: CGRect {
        CGRect(x: pillCenter.x - pillSize.width / 2, y: pillCenter.y - pillSize.height / 2,
               width: pillSize.width, height: pillSize.height)
    }
    private static func rollRect(sign: CGFloat) -> CGRect {
        CGRect(x: circleCenter.x + sign * rollOffset.width - rollSize / 2,
               y: circleCenter.y + rollOffset.height - rollSize / 2, width: rollSize, height: rollSize)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DPadCircle(model: model)
                .frame(width: Self.radius * 2, height: Self.radius * 2)
                .tutorialAnchor(.dpad)
                .position(Self.circleCenter)
            roll("arrow.counterclockwise", "Крен влево", .rollLeft)
                .position(x: Self.rollLeftRect.midX, y: Self.rollLeftRect.midY)
            roll("arrow.clockwise", "Крен вправо", .rollRight)
                .position(x: Self.rollRightRect.midX, y: Self.rollRightRect.midY)
            FineControlToggle(model: model)
                .tutorialAnchor(.fine)
                .position(x: Self.pillCenter.x, y: Self.pillCenter.y)
            // Рамка кнопки ▶ крестовины для обучения.
            Color.clear
                .frame(width: 52, height: 52)
                .tutorialAnchor(.dpadRight)
                .position(x: Self.circleCenter.x + Self.radius * 0.62, y: Self.circleCenter.y)
                .allowsHitTesting(false)
        }
        .frame(width: Self.frameSize.width, height: Self.frameSize.height, alignment: .topLeading)
    }

    private func roll(_ icon: String, _ label: String, _ id: AttitudeButton) -> some View {
        AttitudeHoldButton(systemImage: icon, label: label) { pressed in
            model.setAttitude(id, pressed: pressed)
        }
    }
}

/// Крестовина: один жест на весь круг; сектор определяется по углу от центра.
struct DPadCircle: View {
    let model: FlightHUDModel
    var radius: CGFloat = AttitudeControls.radius

    @GestureState private var active: DPadSector?

    var body: some View {
        let r = radius
        ZStack {
            Circle().fill(Color.black.opacity(0.4))
            if let sector = active {
                DPadWedge(sector: sector)
                    .fill(Color.white.opacity(0.3))
            }
            Path { p in
                let inner = r * CGFloat(DPadSector.deadZone) * 1.6
                let d = CGFloat(0.5).squareRoot()
                for (sx, sy) in [(1.0, 1.0), (-1.0, 1.0)] {
                    let ux = CGFloat(sx) * d, uy = CGFloat(sy) * d
                    p.move(to: CGPoint(x: r + ux * inner, y: r + uy * inner))
                    p.addLine(to: CGPoint(x: r + ux * (r - 2), y: r + uy * (r - 2)))
                    p.move(to: CGPoint(x: r - ux * inner, y: r - uy * inner))
                    p.addLine(to: CGPoint(x: r - ux * (r - 2), y: r - uy * (r - 2)))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 1)
            Circle().fill(Color.white.opacity(0.5)).frame(width: 6, height: 6)
            ForEach(DPadSector.allCases, id: \.self) { sector in
                Image(systemName: sector.systemImage)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white.opacity(active == sector ? 1 : 0.85))
                    .offset(x: sector.direction.dx * r * 0.62, y: sector.direction.dy * r * 0.62)
            }
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($active) { drag, state, _ in
                    state = DPadSector.sector(for: CGPoint(x: drag.location.x - r, y: drag.location.y - r), radius: r)
                }
        )
        .onChange(of: active) { old, new in
            if let old { model.setAttitude(old.button, pressed: false) }
            if let new { model.setAttitude(new.button, pressed: true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Крестовина: тангаж и рыскание")
        .accessibilityAddTraits(.isButton)
    }
}

/// Сектор круга 90° вокруг направления сектора.
struct DPadWedge: Shape {
    let sector: DPadSector

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let center = atan2(Double(sector.direction.dy), Double(sector.direction.dx))
        var path = Path()
        path.move(to: c)
        let steps = 16
        for k in 0...steps {
            let a = center - .pi / 4 + .pi / 2 * Double(k) / Double(steps)
            path.addLine(to: CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a))))
        }
        path.closeSubpath()
        return path
    }
}

/// Круглая кнопка крена 52 pt: активна, пока палец на ней (жест сбрасывается и при отмене касания).
struct AttitudeHoldButton: View {
    let systemImage: String
    let label: String
    var diameter: CGFloat = AttitudeControls.rollSize
    let onPress: (Bool) -> Void

    @GestureState private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: diameter, height: diameter)
            .glassCircle(highlight: pressed ? Color.white : nil)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
            .onChange(of: pressed) { _, value in onPress(value) }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

/// Переключатель «ТОЧНО»: ввод ориентации ×0.3; пилюля зелёная, пока режим включён. Зона касания 56×44 pt.
struct FineControlToggle: View {
    let model: FlightHUDModel

    var body: some View {
        let on = model.fineControl
        Button {
            model.fineControl.toggle()
        } label: {
            Text("ТОЧНО")
                .font(.system(size: HUDFont.caption, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 52, height: 28)
                .background(Capsule().fill(on ? HUDPalette.green : Color.black.opacity(0.4)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .frame(width: AttitudeControls.pillSize.width, height: AttitudeControls.pillSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .longPressHint("ТОЧНО — повороты в 3 раза мягче, для прицеливания")
        .accessibilityLabel("Точное управление")
        .accessibilityValue(on ? "включено" : "выключено")
    }
}
