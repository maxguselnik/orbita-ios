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

/// Шкала шрифтов интерфейса (макет docs/mockups/ui-polish.html): мельче 11 pt текста нет.
enum HUDFont {
    /// Подписи, единицы, счётчики.
    static let caption: CGFloat = 11
    /// Значения в узких местах: SAS, MAX/0, табло скорости, «ТЯГА».
    static let small: CGFloat = 12
    /// Основной текст, кнопки, тосты.
    static let body: CGFloat = 13
    /// Цифры приборов (высотомер, Δv).
    static let value: CGFloat = 15
    /// Заголовки панелей и диалогов.
    static let title: CGFloat = 17
    /// Крупные кнопки действия (ПУСК, Выполнить).
    static let big: CGFloat = 20
}

/// Палитра «классической» раскладки: тёмные панели, зелёный — активное, оранжевый — главное действие.
enum HUDPalette {
    static let panel = Color(red: 12 / 255, green: 16 / 255, blue: 24 / 255).opacity(0.85)
    static let stroke = Color(red: 0x2A / 255, green: 0x34 / 255, blue: 0x46 / 255)
    static let strokeBright = Color(red: 0x4A / 255, green: 0x56 / 255, blue: 0x70 / 255)
    static let green = Color(red: 0x7C / 255, green: 0xE3 / 255, blue: 0x8B / 255)
    static let greenDark = Color(red: 0x2F / 255, green: 0x7D / 255, blue: 0x3A / 255)
    static let greenRing = Color(red: 0x4C / 255, green: 0xC3 / 255, blue: 0x5E / 255)
    static let accent = Color(red: 0xF2 / 255, green: 0xA0 / 255, blue: 0x3D / 255)
    static let accentText = Color(red: 0x1A / 255, green: 0x12 / 255, blue: 0x06 / 255)
    static let sas = Color(red: 0x3E / 255, green: 0xC6 / 255, blue: 0xF0 / 255)
    static let muted = Color(red: 0x8C / 255, green: 0x98 / 255, blue: 0xAA / 255)
    static let text = Color(red: 0xE8 / 255, green: 0xEE / 255, blue: 0xF5 / 255)
    static let advice = Color(red: 1.0, green: 0xD5 / 255, blue: 0x4A / 255)
    static let lcd = Color(red: 0xD5 / 255, green: 0xF0 / 255, blue: 0x5A / 255)
    static let consoleTop = Color(red: 0x2E / 255, green: 0x37 / 255, blue: 0x48 / 255)
    static let consoleBottom = Color(red: 0x12 / 255, green: 0x16 / 255, blue: 0x20 / 255)
}

extension View {
    /// Тёмная панель классической раскладки: подложка ~85 % и тонкая рамка.
    func classicPanel(corner: CGFloat = 8, fill: Color = HUDPalette.panel, stroke: Color = HUDPalette.stroke) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }

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

/// Нажатие без своей подложки: лёгкое затемнение (подложку рисует сама метка).
struct HUDPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// Мягкая пульсирующая обводка: «нажмите это», когда помощник советует действие.
struct HUDPulse: ViewModifier {
    var active: Bool
    var corner: CGFloat = 10

    @State private var bright = false

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
                    .strokeBorder(HUDStyle.accent, lineWidth: 2.5)
                    .opacity(bright ? 1 : 0.25)
                    .padding(-3)
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { bright = true }
                    }
                    .onDisappear { bright = false }
            }
        }
    }
}

extension View {
    func hudPulse(_ active: Bool, corner: CGFloat = 10) -> some View {
        modifier(HUDPulse(active: active, corner: corner))
    }
}

/// Малая кнопка (MAX, 0): рисуется 36 × 24 pt, зона касания 40 × 28.
struct HUDMiniButton: View {
    let title: String
    let label: String
    var pulse = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(HUDPalette.text)
                .frame(width: 36, height: 24)
                .background(HUDPalette.panel, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .hudPulse(pulse, corner: 5)
                .frame(width: 40, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel(label)
    }
}
