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
    var onFinish: (MissionRecord) -> FlightAwardSummary = { _ in FlightAwardSummary() }
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
                MapLayer(model: model, showLegend: $showLegend)
            } else if model.eva != nil {
                // Управляем космонавтом: HUD корабля скрыт целиком.
                EVALayer(model: model)
            } else if model.rover != nil {
                // Активный корабль — ровер: HUD ровера вместо HUD корабля.
                RoverLayer(model: model)
            } else {
                FlightLayer(model: model, guide: guide, hintsEnabled: hintsEnabled, inLesson: inLesson)
            }
        }
        .overlay(alignment: .top) {
            // Тосты и подсказки: по центру под высотомером и строкой совета, ключевых кнопок не закрывают.
            VStack(spacing: 6) {
                if let toast = model.toast, !model.isFlightOverview {
                    Text(toast.text)
                        .font(.system(size: HUDFont.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .hudBackground(corner: 10)
                        .frame(width: 220)
                        .id(toast.id)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if hintsEnabled, !inLesson, !hintsDone, !mapOpen, model.eva != nil || model.rover != nil, let hint = model.hint, !model.isPaused,
                   hint != .stage, hint != .throttle {
                    HintBanner(hint: hint) { model.dismissHints() }
                        .frame(width: 300)
                        .transition(.opacity)
                }
            }
            .padding(.top, mapOpen ? (inLesson ? 100 : 54) : (inLesson ? Self.messageTop + Self.lessonCardExtra : 60))
        }
        .overlay(alignment: .top) {
            // Подсказка по долгому нажатию: в уроке — над плашкой шага (поверх высотомера), иначе под высотомером.
            if let line = model.controlHint, !model.isFlightOverview {
                ControlHintBanner(text: line.text)
                    .id(line.id)
                    .padding(.top, mapOpen ? 54 : (inLesson ? 6 : Self.messageTop + Self.hintOffset))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.controlHint)
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.2), value: model.hint)
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
            if let result = model.result, !model.isPaused, model.eva == nil {
                FlightResultPanel(result: result,
                                  lostData: result.outcome == .crashed ? model.telemetry.science.stored.count : 0,
                                  onHangar: onHangar, onSpaceCenter: onSpaceCenter, onFinish: onFinish,
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

    /// Полоса тостов и подсказок начинается сразу под высотомером (его высота — `AltimeterPanel.panelHeight`).
    private static let messageTop = AltimeterPanel.bottom + 4
    /// Подсказка по долгому нажатию идёт ниже тоста.
    private static let hintOffset: CGFloat = 40
    /// В уроке сверху стоит плашка шага: полоса сообщений уходит ниже неё.
    private static let lessonCardExtra: CGFloat = 116
}

/// Раскладка полёта: компактный HUD; в уроке — он же, с якорями подсветки шагов.
struct FlightLayer: View {
    let model: FlightHUDModel
    let guide: HUDAction?
    let hintsEnabled: Bool
    /// Идёт урок: помощник подъёма выключен, маркер цели на навболе и карточка миссии остаются.
    var inLesson = false

    var body: some View {
        CompactFlightLayer(model: model, guide: guide, hintsEnabled: hintsEnabled, inLesson: inLesson)
    }

    /// Центр капсулы «Пуск» и круга крестовины по высоте — 120 pt от низа; отступы от физических краёв зеркальны:
    /// левый край капсулы и внешний край круга — по 66 pt. Общие для HUD EVA и ровера.
    static let controlCenterFromBottom: CGFloat = 120
    static let stageLeading: CGFloat = 66
    /// Джойстик РСУ классической раскладки: отступ от правого края.
    static let rcsTrailing: CGFloat = 50
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

/// Раскладка карты: сверху время, уровень, «Эксперт»/«Просто» и «Полёт»; слева под шапкой — кнопка цели,
/// справа — карточка узла и «Выполнить манёвр». Центр свободен для жестов и ручек Δv.
struct MapLayer: View {
    let model: FlightHUDModel
    @Binding var showLegend: Bool
    private var contentTop: CGFloat { model.tutorial?.isActive == true ? 104 : 58 }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                MapNavigationHeader(model: model, showLegend: $showLegend)
                    .frame(maxHeight: .infinity, alignment: .top)
                if model.isSystemMap {
                    // Обзор системы: боковых панелей нет, всё управление — в шапке и нижней полосе.
                    SystemMapBottomBar(model: model)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        MapLeftColumn(model: model)
                        Spacer(minLength: 0)
                        MapSideColumn(model: model)
                    }
                    .padding(.top, contentTop)
                    .padding(.bottom, 8)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .foregroundStyle(.white)
        }
    }
}

/// Левая колонка карты: кнопка цели («К Луне ▾») под шапкой.
struct MapLeftColumn: View {
    let model: FlightHUDModel

    static let width = MapGoalsColumn.width

    var body: some View {
        MapGoalsColumn(model: model)
            .frame(width: Self.width, alignment: .topLeading)
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
