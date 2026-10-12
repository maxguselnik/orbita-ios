import OrbitPhysics
import SwiftUI

/// HUD полёта поверх 3D-сцены. Держит игровой цикл UI: `FrameDriver` (CADisplayLink с частотой
/// из настроек) каждый кадр вызывает `tick` — ввод → `advance` → новый снимок; само дерево вьюх
/// по кадру не пересобирается. Центр экрана свободен: там жесты камеры.
/// Карта (`model.map.isOpen`): навбол и джойстик уходят, справа — панель узла манёвра,
/// по центру — подписи отметок и ручки Δv (`MapOverlay`).
struct FlightHUDView: View {
    let model: FlightHUDModel
    var frameRate: FrameRate = .hz90
    /// Подсказки первого полёта включены в настройках.
    var hintsEnabled = true
    /// Выход в ангар (пауза, панель результата); модель HUD о `GameFlow` не знает.
    var onHangar: () -> Void = {}

    @AppStorage(HUDHint.doneKey) private var hintsDone = false
    @State private var driver = FrameDriver()
    @State private var showLegend = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let mapOpen = model.map.isOpen
        let guide = hintsEnabled ? model.guide : nil
        ZStack(alignment: .bottom) {
            // Под всеми контролами: получает только касания по пустому месту.
            // Размер всей области — для проекции карты (рендер во весь экран).
            GeometryReader { geo in
                CameraGestureLayer(model: model)
                    .onAppear { model.map.setViewSize(geo.size) }
                    .onChange(of: geo.size) { _, size in model.map.setViewSize(size) }
            }
            .ignoresSafeArea()

            if mapOpen {
                // Подписи отметок и ручки узла: поверх жестов камеры, под контролами.
                MapOverlay(model: model)
            }

            VStack(spacing: 6) {
                HUDTopBar(model: model)

                HStack(alignment: .bottom, spacing: 8) {
                    ThrottleColumn(model: model, guide: guide)
                    if mapOpen {
                        MapCenterColumn(model: model)
                        MapSideColumn(model: model)
                            .overlay(alignment: .topTrailing) { stagePanel }
                    } else {
                        Spacer(minLength: 0)
                        ControlsColumn(model: model, guide: guide)
                            .overlay(alignment: .topTrailing) { stagePanel }
                    }
                }
            }
            .padding(.top, 4)

            if mapOpen {
                MapFocusPicker(model: model, showLegend: $showLegend)
            } else {
                // Навбол строго по центру экрана, независимо от ширины боковых колонок.
                NavballView(model: model, ascentEnabled: hintsEnabled)
            }
        }
        .overlay(alignment: .top) {
            if !mapOpen {
                // Одна строка по центру под верхней полосой: состояние и совет помощника подъёма.
                FlightStatusView(model: model, ascentEnabled: hintsEnabled)
                    .padding(.horizontal, ThrottleColumn.width + 8)
                    .padding(.top, 54)
            }
        }
        .overlay(alignment: .topLeading) {
            if let toast = model.toast {
                Text(toast.text)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .hudBackground(corner: 10)
                    .frame(width: 220)
                    .padding(.leading, ThrottleColumn.width + 12)
                    .padding(.top, 92)
                    .id(toast.id)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .overlay(alignment: .topLeading) {
            if hintsEnabled, !hintsDone, let hint = model.hint, !model.isPaused,
               hint != .stage, hint != .throttle {
                HintBanner(hint: hint) { model.dismissHints() }
                    .frame(width: 220)
                    .padding(.leading, ThrottleColumn.width + 12)
                    .padding(.top, 142)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.hint)
        .overlay(alignment: .bottom) {
            if mapOpen, !model.isPaused {
                // Пошаговая подсказка карты: над переключателем фокуса, центр экрана свободен.
                MapHintHost(model: model, hintsEnabled: hintsEnabled)
                    .padding(.bottom, HUDStyle.minTouch + 16)
            }
        }
        .overlay {
            if mapOpen, showLegend, !model.isPaused {
                MapLegendView(onClose: { showLegend = false })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showLegend)
        .onChange(of: mapOpen) { _, open in
            if !open { showLegend = false }
        }
        .overlay(alignment: .bottom) {
            if let result = model.result, !model.isPaused {
                FlightResultPanel(result: result, onHangar: onHangar,
                                  onRetry: { model.restart() },
                                  onContinue: { model.dismissResult() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.result)
        .overlay {
            if model.isPaused {
                PauseMenu(model: model, onHangar: onHangar)
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

    /// Панель ступеней выезжает поверх правой колонки, «Ступень» остаётся доступной.
    @ViewBuilder private var stagePanel: some View {
        if model.isPanelOpen {
            StagePanel(model: model)
                .padding(.bottom, (model.map.isOpen ? HUDStyle.minTouch : 54) + 8)
                .transition(.move(edge: .trailing).combined(with: .opacity))
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
