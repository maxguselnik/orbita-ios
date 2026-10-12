import OrbitPhysics
import SwiftUI

/// Правый нижний угол: малые MAX и 0 и джойстик с кнопками крена. До отрыва джойстик приглушён:
/// на площадке главное — «Зажигание» и тяга.
struct ControlsCluster: View {
    let model: FlightHUDModel
    /// Действие, которое советует помощник (подсвечивает MAX или 0).
    var guide: HUDAction?

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                HUDMiniButton(title: "MAX", label: "Полная тяга", pulse: guide == .fullThrottle) {
                    model.throttle = 1
                }
                HUDMiniButton(title: "0", label: "Тяга ноль", pulse: guide == .zeroThrottle) {
                    model.throttle = 0
                }
            }
            AttitudeControls(model: model)
                .opacity(model.onPad ? 0.5 : 1)
        }
    }
}

// MARK: - SAS

/// Сетка режимов SAS 4×2: содержимое всплывающей панели `SASModePill`.
struct SASGrid: View {
    let model: FlightHUDModel
    /// Вызывается после выбора режима (закрыть панель).
    var onPick: () -> Void = {}

    private static let cell: CGFloat = 46

    var body: some View {
        let current = model.sas
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                modeButton(.hold, current)
                modeButton(.prograde, current)
                modeButton(.retrograde, current)
                modeButton(.maneuver, current)
                    .disabled(!model.hasManeuver && current != .maneuver)
                    .opacity(model.hasManeuver || current == .maneuver ? 1 : 0.45)
            }
            GridRow {
                modeButton(.normal, current)
                modeButton(.antiNormal, current)
                modeButton(.radialOut, current)
                modeButton(.radialIn, current)
            }
        }
        .frame(width: Self.cell * 4 + 12)
    }

    private func modeButton(_ mode: SASMode, _ current: SASMode) -> some View {
        Button {
            model.send(.setSAS(current == mode ? .hold : mode))
            onPick()
        } label: {
            VStack(spacing: 1) {
                SASIcon(mode: mode)
                    .frame(width: 18, height: 18)
                Text(Self.shortName(mode))
                    .font(.system(size: 8, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(current == mode ? Color.black : Self.tint(mode))
            .frame(width: Self.cell, height: HUDStyle.minTouch)
        }
        .buttonStyle(HUDButtonStyle(isActive: current == mode))
        .accessibilityLabel(Self.fullName(mode))
    }

    /// Цвет значка режима: про/ретро — жёлто-зелёный, нормали — фиолетовый, радиальные — голубой.
    static func tint(_ mode: SASMode) -> Color {
        switch mode {
        case .off, .hold: Color.white
        case .prograde, .retrograde: NavballPalette.prograde
        case .normal, .antiNormal: NavballPalette.normal
        case .radialOut, .radialIn: NavballPalette.radial
        case .maneuver: NavballPalette.maneuver
        }
    }

    static func shortName(_ mode: SASMode) -> String {
        switch mode {
        case .off: "выкл"
        case .hold: "ДЕРЖАТЬ"
        case .prograde: "ПРОГР"
        case .retrograde: "РЕТРО"
        case .normal: "НОРМ"
        case .antiNormal: "АНТИ"
        case .radialOut: "НАРУЖУ"
        case .radialIn: "ВНУТРЬ"
        case .maneuver: "УЗЕЛ"
        }
    }

    static func fullName(_ mode: SASMode) -> String {
        switch mode {
        case .off: "SAS выключен"
        case .hold: "Держать ориентацию"
        case .prograde: "По вектору скорости"
        case .retrograde: "Против вектора скорости"
        case .normal: "По нормали"
        case .antiNormal: "По антинормали"
        case .radialOut: "Радиально наружу"
        case .radialIn: "Радиально внутрь"
        case .maneuver: "По узлу манёвра"
        }
    }
}

/// Оригинальные значки режимов SAS из простых фигур.
struct SASIcon: View {
    let mode: SASMode

    var body: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 1.5
            let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            let shading = GraphicsContext.Shading.foreground
            func circle(_ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            }
            switch mode {
            case .off, .hold:
                // Перекрестье с замком-кольцом.
                context.stroke(circle(r * 0.75), with: shading, style: style)
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - r, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - r)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
                context.stroke(cross, with: shading, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            case .prograde:
                // Кольцо с тремя усиками — «по скорости».
                context.stroke(circle(r * 0.55), with: shading, style: style)
                var ticks = Path()
                ticks.move(to: CGPoint(x: c.x - r * 0.55, y: c.y)); ticks.addLine(to: CGPoint(x: c.x - r, y: c.y))
                ticks.move(to: CGPoint(x: c.x + r * 0.55, y: c.y)); ticks.addLine(to: CGPoint(x: c.x + r, y: c.y))
                ticks.move(to: CGPoint(x: c.x, y: c.y - r * 0.55)); ticks.addLine(to: CGPoint(x: c.x, y: c.y - r))
                context.stroke(ticks, with: shading, style: style)
                context.fill(circle(1.6), with: shading)
            case .retrograde:
                // Кольцо с косым крестом.
                context.stroke(circle(r * 0.7), with: shading, style: style)
                var x = Path()
                let d = r * 0.5
                x.move(to: CGPoint(x: c.x - d, y: c.y - d)); x.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
                x.move(to: CGPoint(x: c.x + d, y: c.y - d)); x.addLine(to: CGPoint(x: c.x - d, y: c.y + d))
                context.stroke(x, with: shading, style: style)
            case .normal, .antiNormal:
                // Треугольник: вершиной вверх — нормаль, вниз — антинормаль.
                let up = mode == .normal
                var tri = Path()
                tri.move(to: CGPoint(x: c.x, y: up ? c.y - r : c.y + r))
                tri.addLine(to: CGPoint(x: c.x - r * 0.9, y: up ? c.y + r * 0.7 : c.y - r * 0.7))
                tri.addLine(to: CGPoint(x: c.x + r * 0.9, y: up ? c.y + r * 0.7 : c.y - r * 0.7))
                tri.closeSubpath()
                context.stroke(tri, with: shading, style: style)
                context.fill(circle(1.6), with: shading)
            case .radialOut, .radialIn:
                // Кольцо и четыре луча: наружу — от кольца, внутрь — к центру.
                let out = mode == .radialOut
                context.stroke(circle(r * 0.45), with: shading, style: style)
                var rays = Path()
                for k in 0..<4 {
                    let a = Double(k) * .pi / 2 + .pi / 4
                    let inner = out ? r * 0.6 : r * 0.15
                    let outer = out ? r : r * 0.4
                    rays.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * inner, y: c.y + CGFloat(sin(a)) * inner))
                    rays.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * outer, y: c.y + CGFloat(sin(a)) * outer))
                }
                context.stroke(rays, with: shading, style: style)
            case .maneuver:
                // Кольцо и три уголка, смотрящие внутрь, — «по узлу».
                context.stroke(circle(r * 0.4), with: shading, style: style)
                var chevrons = Path()
                for k in 0..<3 {
                    let a = Double(k) * 2 * .pi / 3 - .pi / 2
                    let tip = CGPoint(x: c.x + CGFloat(cos(a)) * r * 0.62, y: c.y + CGFloat(sin(a)) * r * 0.62)
                    for side in [-0.45, 0.45] {
                        let b = a + side
                        chevrons.move(to: CGPoint(x: c.x + CGFloat(cos(b)) * r, y: c.y + CGFloat(sin(b)) * r))
                        chevrons.addLine(to: tip)
                    }
                }
                context.stroke(chevrons, with: shading, style: style)
            }
        }
    }
}

/// SAS одной компактной кнопкой «SAS: ДЕРЖАТЬ»: тап — вкл/выкл. Включённость — точка и цвет текста.
struct SASToggleButton: View {
    let model: FlightHUDModel
    /// Узкий вариант (карта): «SAS» и режим в две строки.
    var stacked = false

    var body: some View {
        let current = model.sas
        let on = current != .off
        Button {
            model.toggleSAS()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(on ? HUDStyle.active : Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)
                if stacked {
                    VStack(spacing: 0) {
                        Text("SAS").font(.system(size: 12, weight: .heavy))
                        Text(on ? SASGrid.shortName(current) : "ВЫКЛ").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(on ? HUDStyle.active : Color.white)
                    .lineLimit(1)
                } else {
                    Text("SAS: " + (on ? SASGrid.shortName(current) : "ВЫКЛ"))
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(on ? HUDStyle.active : Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity, minHeight: HUDStyle.minTouch)
        }
        .buttonStyle(HUDButtonStyle())
        .accessibilityLabel(on ? "Выключить SAS, сейчас: " + SASGrid.fullName(current) : "Включить SAS")
    }
}

/// Режим SAS в свёрнутом виде: маленькая «пилюля» «SAS ДЕРЖАТЬ ▴»; тап раскрывает панель «РЕЖИМ SAS»
/// (сетка 4 × 2), выбор или тап мимо закрывают её. На площадке приглушена.
struct SASModePill: View {
    let model: FlightHUDModel

    @State private var picking = false

    var body: some View {
        let current = model.sas
        let on = current != .off
        Button {
            picking = true
        } label: {
            HStack(spacing: 6) {
                Text("SAS").fontWeight(.semibold).foregroundStyle(HUDPalette.muted)
                Text(on ? SASGrid.shortName(current) : "ВЫКЛ").foregroundStyle(on ? HUDPalette.sas : HUDPalette.text)
                Image(systemName: picking ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(HUDPalette.text)
            }
            .font(.system(size: 10, weight: .heavy))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(HUDPalette.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? HUDPalette.sas : HUDPalette.stroke, lineWidth: 1))
            .frame(minHeight: HUDStyle.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .opacity(model.onPad ? 0.5 : 1)
        .accessibilityLabel("Режим SAS: " + (on ? SASGrid.fullName(current) : "выключен"))
        .accessibilityHint("Раскрыть выбор режима")
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
}

// MARK: - Джойстик и крен

/// Виртуальный джойстик тангаж/рыскание и кнопки крена по бокам (удержание).
struct AttitudeControls: View {
    let model: FlightHUDModel

    var body: some View {
        HStack(spacing: 4) {
            HoldButton(systemImage: "arrow.counterclockwise", label: "Крен влево") { pressed in
                model.rollLeftPressed = pressed
            }
            Joystick { axes in
                // Палец вверх — нос вверх (+тангаж), вправо — рыскание вправо.
                model.pitchInput = Double(-axes.dy)
                model.yawInput = Double(axes.dx)
            }
            HoldButton(systemImage: "arrow.clockwise", label: "Крен вправо") { pressed in
                model.rollRightPressed = pressed
            }
        }
    }
}

/// Джойстик: ведение пальцем от точки касания, возврат в центр при отпускании.
struct Joystick: View {
    /// Отклонение −1…1 по осям (dy вниз — положительное).
    let onMove: (CGVector) -> Void

    let size: CGFloat = 84
    private var travel: CGFloat { size / 2 - 19 }
    @GestureState private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Circle().fill(HUDPalette.panel.opacity(0.7))
            Circle().strokeBorder(HUDPalette.stroke, lineWidth: 1)
            Path { p in
                p.move(to: CGPoint(x: size / 2, y: 12)); p.addLine(to: CGPoint(x: size / 2, y: size - 12))
                p.move(to: CGPoint(x: 12, y: size / 2)); p.addLine(to: CGPoint(x: size - 12, y: size / 2))
            }
            .stroke(.white.opacity(0.2), lineWidth: 1)
            Circle()
                .fill(.white.opacity(offset == .zero ? 0.75 : 0.95))
                .frame(width: 36, height: 36)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .offset(offset)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($offset) { drag, state, _ in
                    let t = drag.translation
                    let length = (t.width * t.width + t.height * t.height).squareRoot()
                    let scale = length > travel ? travel / length : 1
                    state = CGSize(width: t.width * scale, height: t.height * scale)
                }
        )
        .onChange(of: offset) { _, value in
            onMove(CGVector(dx: value.width / travel, dy: value.height / travel))
        }
        .accessibilityLabel("Джойстик тангажа и рыскания")
    }
}

/// Кнопка удержания: активна, пока палец на ней (жест сбрасывается и при отмене касания).
struct HoldButton: View {
    let systemImage: String
    let label: String
    let onPress: (Bool) -> Void

    @GestureState private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(pressed ? Color.black : Color.white)
            .frame(width: 40, height: 52)
            .contentShape(Rectangle())
            .classicPanel(corner: 10, fill: pressed ? HUDStyle.active : HUDPalette.panel)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
            .onChange(of: pressed) { _, value in onPress(value) }
            .accessibilityLabel(label)
    }
}

// MARK: - Ступень

/// Большая кнопка действия ступени: значок, «ЗАЖИГАНИЕ / ОТДЕЛИТЬ / ПАРАШЮТ / НЕТ ДЕЙСТВИЙ» и подпись.
/// Одно нажатие — `.stage`. Пульсирует, когда её советует помощник и на площадке до зажигания.
struct StageButton: View {
    let model: FlightHUDModel
    /// Низкая кнопка (карта: место под панель узла).
    var compact = false
    /// Помощник советует нажать её сейчас.
    var highlighted = false

    var body: some View {
        let t = model.stageStatus
        let enabled = t.action != .none
        let title: String = switch t.action {
        case .ignite: "ЗАЖИГАНИЕ"
        case .separate: "ОТДЕЛИТЬ"
        case .armChute: "ПАРАШЮТ"
        case .none: "НЕТ ДЕЙСТВИЙ"
        }
        let detail: String = switch t.action {
        case .ignite: t.hasSolid ? "РДТТ нельзя остановить" : "затем установите тягу"
        case .separate: "сбросить нижнюю ступень"
        case .armChute: "вооружить парашют"
        case .none: "ступени завершены"
        }
        let pulse = enabled && (highlighted || (model.onPad && t.action == .ignite))
        Button {
            model.send(.stage)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: t.action == .armChute ? "arrow.down.to.line.compact" : "square.stack.3d.down.right.fill")
                    .font(.system(size: 15, weight: .bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: compact ? 14 : 15, weight: .black))
                    if !compact {
                        Text(detail).font(.system(size: 9, weight: .semibold))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .foregroundStyle(enabled ? HUDPalette.accentText : HUDPalette.muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: compact ? HUDStyle.minTouch : 50)
            .background(enabled ? HUDPalette.accent : Color.white.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .hudPulse(pulse, corner: 12)
        .disabled(!enabled)
        .accessibilityLabel(title + ", " + detail)
    }
}
