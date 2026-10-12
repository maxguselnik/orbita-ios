import OrbitPhysics
import SwiftUI

/// Правая колонка: сетка SAS 3×3, джойстик с кнопками крена, «Ступень».
struct ControlsColumn: View {
    let model: FlightHUDModel

    static let width: CGFloat = 196

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            SASGrid(model: model)
            AttitudeControls(model: model)
            StageButton(model: model)
        }
        .frame(width: Self.width)
    }
}

// MARK: - SAS

/// Сетка SAS: держать, прогрейд, ретрогрейд / нормаль, антинормаль, наружу / внутрь, узел, вкл-выкл.
struct SASGrid: View {
    let model: FlightHUDModel

    private static let cell: CGFloat = 46

    var body: some View {
        let current = model.sas
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                modeButton(.hold, current)
                modeButton(.prograde, current)
                modeButton(.retrograde, current)
            }
            GridRow {
                modeButton(.normal, current)
                modeButton(.antiNormal, current)
                modeButton(.radialOut, current)
            }
            GridRow {
                modeButton(.radialIn, current)
                modeButton(.maneuver, current)
                    .disabled(!model.hasManeuver && current != .maneuver)
                    .opacity(model.hasManeuver || current == .maneuver ? 1 : 0.45)
                SASToggleButton(model: model)
            }
        }
        .frame(width: Self.cell * 3 + 8)
    }

    private func modeButton(_ mode: SASMode, _ current: SASMode) -> some View {
        Button {
            model.send(.setSAS(current == mode ? .hold : mode))
        } label: {
            VStack(spacing: 1) {
                SASIcon(mode: mode)
                    .frame(width: 20, height: 20)
                Text(Self.shortName(mode))
                    .font(.system(size: 8, weight: .bold))
                    .lineLimit(1)
            }
            .frame(width: Self.cell, height: HUDStyle.minTouch)
        }
        .buttonStyle(HUDButtonStyle(isActive: current == mode))
        .accessibilityLabel(Self.fullName(mode))
    }

    static func shortName(_ mode: SASMode) -> String {
        switch mode {
        case .off: "выкл"
        case .hold: "ДЕРЖ"
        case .prograde: "ПРОГР"
        case .retrograde: "РЕТРО"
        case .normal: "НОРМ"
        case .antiNormal: "АНТИ"
        case .radialOut: "НАРУЖ"
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

/// SAS вкл/выкл (включение — «держать ориентацию»).
struct SASToggleButton: View {
    let model: FlightHUDModel

    var body: some View {
        let current = model.sas
        Button {
            model.toggleSAS()
        } label: {
            VStack(spacing: 1) {
                Text("SAS").font(.system(size: 15, weight: .heavy))
                Text(current == .off ? "выкл" : "вкл").font(.system(size: 9, weight: .bold))
            }
            .frame(maxWidth: .infinity, minHeight: HUDStyle.minTouch)
        }
        .buttonStyle(HUDButtonStyle(isActive: current != .off))
        .accessibilityLabel(current == .off ? "Включить SAS" : "Выключить SAS")
    }
}

// MARK: - Джойстик и крен

/// Виртуальный джойстик тангаж/рыскание и кнопки крена по бокам (удержание).
struct AttitudeControls: View {
    let model: FlightHUDModel

    var body: some View {
        HStack(spacing: 6) {
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

    let size: CGFloat = 92
    private var travel: CGFloat { size / 2 - 20 }
    @GestureState private var offset: CGSize = .zero

    var body: some View {
        ZStack {
            Circle().fill(HUDStyle.control)
            Circle().strokeBorder(HUDStyle.stroke, lineWidth: 1)
            Path { p in
                p.move(to: CGPoint(x: size / 2, y: 12)); p.addLine(to: CGPoint(x: size / 2, y: size - 12))
                p.move(to: CGPoint(x: 12, y: size / 2)); p.addLine(to: CGPoint(x: size - 12, y: size / 2))
            }
            .stroke(.white.opacity(0.2), lineWidth: 1)
            Circle()
                .fill(.white.opacity(offset == .zero ? 0.75 : 0.95))
                .frame(width: 38, height: 38)
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
            .frame(width: HUDStyle.minTouch, height: 60)
            .contentShape(Rectangle())
            .hudBackground(pressed ? HUDStyle.active : HUDStyle.control, corner: 10)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
            .onChange(of: pressed) { _, value in onPress(value) }
            .accessibilityLabel(label)
    }
}

// MARK: - Ступень

/// Большая кнопка «Ступень»: одно нажатие — `.stage`. На последней ступени выпускает парашют.
struct StageButton: View {
    let model: FlightHUDModel
    /// Низкая кнопка (карта: место под панель узла).
    var compact = false

    var body: some View {
        let t = model.stageStatus
        let isLast = t.remaining <= 1
        let title = isLast ? (t.chute == .stowed ? "ПАРАШЮТ" : "ПАРАШЮТ ВЫПУЩЕН") : "СТУПЕНЬ"
        Button {
            model.send(.stage)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isLast ? "arrow.down.to.line.compact" : "square.stack.3d.down.right.fill")
                    .font(.system(size: 18, weight: .bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 17, weight: .heavy))
                    if !isLast && !compact {
                        Text("осталось \(t.remaining - 1)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .opacity(0.75)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? HUDStyle.minTouch : 54)
        }
        .buttonStyle(HUDButtonStyle(fill: HUDStyle.accent.opacity(0.85)))
        .disabled(isLast && t.chute != .stowed)
        .accessibilityLabel(isLast ? "Выпустить парашют" : "Следующая ступень")
    }
}
