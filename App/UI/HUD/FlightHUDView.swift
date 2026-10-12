import OrbitPhysics
import SwiftUI

/// HUD полёта поверх 3D-сцены. Держит игровой цикл UI: `FrameDriver` (CADisplayLink с частотой
/// из настроек) каждый кадр вызывает `tick` — ввод → `advance` → новый снимок; само дерево вьюх
/// по кадру не пересобирается. Центр экрана свободен: там жесты камеры.
/// Раскладка Б4 «лаконичный»: сверху слева время и ускорение, по центру высотомер и строка совета, справа экипаж
/// и кнопки Карта/Камера; слева стопка ступеней и кнопка действия; снизу по центру кольцо навбола (тяга, перегрузка,
/// SAS, RCS), справа джойстик и MAX/0; при включённом РСУ — поступательный джойстик между ступенью и навболом.
/// Карта (`model.map.isOpen`): навбол и джойстик уходят, справа — панель узла манёвра, по центру — подписи отметок
/// и ручки Δv (`MapOverlay`).
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

            if mapOpen {
                MapLayer(model: model)
                MapFocusPicker(model: model, showLegend: $showLegend)
            } else {
                FlightLayer(model: model, guide: guide, hintsEnabled: hintsEnabled)
            }
        }
        .overlay(alignment: .top) {
            // Тосты и подсказки: по центру под высотомером и строкой совета, ключевых кнопок не закрывают.
            VStack(spacing: 6) {
                if let toast = model.toast {
                    Text(toast.text)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .hudBackground(corner: 10)
                        .frame(width: 220)
                        .id(toast.id)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if hintsEnabled, !hintsDone, let hint = model.hint, !model.isPaused,
                   hint != .stage, hint != .throttle {
                    HintBanner(hint: hint) { model.dismissHints() }
                        .frame(width: 300)
                        .transition(.opacity)
                }
            }
            .padding(.top, mapOpen ? 54 : 60)
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.2), value: model.hint)
        .overlay(alignment: .topTrailing) { stagePanel }
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

    /// Панель ступеней выезжает слева от правых иконок; джойстик и MAX остаются доступными.
    @ViewBuilder private var stagePanel: some View {
        if model.isPanelOpen {
            StagePanel(model: model)
                .padding(.top, 6)
                .padding(.trailing, model.map.isOpen ? HUDStyle.minTouch + 8 : 42)
                .padding(.bottom, model.map.isOpen ? 60 : 100)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

/// Раскладка полёта: все элементы привязаны к краям и углам, центр экрана свободен для жестов камеры.
struct FlightLayer: View {
    let model: FlightHUDModel
    let guide: HUDAction?
    let hintsEnabled: Bool

    var body: some View {
        ZStack {
            topLeft
            topCenter
            topRight
            leftColumn
            bottomLeft
            bottomCenter
            bottomRight
        }
        // Кольцо навбола уходит за нижний край, поэтому нижняя безопасная зона не сдвигает его.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var topLeft: some View {
        MissionTimeBar(model: model)
            .padding(.top, 6)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var topCenter: some View {
        VStack(spacing: 3) {
            AltimeterPanel(model: model)
            FlightStatusView(model: model, ascentEnabled: hintsEnabled)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var topRight: some View {
        HStack(alignment: .top, spacing: 2) {
            if CrewPlaceholder.hasCabin(model.parts) {
                CrewPlaceholder()
                    .padding(.top, 2)
                    .padding(.trailing, 2)
            }
            FlightCornerButtons(model: model)
        }
        .padding(.trailing, 2)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    /// Отступ нижнего ряда блока ориентации от нижнего края, pt (центр креста ≈ 140 pt над краем).
    static let attitudeBottom: CGFloat = 56

    /// Стопка ступеней под строкой времени и карточка миссии; если развёрнутая карточка упирается в блок кнопок
    /// ориентации, она сворачивается в одну строку.
    private var leftColumn: some View {
        GeometryReader { geo in
            let blockTop = geo.size.height - Self.attitudeBottom - AttitudeControls.side
            let rows = CGFloat(StageStackView.rowCount(model: model))
            let stackHeight = rows > 0 ? rows * StageGroupRow.height + (rows - 1) * 3 : 0
            let fits = MissionCard.fitsExpanded(stackHeight: stackHeight, blockTop: blockTop)
            VStack(alignment: .leading, spacing: 6) {
                StageStackView(model: model)
                MissionCard(model: model, enabled: hintsEnabled, forceCollapsed: !fits)
            }
            .padding(.top, 36)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Блок кнопок ориентации в левом нижнем углу, поднят над краем (боковую безопасную зону даёт родитель).
    private var bottomLeft: some View {
        AttitudeControls(model: model)
            .opacity(model.onPad ? 0.5 : 1)
            .padding(.leading, 16)
            .padding(.bottom, Self.attitudeBottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var bottomCenter: some View {
        NavballCluster(model: model, ascentEnabled: hintsEnabled)
            .offset(y: NavballCluster.overhang)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Правый нижний угол: сверху вниз плашка узла, джойстик РСУ (если включено), ниже MAX/0 и «Ступень» у края.
    private var bottomRight: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ManeuverBadgeHost(model: model)
            RCSControlsHost(model: model)
            HStack(alignment: .bottom, spacing: 6) {
                ControlsCluster(model: model, guide: guide)
                StageButton(model: model, highlighted: guide == .stage)
            }
        }
        .padding(.trailing, 6)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

/// Поступательное управление РСУ появляется, пока РСУ включено и на корабле есть блоки.
struct RCSControlsHost: View {
    let model: FlightHUDModel

    var body: some View {
        let rcs = model.rcs
        if rcs.enabled, rcs.available {
            RCSControls(model: model)
        }
    }
}

/// Плашка узла манёвра над блоком кнопок ориентации (тап — карта); читает телеметрию узла каждый кадр.
struct ManeuverBadgeHost: View {
    let model: FlightHUDModel

    var body: some View {
        if let status = model.telemetry.maneuver {
            ManeuverBadge(status: status) { model.toggleMap() }
        }
    }
}

/// Раскладка карты: время сверху слева, «Ступени» справа, слева SAS и «Полёт», по центру — сводка карты,
/// справа — панель узла манёвра и «Ступень».
struct MapLayer: View {
    let model: FlightHUDModel

    var body: some View {
        ZStack {
            MissionTimeBar(model: model)
                .padding(.top, 6)
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            StagePanelButton(model: model)
                .padding(.trailing, 4)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            HStack(alignment: .bottom, spacing: 8) {
                MapLeftColumn(model: model)
                MapCenterColumn(model: model)
                MapSideColumn(model: model)
            }
            .padding(.top, 50)
        }
    }
}

/// Левая колонка карты: SAS (вкл/выкл и «по узлу») и кнопка «Полёт».
struct MapLeftColumn: View {
    let model: FlightHUDModel

    static let width: CGFloat = 156

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            MapSASRow(model: model)
            MapToggleButton(model: model)
        }
        .frame(width: Self.width)
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
