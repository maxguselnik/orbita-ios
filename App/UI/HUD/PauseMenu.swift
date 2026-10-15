import SwiftUI

/// Меню паузы. Сохранение и загрузка скрыты, пока не готовы (этап 10).
struct PauseMenu: View {
    let model: FlightHUDModel
    let onHangar: () -> Void
    /// Урок — новый полёт («Первый полёт», «К Луне»).
    var onTutorial: (TutorialID) -> Void = { _ in }

    @State private var confirmRestart = false
    @State private var confirmHangar = false
    @State private var showLessons = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { model.resume() }

            if showLessons {
                TutorialListPanel(context: .flight, onStart: onTutorial, onClose: { showLessons = false })
            } else {
                menu
            }
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
                item("Начать заново", systemImage: "arrow.counterclockwise") { confirmRestart = true }
                item("Ангар", systemImage: "wrench.and.screwdriver") { confirmHangar = true }
            }
            item("Обучение", systemImage: "graduationcap") { showLessons = true }
        }
        .padding(16)
        .frame(width: 340)
        .hudBackground(Color.black.opacity(0.85), corner: 18)
        .alert("Начать полёт заново?", isPresented: $confirmRestart) {
            Button("Начать заново", role: .destructive) { model.restart() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Текущий полёт не сохранится.")
        }
        .alert("Выйти в ангар?", isPresented: $confirmHangar) {
            Button("Выйти", role: .destructive) { onHangar() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Текущий полёт не сохранится.")
        }
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
