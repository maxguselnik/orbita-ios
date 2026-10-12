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

/// Кнопка удержания блока ориентации: зона и вид — `AttitudeControls.cell` (52 pt); жест сбрасывается и при отмене касания.
/// Каждая кнопка — своё представление со своим жестом, поэтому удержание нескольких кнопок идёт одновременно.
struct AttitudeHoldButton: View {
    let systemImage: String
    let label: String
    let onPress: (Bool) -> Void

    @GestureState private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(pressed ? Color.black : HUDPalette.text)
            .frame(width: AttitudeControls.cell, height: AttitudeControls.cell)
            .classicPanel(corner: 8, fill: pressed ? HUDStyle.active : HUDPalette.panel)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
            .onChange(of: pressed) { _, value in onPress(value) }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}

/// Блок кнопок ориентации: ⟲ ▲ ⟳ / ◀ · ▶ / ТОЧНО ▼ · (3×3, кнопки 52 pt, зазор 6 pt).
struct AttitudeControls: View {
    let model: FlightHUDModel

    /// Сторона кнопки (≥ `HUDStyle.minTouch`), зазор между кнопками и сторона всего блока 3×3.
    static let cell: CGFloat = 52
    static let gap: CGFloat = 6
    static let side: CGFloat = 3 * cell + 2 * gap

    var body: some View {
        VStack(spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                button("arrow.counterclockwise", "Крен влево", .rollLeft)
                button("chevron.up", "Нос вверх", .pitchUp)
                button("arrow.clockwise", "Крен вправо", .rollRight)
            }
            HStack(spacing: Self.gap) {
                button("chevron.left", "Рыскание влево", .yawLeft)
                Color.clear.frame(width: AttitudeControls.cell, height: AttitudeControls.cell)
                button("chevron.right", "Рыскание вправо", .yawRight)
            }
            HStack(spacing: Self.gap) {
                FineControlToggle(model: model)
                button("chevron.down", "Нос вниз", .pitchDown)
                Color.clear.frame(width: AttitudeControls.cell, height: AttitudeControls.cell)
            }
        }
    }

    private func button(_ icon: String, _ label: String, _ id: AttitudeButton) -> some View {
        AttitudeHoldButton(systemImage: icon, label: label) { pressed in
            model.setAttitude(id, pressed: pressed)
        }
    }
}

/// Переключатель «ТОЧНО»: ввод ориентации ×0.3; подсвечен, пока включён.
struct FineControlToggle: View {
    let model: FlightHUDModel

    var body: some View {
        let on = model.fineControl
        Button {
            model.fineControl.toggle()
        } label: {
            Text("ТОЧНО")
                .font(.system(size: 9, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(on ? Color.black : HUDPalette.text)
                .frame(width: AttitudeControls.cell, height: AttitudeControls.cell)
                .classicPanel(corner: 8, fill: on ? HUDStyle.active : HUDPalette.panel)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel("Точное управление")
        .accessibilityValue(on ? "включено" : "выключено")
    }
}
