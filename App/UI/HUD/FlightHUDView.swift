import OrbitPhysics
import SwiftUI

/// HUD полёта поверх 3D-сцены. Держит игровой цикл UI: `FrameDriver` (CADisplayLink с частотой
/// из настроек) каждый кадр вызывает `tick` — ввод → `advance` → новый снимок; само дерево вьюх
/// по кадру не пересобирается. Центр экрана свободен: там жесты камеры.
struct FlightHUDView: View {
    let model: FlightHUDModel
    var frameRate: FrameRate = .hz90

    @State private var driver = FrameDriver()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottom) {
            // Под всеми контролами: получает только касания по пустому месту.
            CameraGestureLayer(model: model)
                .ignoresSafeArea()

            VStack(spacing: 6) {
                HUDTopBar(model: model)

                HStack(alignment: .bottom, spacing: 8) {
                    ThrottleColumn(model: model)
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

            // Навбол строго по центру экрана, независимо от ширины боковых колонок.
            NavballView(model: model)
        }
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
        .onAppear {
            driver.frameRate = frameRate
            driver.start { [model] now in model.tick(now: now) }
        }
        .onDisappear { driver.stop() }
        .onChange(of: frameRate) { _, rate in driver.frameRate = rate }
        .onChange(of: scenePhase) { old, new in
            // Уход в фон или системная шторка — пауза с меню.
            if old == .active, new != .active, !model.isPaused {
                model.pause()
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
