import UIKit

/// Лёгкая вибрация интерфейса ангара. Настройку «Вибрация» проверяет вызывающий.
@MainActor
enum UIFeedback {
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Выбор, переключатель, тап по детали.
    static func tap() {
        selection.selectionChanged()
        selection.prepare()
    }

    /// Предупреждение: нельзя, не хватает, ошибка сборки.
    static func warning() {
        notification.notificationOccurred(.warning)
        notification.prepare()
    }
}
