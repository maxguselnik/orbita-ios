import SwiftUI

/// Меню паузы. «Сохранить» и «Загрузить» — заглушки до этапа 10.
struct PauseMenu: View {
    let model: FlightHUDModel
    let onHangar: () -> Void
    /// Урок — новый полёт («Первый полёт», «К Луне»); «Все кнопки» идут поверх текущего полёта.
    var onTutorial: (TutorialID) -> Void = { _ in }

    @State private var note: String?
    @State private var showLessons = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { model.resume() }

            if showLessons {
                TutorialListPanel(context: .flight, onStart: start, onClose: { showLessons = false })
            } else {
                menu
            }
        }
    }

    private func start(_ id: TutorialID) {
        if id == .controls {
            model.startTour()
        } else {
            onTutorial(id)
        }
    }

    private var menu: some View {
        VStack(spacing: 8) {
            Text("Пауза")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.bottom, 4)

            item("Продолжить", systemImage: "play.fill", primary: true) { model.resume() }
            HStack(spacing: 8) {
                item("Сохранить", systemImage: "square.and.arrow.down") { note = "Сохранения — на этапе 10" }
                item("Загрузить", systemImage: "folder") { note = "Загрузка — на этапе 10" }
            }
            HStack(spacing: 8) {
                item("Перезапуск", systemImage: "arrow.counterclockwise") { model.restart() }
                item("Ангар", systemImage: "wrench.and.screwdriver") { onHangar() }
            }
            item("Обучение", systemImage: "graduationcap") { showLessons = true }

            Text(note ?? " ")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HUDStyle.secondaryText)
                .frame(height: 16)
        }
        .padding(16)
        .frame(width: 340)
        .hudBackground(Color.black.opacity(0.85), corner: 18)
    }

    private func item(_ title: String, systemImage: String, primary: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(HUDButtonStyle(isActive: primary))
    }
}
