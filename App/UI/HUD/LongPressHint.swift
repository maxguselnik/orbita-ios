import SwiftUI

/// Подсказка кнопки по долгому нажатию (0.5 с): одна строка на 3 с, действие кнопки не выполняется.
/// Заменяет тур «Все кнопки».
enum ControlHint {
    /// Сколько секунд подсказка висит на экране.
    static let duration: TimeInterval = 3
    /// Через сколько секунд удержания показывается подсказка.
    static let holdTime: TimeInterval = 0.5
}

/// Строка подсказки в модели (id нужен, чтобы повторное нажатие перезапускало показ).
struct ControlHintLine: Equatable, Identifiable {
    let id: Int
    let text: String
}

/// Что делает долгое нажатие: показывает строку подсказки в модели полёта.
private struct ShowControlHintKey: EnvironmentKey {
    static let defaultValue: @MainActor (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var showControlHint: @MainActor (String) -> Void {
        get { self[ShowControlHintKey.self] }
        set { self[ShowControlHintKey.self] = newValue }
    }
}

private struct LongPressHintModifier: ViewModifier {
    let text: String
    /// Контроль сам по себе «держится» (крестовина, дуга тяги, ползунок): подсказка не отменяет его действие.
    let isHold: Bool

    @Environment(\.showControlHint) private var show

    func body(content: Content) -> some View {
        let gesture = LongPressGesture(minimumDuration: ControlHint.holdTime)
            .onEnded { _ in show(text) }
        if isHold {
            content.simultaneousGesture(gesture)
        } else {
            // Приоритетный жест: после 0.5 с удержания нажатие кнопки отменяется, быстрый тап проходит как обычно.
            content.highPriorityGesture(gesture)
        }
    }
}

extension View {
    /// Долгое нажатие показывает подсказку `text`. Для кнопок действие при этом не выполняется;
    /// для удерживаемых контролов (`isHold`) подсказка появляется поверх обычного действия.
    func longPressHint(_ text: String, isHold: Bool = false) -> some View {
        modifier(LongPressHintModifier(text: text, isHold: isHold))
    }
}

/// Строка подсказки сверху: появляется по долгому нажатию, сама гаснет через 3 с.
struct ControlHintBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: 460)
            .hudBackground(corner: 10)
            .allowsHitTesting(false)
            .accessibilityLabel(text)
    }
}
