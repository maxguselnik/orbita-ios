import OrbitPhysics
import SwiftUI

/// Цвета карты: встреча — фиолетовая, возврат — оранжевый, как орбиты в рендере.
enum MapPalette {
    static let encounter = Color(red: 0.74, green: 0.48, blue: 1.0)
    static let returnTrip = Color(red: 1.0, green: 0.6, blue: 0.2)
    static let impact = Color(red: 1.0, green: 0.36, blue: 0.32)
    static let afterManeuver = Color(red: 1.0, green: 0.86, blue: 0.3)
    static let ready = Color(red: 0.4, green: 0.95, blue: 0.5)
}

/// Названия тел в нужном падеже для подсказок карты.
enum MapText {
    /// «Луны», «Терры».
    static func genitive(_ body: BodyID) -> String {
        switch body {
        case .terra: "Терры"
        case .luna: "Луны"
        case .sol: "Сола"
        case .vella: "Веллы"
        case .arda: "Арды"
        case .taros: "Тароса"
        }
    }

    /// «Луной», «Террой».
    static func instrumental(_ body: BodyID) -> String {
        switch body {
        case .terra: "Террой"
        case .luna: "Луной"
        case .sol: "Солом"
        case .vella: "Веллой"
        case .arda: "Ардой"
        case .taros: "Таросом"
        }
    }

    /// «Луну», «Терру».
    static func accusative(_ body: BodyID) -> String {
        switch body {
        case .terra: "Терру"
        case .luna: "Луну"
        case .sol: "Сол"
        case .vella: "Веллу"
        case .arda: "Арду"
        case .taros: "Тарос"
        }
    }

    /// «Пе 32.0 км».
    static func periapsis(_ altitude: Double) -> String {
        "Пе " + HUDFormat.distance(altitude)
    }

    /// Угол в радианах → «−112°».
    static func degrees(_ radians: Double) -> String {
        guard radians.isFinite else { return HUDFormat.dash }
        let value = Int((radians * 180 / .pi).rounded())
        return (value < 0 ? HUDFormat.minus : "") + "\(abs(value))°"
    }
}

// MARK: - Левая колонка

/// Кнопка «Полёт» на карте (в полёте карта открывается иконкой справа сверху).
struct MapToggleButton: View {
    let model: FlightHUDModel

    var body: some View {
        let open = model.map.isOpen
        Button {
            model.toggleMap()
        } label: {
            Label(open ? "Полёт" : "Карта", systemImage: open ? "scope" : "map")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(HUDButtonStyle(isActive: open))
        .tutorialAnchor(.mapFlight)
        .accessibilityLabel(open ? "Закрыть карту" : "Открыть карту")
        .longPressHint(open ? "Полёт — вернуться к управлению кораблём" : "Карта: орбиты, Луна и манёвры")
    }
}

// MARK: - Цель («Куда летим?»)

/// Кнопка цели простой карты: «главная» цель (текущая цель урока, иначе активная, иначе первая) и «▾» с меню всех целей.
/// Тап по названию ставит узел по главной цели. Нет целей — кнопки нет.
struct MapGoalsColumn: View {
    let model: FlightHUDModel

    static let width: CGFloat = 156
    private static let menuWidth = HUDStyle.minTouch

    var body: some View {
        let goals = model.availableGoals
        let active = model.maneuverGoal
        let lesson = model.tutorial?.isActive == true ? (model.tutorial?.display.targets ?? []) : []
        if let main = Self.mainGoal(goals, active: active, lessonTargets: lesson) {
            let several = goals.count > 1
            HStack(spacing: 2) {
                Button {
                    model.planManeuver(main)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Self.icon(main))
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 18)
                        Text(Self.title(main))
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HUDButtonStyle(isActive: main == active))
                .tutorialAnchor(optional: Self.anchor(main))
                .accessibilityLabel(Self.title(main))
                .accessibilityHint("Игра сама поставит узел манёвра")
                .longPressHint(Self.hint(main))
                .accessibilityAddTraits(main == active ? .isSelected : [])
                if several {
                    Menu {
                        ForEach(goals, id: \.self) { goal in
                            Button {
                                model.planManeuver(goal)
                            } label: {
                                if let window = model.planetWindowText(goal) {
                                    Text(Self.title(goal) + " · " + window)
                                } else {
                                    Text(Self.title(goal))
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .menuStyle(.button)
                    .buttonStyle(HUDButtonStyle())
                    .frame(width: Self.menuWidth)
                    .accessibilityLabel("Выбрать другую цель")
                }
            }
            .frame(width: Self.width)
            .tutorialAnchor(.mapGoals)
        }
    }

    /// Главная цель: текущая цель урока из кнопок целей, иначе активная из списка, иначе первая.
    static func mainGoal(_ goals: [ManeuverGoal], active: ManeuverGoal?, lessonTargets: [LessonElement]) -> ManeuverGoal? {
        for target in lessonTargets {
            if let goal = goals.first(where: { anchor($0) == target }) { return goal }
        }
        if let active, goals.contains(active) { return active }
        return goals.first
    }

    /// Ключ рамки кнопки цели для уроков.
    static func anchor(_ goal: ManeuverGoal) -> LessonElement? {
        switch goal {
        case .toLuna: .mapLuna
        case .circularize: .mapCircularize
        default: nil
        }
    }

    /// Подсказка по долгому нажатию на кнопку цели.
    static func hint(_ goal: ManeuverGoal) -> String {
        switch goal {
        case .toLuna: "К Луне — игра поставит узел перелёта к Луне"
        case .circularize: "Скруглить орбиту — узел, после которого орбита станет круговой"
        case .changeOrbit: "Изменить высоту — узел в перицентре: «+» поднимает дальнюю сторону орбиты, «−» опускает"
        case .returnHome: "Домой на Терру — узел возврата с орбиты Луны"
        case .toVella, .toArda, .toTaros:
            "К планете — игра выберет окно, поставит узел отлёта и сама поправит курс в пути"
        }
    }

    static func title(_ goal: ManeuverGoal) -> String {
        switch goal {
        case .toLuna: "К Луне"
        case .circularize: "Скруглить орбиту"
        case .changeOrbit: "Изменить высоту"
        case .returnHome: "Домой на Терру"
        case .toVella: "К Велле"
        case .toArda: "К Арде"
        case .toTaros: "К Таросу"
        }
    }

    static func icon(_ goal: ManeuverGoal) -> String {
        switch goal {
        case .toLuna: "moon.fill"
        case .circularize: "circle.dashed"
        case .changeOrbit: "arrow.up.and.down"
        case .returnHome: "house.fill"
        case .toVella, .toArda, .toTaros: "globe"
        }
    }
}

/// Фокус камеры карты: одна кнопка-меню «◎ Корабль ▾» и «?» снизу по центру, над навболом.
/// Пока ускорение ждёт окна к планете, над ними — отсчёт до окна.
struct MapFocusPicker: View {
    let model: FlightHUDModel
    /// Кнопка «?» открывает легенду карты.
    @Binding var showLegend: Bool

    var body: some View {
        let focus = model.map.focus
        VStack(spacing: 3) {
            if let wait = model.planetWaitText {
                Text(wait)
                    .font(.system(size: HUDFont.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(HUDPalette.green)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Menu {
                    if let bodyID = focus.bodyID {
                        Text(Self.info(bodyID))
                    }
                    ForEach(MapFocus.allCases, id: \.self) { item in
                        Button {
                            model.setMapFocus(item)
                        } label: {
                            if item == focus {
                                Label(Self.name(item), systemImage: "checkmark")
                            } else {
                                Text(Self.name(item))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "scope")
                            .font(.system(size: 13, weight: .semibold))
                        Text(Self.name(focus))
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                }
                .menuStyle(.button)
                .menuOrder(.fixed)
                .buttonStyle(HUDButtonStyle(isActive: false))
                .accessibilityLabel("Центр карты: \(Self.name(focus)), выбрать")
                .longPressHint("Центр карты: корабль, Терра, Луна, Система или планета — карта вращается вокруг него")
                Button {
                    showLegend.toggle()
                } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(HUDButtonStyle(isActive: showLegend))
                .tutorialAnchor(.mapLegend)
                .accessibilityLabel("Легенда карты и подсказки")
                .longPressHint("«?» — что значат цвета и значки на карте")
            }
        }
        .padding(4)
        .hudBackground()
        .fixedSize()
        .tutorialAnchor(.mapFocus)
    }

    /// «Велла · g 7.85 м/с² · средняя 12 °C · нет грунта».
    static func info(_ id: BodyID) -> String {
        let body = Bodies.body(id)
        return body.name + String(format: " · g %.2f м/с² · средняя %.0f °C", body.surfaceGravity, body.surfaceTemperature - 273.15)
            + (body.hasSolidSurface ? "" : " · нет грунта")
    }

    static func name(_ focus: MapFocus) -> String {
        switch focus {
        case .vessel: "Корабль"
        case .terra: "Терра"
        case .luna: "Луна"
        case .sol: "Система"
        case .vella: "Велла"
        case .arda: "Арда"
        case .taros: "Тарос"
        }
    }
}

extension ManeuverAxis {
    /// Название строки оси в панели «Эксперт».
    var rowTitle: String {
        switch self {
        case .prograde: "↑ Вперёд"
        case .normal: "↻ Вбок"
        case .radial: "⇡ От планеты"
        }
    }
}

// MARK: - Правая колонка

/// Правая колонка карты: карточка узла (по режиму) и «Выполнить манёвр».
/// Просто: итог цели и «Сила прожига». Эксперт: итог, Δv, оси и шаг.
struct MapSideColumn: View {
    let model: FlightHUDModel

    static let width: CGFloat = 190

    var body: some View {
        // Низкая карточка стоит над кнопкой без зазора; высокая прокручивается, кнопка остаётся на виду.
        ViewThatFits(in: .vertical) {
            VStack(spacing: 6) {
                content
                ManeuverExecuteButton(model: model)
            }
            VStack(spacing: 6) {
                ScrollView { content }
                    .scrollIndicators(.visible)
                ManeuverExecuteButton(model: model)
            }
        }
        .frame(width: Self.width)
    }

    private var content: some View {
        VStack(spacing: 6) {
            if model.deletedNode != nil, !model.hasManeuver {
                DeletedNodeBar(model: model)
            }
            if model.mapExpert { expert } else { simple }
        }
    }

    @ViewBuilder
    private var simple: some View {
        if model.hasManeuver {
            ManeuverResultCard(model: model)
        } else {
            MapHintCard(text: model.availableGoals.isEmpty
                        ? "Манёвры появятся на орбите"
                        : "Выберите цель слева: игра сама поставит узел")
        }
    }

    @ViewBuilder
    private var expert: some View {
        if model.hasManeuver {
            ManeuverPanel(model: model)
        } else {
            MapHintCard(text: "Тапните по орбите, чтобы поставить узел манёвра")
        }
    }
}

/// Полоса «Узел удалён · Вернуть узел» на 4 с после удаления узла.
struct DeletedNodeBar: View {
    let model: FlightHUDModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Узел удалён")
                .font(.system(size: HUDFont.caption, weight: .semibold))
                .foregroundStyle(HUDStyle.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                model.restoreDeletedNode()
            } label: {
                Text("Вернуть узел")
                    .font(.system(size: HUDFont.body, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Вернуть узел")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudBackground(corner: 10)
    }
}

/// Карточка-подсказка справа, когда узла нет.
struct MapHintCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(HUDStyle.secondaryText)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hudBackground(corner: 10)
            .allowsHitTesting(false)
    }
}

// MARK: - Простая карта: результат и выполнение

/// Тексты итога цели («Пе у Луны 32.0 км ✓»).
enum ManeuverResultText {
    static let check = " ✓"

    static func headline(_ outcome: ManeuverOutcome) -> String {
        let mark = outcome.isGood ? check : ""
        switch outcome.kind {
        case .lunaPeriapsis(let altitude):
            return "Пе у Луны " + HUDFormat.distance(altitude) + mark
        case .terraPeriapsis(let altitude):
            return "Возврат к Терре · Пе " + HUDFormat.distance(altitude) + mark
        case .orbit(_, let apoapsis, let periapsis):
            if apoapsis.isInfinite { return "Пролёт · Пе " + HUDFormat.distance(periapsis) + mark }
            return "Орбита " + kilometers(apoapsis) + " × " + kilometers(periapsis) + " км" + mark
        case .planetPeriapsis(let body, let altitude):
            return "Пе у " + MapText.genitive(body) + " " + HUDFormat.distance(altitude) + mark
        case .planetApproach(let body, let distance, let correction):
            return "Сближение с " + MapText.instrumental(body) + " " + HUDFormat.distance(distance)
                + " · коррекция ~" + HUDFormat.speed(correction) + mark
        case .noEncounter(let body):
            switch body {
            case .luna: return "Встречи с Луной нет"
            case .terra: return "Возврата к Терре нет"
            case .vella: return "Встречи с Веллой нет"
            case .arda: return "Встречи с Ардой нет"
            case .taros: return "Встречи с Таросом нет"
            case .sol: return "Встречи с Солом нет"
            }
        case .impact(let body):
            return "Падение на " + MapText.accusative(body)
        }
    }

    /// Подпись над крупным значением итога: «Пролёт над Луной».
    static func caption(_ outcome: ManeuverOutcome) -> String {
        switch outcome.kind {
        case .lunaPeriapsis: "Пролёт над Луной"
        case .terraPeriapsis: "Возврат к Терре, высота"
        case .orbit(_, let apoapsis, _): apoapsis.isInfinite ? "Пролёт" : "Орбита"
        case .planetPeriapsis(let body, _): "Пролёт над " + MapText.genitive(body)
        case .planetApproach(let body, _, _): "Сближение с " + MapText.instrumental(body)
        case .noEncounter, .impact: "Итог"
        }
    }

    /// Крупное значение итога: «30 км ✓», «80 × 74 км ✓». Галочка — только если цель достигнута.
    static func value(_ outcome: ManeuverOutcome) -> String {
        let mark = outcome.isGood ? check : ""
        switch outcome.kind {
        case .lunaPeriapsis(let altitude), .terraPeriapsis(let altitude):
            return HUDFormat.distance(altitude) + mark
        case .orbit(_, let apoapsis, let periapsis):
            if apoapsis.isInfinite { return "Пе " + HUDFormat.distance(periapsis) + mark }
            return kilometers(apoapsis) + " × " + kilometers(periapsis) + " км" + mark
        case .planetPeriapsis(_, let altitude):
            return HUDFormat.distance(altitude) + mark
        case .planetApproach(_, let distance, let correction):
            return HUDFormat.distance(distance) + " · коррекция ~" + HUDFormat.speed(correction) + mark
        case .noEncounter, .impact:
            return headline(outcome)
        }
    }

    /// Строка простой карточки без Δv: «прожиг через 57 с», «прожиг сейчас», «выполнен».
    static func simpleDetail(_ m: ManeuverStatus) -> String {
        let lead = m.burnTime.isFinite ? m.timeToBurn : m.timeToNode
        if m.isDone { return "выполнен" }
        if lead <= 0 { return "прожиг сейчас" }
        return "прожиг через " + HUDFormat.countdown(lead)
    }


    /// Высота в километрах без единиц: «80», «80.5».
    static func kilometers(_ meters: Double) -> String {
        let km = meters / 1_000
        return abs(km - km.rounded()) < 0.05 ? HUDFormat.grouped(km.rounded()) : HUDFormat.fixed(km, digits: 1)
    }

    /// Строка «Δv 857 м/с · через 31:41»; прожиг уже идёт — «прожиг сейчас».
    static func detail(_ m: ManeuverStatus) -> String {
        let lead = m.burnTime.isFinite ? m.timeToBurn : m.timeToNode
        let when: String
        if m.isDone {
            when = "выполнен"
        } else if lead <= 0 {
            when = "прожиг сейчас"
        } else {
            when = "через " + HUDFormat.countdown(lead)
        }
        return "Δv " + HUDFormat.speed(m.deltaV) + " · " + when
    }
}

/// Подпись и крупное значение итога цели; общая верхушка карточек «Просто» и «Эксперт».
struct ManeuverResultHeader: View {
    let model: FlightHUDModel

    var body: some View {
        let outcome = model.map.snapshot.maneuver.map {
            ManeuverPlanner.outcome(model.maneuverGoal, trajectory: $0.trajectory)
        }
        VStack(alignment: .leading, spacing: 1) {
            if let outcome {
                let caption = ManeuverResultText.caption(outcome)
                let value = ManeuverResultText.value(outcome)
                Text(caption)
                    .font(.system(size: HUDFont.caption, weight: .semibold))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(value)
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(outcome.isGood ? MapPalette.ready : HUDStyle.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(caption + ": " + value.replacingOccurrences(of: "✓", with: "цель достигнута"))
            } else {
                Text(HUDFormat.dash)
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(HUDStyle.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Карточка «Просто»: итог цели, время прожига, «Сила прожига» (−, ползунок, +).
struct ManeuverResultCard: View {
    let model: FlightHUDModel

    var body: some View {
        let busy = model.isAutoBurning
        VStack(alignment: .leading, spacing: 4) {
            ManeuverResultHeader(model: model)
            ManeuverResultDetail(model: model)
            if busy {
                Text("Идёт прожиг — сначала Стоп")
                    .font(.system(size: HUDFont.caption, weight: .semibold))
                    .foregroundStyle(HUDStyle.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text("Сила прожига")
                .font(.system(size: HUDFont.caption, weight: .semibold))
                .foregroundStyle(HUDStyle.secondaryText)
                .padding(.top, 2)
            HStack(spacing: 4) {
                NudgeButton(model: model, direction: -1)
                ManeuverJog(model: model)
                NudgeButton(model: model, direction: 1)
            }
            .disabled(busy)
            .opacity(busy ? 0.4 : 1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudBackground()
        .tutorialAnchor(.mapPanel)
        .tutorialAnchor(.mapSummary)
    }
}

/// «прожиг через 57 с» — единственная часть карточки «Просто», читающая кадр.
struct ManeuverResultDetail: View {
    let model: FlightHUDModel

    var body: some View {
        if let m = model.maneuver {
            Text(ManeuverResultText.simpleDetail(m))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(HUDStyle.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// «−» и «+»: тап — прогрейд ± шаг цели, удержание — повтор.
struct NudgeButton: View {
    let model: FlightHUDModel
    /// −1 или +1.
    let direction: Double

    @State private var repeatTask: Task<Void, Never>?
    @State private var pressed = false
    /// Палец на кнопке; сбрасывается и при отмене касания системой (там `onEnded` не приходит).
    @GestureState private var touching = false

    var body: some View {
        Text(direction < 0 ? HUDFormat.minus : "+")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
            .hudBackground(HUDStyle.control, corner: 10)
            .opacity(pressed ? 0.7 : 1)
            .scaleEffect(pressed ? 0.96 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { _ in begin() }
                    .onEnded { _ in end() }
            )
            .onChange(of: touching) { _, value in if !value { end() } }
            .onDisappear { end() }
            .accessibilityElement()
            .accessibilityLabel(direction < 0 ? "Меньше" : "Больше")
            .accessibilityHint("Шаг \(HUDFormat.fixed(ManeuverPlanner.fineStep(model.maneuverGoal), digits: 1)) м/с по ходу орбиты")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.nudgeManeuver(by: direction) }
    }

    private func begin() {
        guard repeatTask == nil else { return }
        pressed = true
        model.nudgeManeuver(by: direction)
        let model = model, direction = direction
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                model.nudgeManeuver(by: direction)
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func end() {
        repeatTask?.cancel()
        repeatTask = nil
        pressed = false
    }
}

/// Пружинящий ползунок-джог: рукоять тянется влево/вправо, отпустил — возвращается в центр.
/// Скорость изменения прогрейда — по отводу (`ManeuverDrag` с масштабом `fineStep`).
struct ManeuverJog: View {
    let model: FlightHUDModel

    @GestureState private var pull: CGFloat = 0
    @GestureState private var active = false

    private static let knob: CGFloat = 30
    /// Ход рукояти от центра, pt.
    private static let travel: CGFloat = 26

    var body: some View {
        let shown = min(max(pull, -Self.travel), Self.travel)
        ZStack {
            Capsule()
                .fill(Color.black.opacity(0.45))
                .frame(height: 30)
                .overlay(Capsule().strokeBorder(HUDStyle.stroke, lineWidth: 1))
            HStack {
                Image(systemName: "chevron.left").font(.system(size: HUDFont.caption, weight: .bold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: HUDFont.caption, weight: .bold))
            }
            .foregroundStyle(HUDStyle.secondaryText)
            .padding(.horizontal, 8)
            Circle()
                .fill(active ? HUDStyle.active : Color.white)
                .frame(width: Self.knob, height: Self.knob)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .offset(x: shown)
                .animation(active ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: shown)
        }
        .frame(maxWidth: .infinity, minHeight: HUDStyle.minTouch, maxHeight: HUDStyle.minTouch)
        .contentShape(Rectangle())
        .gesture(drag)
        .onChange(of: active) { _, value in
            // Касание отменено системой — onEnded может не прийти.
            if !value, model.maneuverDrag?.fromJog == true { model.maneuverDrag = nil }
        }
        .onDisappear {
            if model.maneuverDrag?.fromJog == true { model.maneuverDrag = nil }
        }
        .accessibilityElement()
        .accessibilityLabel("Подправить")
        .accessibilityHint("Тяните вправо — больше, влево — меньше; отпустите — остановится")
        .accessibilityAdjustableAction { direction in
            model.nudgeManeuver(by: direction == .increment ? 1 : -1)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($pull) { value, state, _ in state = value.translation.width }
            .updating($active) { _, state, _ in state = true }
            .onChanged { value in
                let offset = Double(min(max(value.translation.width, -Self.travel), Self.travel))
                if var current = model.maneuverDrag, current.fromJog {
                    current.offset = offset
                    model.maneuverDrag = current
                } else {
                    model.maneuverDrag = ManeuverDrag(handle: .prograde, offset: offset,
                                                      scale: ManeuverPlanner.fineStep(model.maneuverGoal), fromJog: true)
                }
            }
            .onEnded { _ in
                if model.maneuverDrag?.fromJog == true { model.maneuverDrag = nil }
            }
    }
}

/// Большая зелёная «▶ Выполнить манёвр»; во время автопрожига — «■ Стоп» с фазой. Узел выполнен — «удалить».
struct ManeuverExecuteButton: View {
    let model: FlightHUDModel

    private static let green = Color(red: 0.2, green: 0.72, blue: 0.34)
    private static let red = Color(red: 0.85, green: 0.28, blue: 0.25)

    var body: some View {
        if let phase = model.autoBurnText {
            Button {
                model.stopManeuver()
            } label: {
                VStack(spacing: 1) {
                    Text("■ Стоп")
                        .font(.system(size: 16, weight: .heavy))
                    Text(phase)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Self.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(HUDPressStyle())
            .tutorialAnchor(.mapExecute)
            .accessibilityLabel("Стоп автопрожига")
            .longPressHint("Стоп — отменить автопрожиг")
            .accessibilityValue(phase)
        } else if model.maneuverNode != nil {
            if model.maneuver?.isDone == true {
                Button {
                    model.deleteManeuver()
                } label: {
                    Text("✓ Выполнено · удалить узел")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(MapPalette.ready)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .hudBackground(corner: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HUDPressStyle())
                .tutorialAnchor(.mapExecute)
                .accessibilityLabel("Узел выполнен, удалить")
                .longPressHint("Узел выполнен — нажмите, чтобы убрать его с карты")
            } else {
                Button {
                    model.executeManeuver()
                } label: {
                    Text("▶ Выполнить манёвр")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Self.green, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(HUDPressStyle())
                .tutorialAnchor(.mapExecute)
                .accessibilityLabel("Выполнить манёвр")
                .accessibilityHint("Корабль сам долетит до узла, развернётся и сделает прожиг")
                .longPressHint("Выполнить манёвр — корабль сам долетит до узла, развернётся и сделает прожиг")
            }
        }
    }
}

/// Панель узла «Эксперт»: итог цели, Δv и время (каждый кадр — только `ManeuverReadout`), оси Δv,
/// шаг подстройки, «К узлу» и «Удалить».
struct ManeuverPanel: View {
    let model: FlightHUDModel

    @State private var axis: ManeuverAxis = .prograde
    /// Выбранный шаг подстройки, м/с.
    @State private var step: Double = 1

    /// Шаги подстройки, м/с: тонко 0.1, 1 и грубо 10 (кнопки «−» и «+» берут выбранный).
    private static let stepChoices: [Double] = [0.1, 1, 10]

    var body: some View {
        let node = model.maneuverNode
        let busy = model.isAutoBurning
        VStack(spacing: 4) {
            // «К узлу» и «Удалить» — значками справа от итога: отдельный ряд не помещался по высоте экрана.
            HStack(alignment: .top, spacing: 2) {
                ManeuverResultHeader(model: model)
                iconButton("forward.end.fill", label: "Ускорить время до узла", hint: "К узлу — время ускорится и остановится перед прожигом") {
                    model.warpToManeuver()
                }
                .disabled(!model.canWarpToManeuver)
                .opacity(model.canWarpToManeuver ? 1 : 0.4)
                .tutorialAnchor(.mapToNode)
                iconButton("trash", label: "Удалить узел", hint: "Удалить узел манёвра") {
                    model.deleteManeuver()
                }
            }
            ManeuverReadout(model: model)

            if busy {
                Text("Идёт прожиг — сначала Стоп")
                    .font(.system(size: HUDFont.caption, weight: .semibold))
                    .foregroundStyle(HUDStyle.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 3) {
                ForEach(ManeuverAxis.allCases, id: \.self) { item in
                    axisRow(item, value: node.map { item.value($0) } ?? 0)
                }
            }
            .disabled(busy)
            .opacity(busy ? 0.4 : 1)

            HStack(spacing: 4) {
                ExpertStepButton(model: model, axis: axis, step: step, direction: -1)
                Menu {
                    ForEach(Self.stepChoices, id: \.self) { choice in
                        Button(Self.stepText(choice)) { step = choice }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(Self.stepText(step))
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 2)
                }
                .menuStyle(.button)
                .buttonStyle(HUDButtonStyle())
                .frame(width: 78)
                .accessibilityLabel("Шаг \(Self.stepText(step)), выбрать")
                ExpertStepButton(model: model, axis: axis, step: step, direction: 1)
            }
            .disabled(busy)
            .opacity(busy ? 0.4 : 1)
        }
        .padding(6)
        .hudBackground()
        .tutorialAnchor(.mapPanel)
        .tutorialAnchor(.mapSummary)
    }

    /// Значок 44 × 44 в строке итога.
    private func iconButton(_ systemImage: String, label: String, hint: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(HUDStyle.secondaryText)
        .accessibilityLabel(label)
        .longPressHint(hint)
    }

    /// Строка оси: «↑ Вперёд — 857 м/с»; тап выбирает ось для «−» и «+».
    private func axisRow(_ item: ManeuverAxis, value: Double) -> some View {
        let selected = axis == item
        return Button {
            axis = item
        } label: {
            HStack(spacing: 4) {
                Text(item.rowTitle)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(abs(value) < 0.05 ? "0" : HUDFormat.signedSpeed(value))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .hudBackground(selected ? HUDStyle.accent : HUDStyle.control, corner: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HUDPressStyle())
        .accessibilityLabel("Компонента \(item.fullName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func stepText(_ step: Double) -> String {
        HUDFormat.fixed(step, digits: step < 1 ? 1 : 0) + " м/с"
    }


    /// Период текущей орбиты (первый участок прогноза), nil — орбита незамкнутая.
    static func period(_ snapshot: MapSnapshot) -> Double? {
        guard let p = snapshot.trajectory?.patches.first?.elements.period, p.isFinite, p > 0 else { return nil }
        return p
    }

    static func signed(_ value: Double) -> String {
        (value < 0 ? HUDFormat.minus : "+") + HUDFormat.grouped(abs(value))
    }
}

/// «−» и «+» панели «Эксперт» (≈ 88 × 48): тап — компонента ± выбранный шаг, удержание — повтор.
struct ExpertStepButton: View {
    let model: FlightHUDModel
    let axis: ManeuverAxis
    /// Шаг, м/с (больше нуля).
    let step: Double
    /// −1 или +1.
    let direction: Double

    @State private var repeatTask: Task<Void, Never>?
    @State private var pressed = false
    /// Палец на кнопке; сбрасывается и при отмене касания системой (там `onEnded` не приходит).
    @GestureState private var touching = false

    var body: some View {
        Text(direction < 0 ? HUDFormat.minus : "+")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
            .hudBackground(HUDStyle.control, corner: 10)
            .opacity(pressed ? 0.7 : 1)
            .scaleEffect(pressed ? 0.96 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { _ in begin() }
                    .onEnded { _ in end() }
            )
            .onChange(of: touching) { _, value in if !value { end() } }
            .onDisappear { end() }
            .accessibilityElement()
            .accessibilityLabel((direction < 0 ? "Минус " : "Плюс ") + HUDFormat.fixed(step, digits: step < 1 ? 1 : 0) + " м/с " + axis.fullName)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.adjustManeuver(axis, by: direction * step) }
    }

    private func begin() {
        guard repeatTask == nil else { return }
        pressed = true
        let model = model, axis = axis, delta = direction * step
        model.adjustManeuver(axis, by: delta)
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                model.adjustManeuver(axis, by: delta)
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func end() {
        repeatTask?.cancel()
        repeatTask = nil
        pressed = false
    }
}

/// Числа узла — единственная часть панели, читающая кадр: «Δv 857 м/с · прожиг 38 с», «узел через 30:24».
struct ManeuverReadout: View {
    let model: FlightHUDModel

    var body: some View {
        if let m = model.maneuver {
            // Прожиг уже идёт — вместо полного Δv остаток.
            let burning = !m.isDone && m.timeToBurn <= 0 && m.remainingDeltaV < m.deltaV - 0.5
            VStack(alignment: .leading, spacing: 2) {
                Text((burning ? "ост " + HUDFormat.speed(m.remainingDeltaV) : "Δv " + HUDFormat.speed(m.deltaV))
                     + " · прожиг " + HUDFormat.countdown(m.burnTime))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if m.isDone || m.timeToNode < -max(m.burnTime.isFinite ? m.burnTime : 0, 1) {
                    Button {
                        model.deleteManeuver()
                    } label: {
                        Text("Узел выполнен — удалить")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(MapPalette.ready)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.plain)
                } else if m.timeToBurn <= 0 {
                    Text("Начало прожига — сейчас")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(HUDStyle.accent)
                        .lineLimit(1)
                } else {
                    Text(m.timeToNode < 0 ? "узел позади" : "узел через " + HUDFormat.countdown(m.timeToNode))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(HUDStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Плашка узла вне карты (слева от навбола): остаток Δv и начало прожига. Тап — карта.
struct ManeuverBadge: View {
    let status: ManeuverStatus
    /// Фаза автопрожига («Прожиг · ост 312 м/с»); nil — автопрожиг не идёт.
    var autoText: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    SASIcon(mode: .maneuver)
                        .foregroundStyle(NavballPalette.maneuver)
                        .frame(width: 14, height: 14)
                    Text("Узел · Δv \(HUDFormat.speed(status.remainingDeltaV))")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                Text(autoText ?? Self.subtitle(status))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(autoText != nil ? HUDStyle.accent : (status.isDone ? MapPalette.ready : HUDStyle.secondaryText))
            }
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minHeight: HUDStyle.minTouch)
            .hudBackground(corner: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открыть карту")
    }

    static func subtitle(_ m: ManeuverStatus) -> String {
        if m.isDone { return "выполнен — удалите на карте" }
        if m.timeToBurn <= 0 { return "прожиг — сейчас" }
        return "начало через \(HUDFormat.countdown(m.timeToBurn))"
    }
}
