import OrbitPhysics
import SwiftUI

/// HUD полёта поверх 3D-сцены. Держит игровой цикл UI: каждый кадр `tick` —
/// ввод → `advance` → новый снимок. Центр экрана свободен для камеры.
struct FlightHUDView: View {
    let model: FlightHUDModel

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: model.isPaused)) { context in
            content
                .onChange(of: context.date) { _, date in
                    model.tick(date)
                }
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            HUDTopBar(model: model)

            HStack(alignment: .bottom, spacing: 8) {
                ThrottleColumn(model: model)
                Spacer(minLength: 0)
                NavballStub(telemetry: model.telemetry)
                Spacer(minLength: 0)
                ControlsColumn(model: model)
                    .overlay(alignment: .topTrailing) {
                        if model.isPanelOpen {
                            // Панель выезжает поверх SAS и джойстика, «Ступень» остаётся доступной.
                            StagePanel(model: model)
                                .padding(.bottom, 54 + 8)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(toast.text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .hudBackground(corner: 10)
                    .padding(.top, 62)
                    .id(toast.id)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .overlay {
            if model.isPaused {
                PauseMenu(model: model)
            }
        }
    }
}

#Preview("HUD", traits: .landscapeLeft) {
    @Previewable @State var model = FlightHUDModel()
    ZStack {
        LinearGradient(colors: [.black, Color(red: 0.1, green: 0.2, blue: 0.4)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        FlightHUDView(model: model)
    }
}
