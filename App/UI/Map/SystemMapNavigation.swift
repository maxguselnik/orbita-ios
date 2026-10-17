import OrbitPhysics
import SwiftUI

/// Верхняя строка карты. В обзоре системы — время, уровень, «К кораблю» и «Полёт»;
/// у корабля — время, уровень, переключатель «Эксперт» / «Просто» и «Полёт».
struct MapNavigationHeader: View {
    let model: FlightHUDModel
    @Binding var showLegend: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Часы и ускорение не обрезаются: ужимается строка уровня.
            MissionTimeBar(model: model).layoutPriority(1)
            Spacer(minLength: 2)
            MapLevelMenu(model: model, showLegend: $showLegend)
            Spacer(minLength: 2)
            if model.isSystemMap {
                HUDIconButton(systemImage: "location.circle",
                              label: "Вернуться к кораблю и восстановить масштаб",
                              hint: "К кораблю — карта вокруг корабля, исходный масштаб") {
                    model.setMapFocus(.vessel)
                }
                MapToggleButton(model: model).frame(width: 94)
            } else {
                Button { model.setMapExpert(!model.mapExpert) } label: {
                    Text(model.mapExpert ? "Просто" : "Эксперт")
                        .font(.system(size: HUDFont.body, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(HUDButtonStyle())
                .disabled(model.tutorial?.isActive == true)
                .opacity(model.tutorial?.isActive == true ? 0.45 : 1)
                .accessibilityLabel(model.mapExpert ? "Простой режим" : "Режим «Эксперт»")
                .longPressHint(model.mapExpert ? "Просто — цель выбирает игра" : "Эксперт — ручки Δv, оси и время узла вручную")
                MapToggleButton(model: model).frame(width: 94)
            }
        }
        .padding(.top, 4)
    }
}

/// Уровень карты: «Система Сола › Арда ▾»; меню — выбор центра и легенда.
struct MapLevelMenu: View {
    let model: FlightHUDModel
    @Binding var showLegend: Bool

    var body: some View {
        let focus = model.map.focus
        let child: String? = focus == .sol ? nil : model.mapLocationText
        Menu {
            ForEach(MapFocus.allCases, id: \.self) { item in
                Button(MapFocusPicker.name(item)) { model.setMapFocus(item) }
            }
            Button("Легенда карты", systemImage: "questionmark") { showLegend = true }
        } label: {
            HStack(spacing: 5) {
                Text("Система Сола")
                    .foregroundStyle(child == nil ? Color.white : HUDStyle.secondaryText)
                if let child {
                    Image(systemName: "chevron.right").font(.system(size: 9))
                        .foregroundStyle(HUDStyle.secondaryText)
                    Text(child).foregroundStyle(HUDStyle.active)
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: HUDFont.body, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
        }
        .menuOrder(.fixed)
        .buttonStyle(HUDButtonStyle())
        .tutorialAnchor(.mapFocus)
        .accessibilityLabel("Уровень карты: \(child ?? "Система Сола"), выбрать")
    }
}

/// Нижняя полоса обзора системы: объекты, карточка выбранного тела или прожиг со «Стоп».
struct SystemMapBottomBar: View {
    let model: FlightHUDModel

    var body: some View {
        VStack(spacing: 4) {
            // Отсчёт окна к планете: карта сама переходит в обзор системы на время ожидания.
            if let wait = model.planetWaitText, !model.isAutoBurning {
                Text(wait)
                    .font(.system(size: HUDFont.body, weight: .semibold).monospacedDigit())
                    .foregroundStyle(HUDPalette.green)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .hudBackground()
                    .allowsHitTesting(false)
            }
            if model.isAutoBurning {
                SystemMapBurnRow(model: model)
            } else if let body = model.map.focus.bodyID, body != .sol {
                SystemMapSelection(model: model, bodyID: body)
            } else {
                SystemMapObjects(model: model)
            }
        }
        .padding(.bottom, 6)
    }
}

/// Объекты системы одной строкой; отметка — где корабль. Справа — шаги масштаба.
struct SystemMapObjects: View {
    let model: FlightHUDModel
    private let objects: [MapFocus] = [.vella, .terra, .luna, .arda, .taros]
    /// Шаг масштаба кнопками «−» / «+».
    private static let zoomStep: Float = 0.6

    var body: some View {
        HStack(spacing: 6) {
            ForEach(objects, id: \.self) { focus in
                let here = focus.bodyID == model.telemetry.body
                Button { model.setMapFocus(focus) } label: {
                    HStack(spacing: 4) {
                        Text(MapFocusPicker.name(focus))
                        if here { Image(systemName: "location.fill").font(.system(size: 10)) }
                    }
                    .font(.system(size: HUDFont.body, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if here {
                            RoundedRectangle(cornerRadius: 8).stroke(HUDStyle.active, lineWidth: 1)
                                .padding(-6)
                        }
                    }
                }
                .buttonStyle(HUDButtonStyle())
                .accessibilityLabel("Рассмотреть: \(MapFocusPicker.name(focus))")
                .accessibilityValue(here ? "Корабль здесь" : "")
            }
            Spacer(minLength: 8)
            Button { model.cameraZoom(1 / Self.zoomStep) } label: {
                Image(systemName: "minus").font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Отдалить карту")
            Button { model.cameraZoom(Self.zoomStep) } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Приблизить карту")
        }
        .padding(4)
        .hudBackground()
    }
}

/// Карточка выбранного тела вместо полосы объектов: «‹» назад, сведения, «Поставить маршрут».
struct SystemMapSelection: View {
    let model: FlightHUDModel
    let bodyID: BodyID

    var body: some View {
        let here = bodyID == model.telemetry.body
        let goal = FlightHUDModel.routeGoal(to: bodyID)
        let canPlan = goal.map { model.availableGoals.contains($0) } ?? false
        HStack(spacing: 10) {
            Button { model.setMapFocus(.sol) } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Назад к списку объектов")
            VStack(alignment: .leading, spacing: 2) {
                Text(Bodies.body(bodyID).name).font(.system(size: HUDFont.value, weight: .bold))
                Text(detail(here: here, canPlan: canPlan))
                    .font(.system(size: HUDFont.caption))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            Button { model.planRouteToFocusedBody() } label: {
                Text(here ? "Показать корабль" : "Поставить маршрут")
                    .font(.system(size: HUDFont.body, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 14)
            }
            .buttonStyle(HUDButtonStyle(isActive: true))
            .disabled(!here && !canPlan)
            .opacity(!here && !canPlan ? 0.45 : 1)
        }
        .padding(4)
        .hudBackground()
    }

    private func detail(here: Bool, canPlan: Bool) -> String {
        if here { return "Корабль у этого тела" }
        // Название уже в заголовке карточки: оставляем только «g … · средняя …».
        let info = MapFocusPicker.info(bodyID).replacingOccurrences(of: Bodies.body(bodyID).name + " · ", with: "")
        return canPlan ? info : info + "\nМаршрут пока недоступен с текущей орбиты"
    }
}

/// Во время автопрожига полоса объектов уступает место строке прожига и «Стоп».
struct SystemMapBurnRow: View {
    let model: FlightHUDModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.maneuverGoal.map { "Прожиг: " + MapGoalsColumn.title($0) } ?? "Автопрожиг")
                .font(.system(size: HUDFont.body, weight: .semibold))
                .foregroundStyle(HUDPalette.green)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: HUDStyle.minTouch, alignment: .leading)
                .hudBackground()
            ManeuverExecuteButton(model: model).frame(width: MapSideColumn.width)
        }
    }
}
