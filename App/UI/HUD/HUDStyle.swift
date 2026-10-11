import SwiftUI

/// Общие размеры и цвета HUD: плотные полупрозрачные подложки и белый текст — читаемо на любом фоне.
enum HUDStyle {
    static let minTouch: CGFloat = 44
    static let corner: CGFloat = 12
    static let panel = Color.black.opacity(0.6)
    static let control = Color.black.opacity(0.55)
    static let stroke = Color.white.opacity(0.18)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.18)
    static let active = Color(red: 0.25, green: 0.78, blue: 0.95)
    static let secondaryText = Color.white.opacity(0.65)
}

extension View {
    /// Плотная подложка элемента HUD.
    func hudBackground(_ fill: Color = HUDStyle.panel, corner: CGFloat = HUDStyle.corner) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(HUDStyle.stroke, lineWidth: 1))
    }
}

/// Кнопка HUD: подсвечивается при нажатии и в активном состоянии, касание ≥ 44 pt.
struct HUDButtonStyle: ButtonStyle {
    var isActive = false
    var fill: Color = HUDStyle.control

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? Color.black : Color.white)
            .frame(minWidth: HUDStyle.minTouch, minHeight: HUDStyle.minTouch)
            .contentShape(Rectangle())
            .hudBackground(isActive ? HUDStyle.active : fill, corner: 10)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
