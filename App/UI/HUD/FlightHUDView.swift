import OrbitPhysics
import SwiftUI

/// HUD полёта поверх 3D-сцены. Держит игровой цикл UI: `FrameDriver` (CADisplayLink с частотой
/// из настроек) каждый кадр вызывает `tick` — ввод → `advance` → новый снимок; само дерево вьюх
/// по кадру не пересобирается. Центр экрана свободен: там жесты камеры.
/// Раскладка Б4 «лаконичный»: сверху слева время и ускорение, по центру высотомер и строка совета, справа экипаж
/// и кнопки Карта/Камера; слева стопка ступеней и кнопка действия; снизу по центру кольцо навбола (тяга, перегрузка,
/// SAS, RCS), справа джойстик и MAX/0; при включённом РСУ — поступательный джойстик между ступенью и навболом.
/// Карта (`model.map.isOpen`): навбол остаётся для ручной тяги и SAS, справа — панель узла, по центру — подписи отметок
/// и ручки Δv (`MapOverlay`).
struct FlightHUDView: View {
    let model: FlightHUDModel
    var frameRate: FrameRate = .hz90
    /// Подсказки первого полёта включены в настройках.
    var hintsEnabled = true
    /// Выход в ангар (пауза, панель результата); модель HUD о `GameFlow` не знает.
    var onHangar: () -> Void = {}
    /// Выход в космоцентр (панель результата).
    var onSpaceCenter: () -> Void = {}
    /// Начислить науку за итог полёта (один раз на полёт, `GameFlow.finishFlight`); модель HUD о `GameFlow` не знает.
    var onFinish: (MissionRecord) -> (fresh: [Milestone], science: Int) = { _ in ([], 0) }
    /// Урок из меню паузы: новый полёт по уроку (модель HUD о `GameFlow` не знает).
    var onTutorial: (TutorialID) -> Void = { _ in }

    @AppStorage(HUDHint.doneKey) private var hintsDone = false
    @State private var driver = FrameDriver()
    @State private var showLegend = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let mapOpen = model.map.isOpen
        // Пока идёт урок, подсказки первого полёта и помощник подъёма не дублируют его (маркер цели на навболе остаётся).
        let inLesson = model.tutorial?.isActive == true
        let guide = hintsEnabled && !inLesson ? model.guide : nil
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
                NavballCluster(model: model, ascentEnabled: false)
                    .padding(.bottom, NavballCluster.lift)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.container, edges: .bottom)
                MapFocusPicker(model: model, showLegend: $showLegend)
                    .padding(.bottom, Self.mapFocusBottom)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                FlightLayer(model: model, guide: guide, hintsEnabled: hintsEnabled, inLesson: inLesson)
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
                if hintsEnabled, !inLesson, !hintsDone, !mapOpen, let hint = model.hint, !model.isPaused,
                   hint != .stage, hint != .throttle {
                    HintBanner(hint: hint) { model.dismissHints() }
                        .frame(width: 300)
                        .transition(.opacity)
                }
            }
            .padding(.top, mapOpen ? (inLesson ? 100 : 54) : (inLesson ? 176 : 60))
        }
        .overlay(alignment: .top) {
            // Подсказка по долгому нажатию: в уроке — над плашкой шага (поверх высотомера), иначе под высотомером.
            if let line = model.controlHint {
                ControlHintBanner(text: line.text)
                    .id(line.id)
                    .padding(.top, mapOpen ? 54 : (inLesson ? 6 : 100))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.controlHint)
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.2), value: model.hint)
        .overlay(alignment: .topTrailing) { stagePanel }
        .overlay(alignment: .bottom) {
            if mapOpen, model.mapExpert, !model.isPaused {
                // Пошаговая подсказка карты: над переключателем фокуса, центр экрана свободен.
                MapHintHost(model: model, hintsEnabled: hintsEnabled && !inLesson)
                    .padding(.bottom, Self.mapFocusBottom + HUDStyle.minTouch + 16)
                    .ignoresSafeArea(.container, edges: .bottom)
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
                FlightResultPanel(result: result, onHangar: onHangar, onSpaceCenter: onSpaceCenter, onFinish: onFinish,
                                  onRetry: { model.restart() },
                                  onContinue: { model.dismissResult() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.result)
        .overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
            if let tutorial = model.tutorial {
                TutorialOverlay(controller: tutorial, model: model, anchors: anchors, onHangar: onHangar)
            }
        }
        .overlay {
            if model.isPaused {
                PauseMenu(model: model, onHangar: onHangar, onTutorial: onTutorial)
            }
        }
        .environment(\.showControlHint, { [model] text in model.showControlHint(text) })
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

    /// Фокус карты расположен над навболом; его нижняя часть уходит за физический край экрана.
    private static let mapFocusBottom = NavballCluster.height + NavballCluster.lift + 8

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
    /// Идёт урок: помощник подъёма в строке состояния выключен, маркер цели и карточка миссии остаются.
    var inLesson = false

    var body: some View {
        ZStack {
            topLeft
            topCenter
            topRight
            bottomRight
            bottomCenter
            bottomLeft
            leftColumn
        }
        // Элементы нижнего ряда считаются от физического низа экрана.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var topLeft: some View {
        MissionTimeBar(model: model)
            .tutorialAnchor(.timeBar)
            .padding(.top, 6)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var topCenter: some View {
        VStack(spacing: 3) {
            AltimeterPanel(model: model)
                .tutorialAnchor(.altimeter)
            FlightStatusView(model: model, ascentEnabled: hintsEnabled && !inLesson)
            ThermalGauge(model: model)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var topRight: some View {
        HStack(alignment: .top, spacing: 2) {
            if !model.crew.isEmpty {
                CrewStrip(crew: model.crew)
                    .tutorialAnchor(.crew)
                    .padding(.top, 2)
                    .padding(.trailing, 2)
            }
            FlightCornerButtons(model: model)
                .tutorialAnchor(.corner)
        }
        .padding(.trailing, 2)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    /// Центр капсулы «Пуск» и круга крестовины по высоте — 120 pt от низа; отступы от физических краёв зеркальны:
    /// левый край капсулы и внешний край круга — по 66 pt.
    static let controlCenterFromBottom: CGFloat = 120
    static let stageLeading: CGFloat = 66

    /// Стопка ступеней под строкой времени и карточка миссии под ней. Карточка выше остальных слоёв: развёрнутая (по тапу)
    /// перекрывает их и перехватывает касания. По умолчанию развёрнута, только если помещается над капсулой «Пуск».
    private var leftColumn: some View {
        GeometryReader { geo in
            let capsuleTop = geo.size.height - Self.controlCenterFromBottom - StageButton.height / 2
            let rows = CGFloat(StageStackView.rowCount(model: model))
            let stackHeight = rows > 0 ? rows * StageGroupRow.height + (rows - 1) * 3 : 0
            let fits = MissionCard.fitsExpanded(stackHeight: stackHeight, blockTop: capsuleTop)
            VStack(alignment: .leading, spacing: MissionCard.gap) {
                StageStackView(model: model)
                    .tutorialAnchor(.stageStack)
                MissionCard(model: model, enabled: hintsEnabled || inLesson, autoExpand: fits)
                    .tutorialAnchor(.mission)
            }
            .padding(.top, 36)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Левый нижний угол: капсула «Пуск» от физического края (66 pt), над ней плашка узла манёвра.
    private var bottomLeft: some View {
        VStack(alignment: .leading, spacing: 6) {
            ManeuverBadgeHost(model: model)
            StageButton(model: model, highlighted: guide == .stage)
                .tutorialAnchor(.stageButton)
        }
        .padding(.leading, Self.stageLeading)
        .padding(.bottom, Self.controlCenterFromBottom - StageButton.height / 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    private var bottomCenter: some View {
        NavballCluster(model: model, ascentEnabled: hintsEnabled || inLesson, guide: guide)
            .padding(.bottom, NavballCluster.lift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Правый нижний угол: круглая крестовина, крен и «ТОЧНО» от физического края; над кнопкой крена — джойстик РСУ.
    static let rcsTrailing: CGFloat = 50

    private var bottomRight: some View {
        ZStack(alignment: .bottomTrailing) {
            AttitudeControls(model: model)
                .padding(.trailing, AttitudeControls.trailingInset)
                .padding(.bottom, AttitudeControls.bottomInset)
            RCSControlsHost(model: model)
                .padding(.trailing, Self.rcsTrailing)
                .padding(.bottom, AttitudeControls.bottomInset + AttitudeControls.frameSize.height + 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .ignoresSafeArea(.container, edges: .horizontal)
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
            ManeuverBadge(status: status, autoText: model.autoBurnText) { model.toggleMap() }
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

/// Левая колонка карты: цели «Куда летим?» сверху, внизу SAS (вкл/выкл и «по узлу») и кнопка «Полёт».
struct MapLeftColumn: View {
    let model: FlightHUDModel

    static let width: CGFloat = 156

    var body: some View {
        VStack(spacing: 6) {
            MapGoalsColumn(model: model)
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
