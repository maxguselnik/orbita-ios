import SwiftUI

/// Меню паузы. «Продолжить» и «Перезапуск» работают, остальное — заглушки.
struct PauseMenu: View {
    let model: FlightHUDModel

    @State private var note: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { model.resume() }

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
                    item("Ангар", systemImage: "wrench.and.screwdriver") { note = "Ангар — на этапе 3" }
                }

                Text(note ?? " ")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .frame(height: 16)
            }
            .padding(16)
            .frame(width: 340)
            .hudBackground(Color.black.opacity(0.85), corner: 18)
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
