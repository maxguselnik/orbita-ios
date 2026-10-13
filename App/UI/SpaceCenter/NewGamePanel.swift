import OrbitPhysics
import SwiftUI

/// Выбор режима новой игры: песочница, наука, карьера (этап 8, пока недоступна).
struct NewGamePanel: View {
    let canCancel: Bool
    let onStart: (GameMode) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 10) {
                Text("Новая игра")
                    .font(.system(size: 22, weight: .heavy))
                HStack(spacing: 10) {
                    card(.sandbox, "Песочница", "Все детали открыты", enabled: true)
                    card(.science, "Наука", "Детали за науку", enabled: true)
                    card(.career, "Карьера", "Этап 8", enabled: false)
                }
                if canCancel {
                    Text("Прогресс текущей игры (наука, технологии, вехи) будет сброшен.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HUDStyle.secondaryText)
                    Button("Отмена", action: onCancel)
                        .font(.system(size: 15, weight: .bold))
                        .buttonStyle(HUDButtonStyle())
                }
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: 560)
            .hudBackground(Color.black.opacity(0.88), corner: 18)
        }
    }

    private func card(_ mode: GameMode, _ title: String, _ subtitle: String, enabled: Bool) -> some View {
        Button { onStart(mode) } label: {
            VStack(spacing: 6) {
                Image(systemName: icon(mode)).font(.system(size: 24, weight: .semibold))
                Text(title).font(.system(size: 16, weight: .heavy))
                Text(subtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .padding(8)
        }
        .buttonStyle(HUDButtonStyle(isActive: false))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(title + ", " + subtitle)
    }

    private func icon(_ mode: GameMode) -> String {
        switch mode {
        case .sandbox: "cube.transparent"
        case .science: "atom"
        case .career: "briefcase"
        }
    }
}

/// Меню космоцентра: настройки и обучение.
struct GameMenuPanel: View {
    @Bindable var settings: GameSettings
    let onLessons: () -> Void
    let onNewGame: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Меню").font(.system(size: 20, weight: .heavy))
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть меню")
            }
            HStack(spacing: 14) {
                VStack(spacing: 2) {
                    Toggle("Звук", isOn: $settings.soundEnabled)
                    Toggle("Вибрация", isOn: $settings.hapticsEnabled)
                }
                VStack(spacing: 2) {
                    Toggle("Подсказки", isOn: $settings.hintsEnabled)
                    Toggle("Наклон телефона", isOn: $settings.tiltControl)
                }
            }
            .font(.system(size: 14, weight: .semibold))
            HStack {
                Text("Частота кадров").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Picker("Частота кадров", selection: $settings.frameRate) {
                    ForEach(FrameRate.allCases, id: \.self) { rate in
                        Text("\(rate.rawValue) Гц").tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            HStack(spacing: 8) {
                Button(action: onLessons) {
                    Label("Обучение", systemImage: "graduationcap")
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(HUDButtonStyle(isActive: true))
                Button(action: onNewGame) {
                    Label("Новая игра", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(HUDButtonStyle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: 460)
        .hudBackground(Color.black.opacity(0.88), corner: 18)
    }
}
