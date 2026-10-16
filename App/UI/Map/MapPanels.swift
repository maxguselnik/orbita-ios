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

/// SAS на карте: вкл/выкл и «по узлу».
struct MapSASRow: View {
    let model: FlightHUDModel

    var body: some View {
        let current = model.sas
        let enabled = model.hasManeuver || current == .maneuver
        HStack(spacing: 4) {
            SASToggleButton(model: model, stacked: true)
            Button {
                model.send(.setSAS(current == .maneuver ? .hold : .maneuver))
            } label: {
                VStack(spacing: 1) {
                    SASIcon(mode: .maneuver)
                        .frame(width: 18, height: 18)
                    Text("УЗЕЛ").font(.system(size: HUDFont.caption, weight: .bold))
                }
                .frame(maxWidth: .infinity, minHeight: HUDStyle.minTouch)
            }
            .buttonStyle(HUDButtonStyle(isActive: current == .maneuver))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .tutorialAnchor(.mapSASNode)
            .accessibilityLabel("SAS по узлу манёвра")
            .longPressHint("УЗЕЛ — нос корабля смотрит туда, куда нужно жечь")
        }
    }
}

// MARK: - Центр

/// Середина экрана на карте: сводка сверху слева, остальное — свободно для жестов и ручек.
struct MapCenterColumn: View {
    let model: FlightHUDModel
    var hintsEnabled = true

    var body: some View {
        // Сводка и подсказка делят одну область над контролами. Длинный текст прокручивается,
        // поэтому в «Эксперт» он не перекрывает ни сводку, ни фокус карты и навбол.
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                MapInfoPanel(snapshot: model.map.snapshot)
                    .tutorialAnchor(.mapSummary)
                if model.mapExpert, !model.isPaused {
                    MapHintHost(model: model, hintsEnabled: hintsEnabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, max(0, NavballCluster.height + NavballCluster.lift - 54))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Цели («Куда летим?»)

/// Колонка целей простой карты: по одной кнопке на цель из `availableGoals`; активная подсвечена.
/// Нет целей — колонки нет.
struct MapGoalsColumn: View {
    let model: FlightHUDModel

    var body: some View {
        let goals = model.availableGoals
        if !goals.isEmpty {
            let active = model.maneuverGoal
            let planets = goals.filter { $0.planet != nil }
            VStack(alignment: .leading, spacing: 4) {
                Text("КУДА ЛЕТИМ?")
                    .font(.system(size: HUDFont.caption, weight: .heavy))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .padding(.leading, 2)
                ForEach(goals.filter { $0.planet == nil }, id: \.self) { goal in
                    Button {
                        model.planManeuver(goal)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Self.icon(goal))
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 18)
                            Text(Self.title(goal))
                                .font(.system(size: 13, weight: .bold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(HUDButtonStyle(isActive: goal == active))
                    .tutorialAnchor(optional: Self.anchor(goal))
                    .accessibilityLabel(Self.title(goal))
                    .accessibilityHint("Игра сама поставит узел манёвра")
                    .longPressHint(Self.hint(goal))
                    .accessibilityAddTraits(goal == active ? .isSelected : [])
                }
                if !planets.isEmpty {
                    PlanetGoalsMenu(model: model, goals: planets, active: active)
                }
            }
            .tutorialAnchor(.mapGoals)
        }
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

/// Кнопка «К планете»: меню планет с временем до окна отлёта (с орбиты Терры) — два нажатия до узла.
struct PlanetGoalsMenu: View {
    let model: FlightHUDModel
    let goals: [ManeuverGoal]
    let active: ManeuverGoal?

    var body: some View {
        let current = goals.first { $0 == active }
        Menu {
            ForEach(goals, id: \.self) { goal in
                Button {
                    model.planManeuver(goal)
                } label: {
                    if let window = model.planetWindowText(goal) {
                        Text(MapGoalsColumn.title(goal) + " · " + window)
                    } else {
                        Text(MapGoalsColumn.title(goal))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(current.map(MapGoalsColumn.title) ?? "К планете")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(HUDButtonStyle(isActive: current != nil))
        .accessibilityLabel("К планете")
        .accessibilityHint(MapGoalsColumn.hint(.toArda))
        .accessibilityAddTraits(current != nil ? .isSelected : [])
    }
}

/// Строка сводки карты.
struct MapInfoLine: Identifiable {
    let id: String
    let text: String
    let color: Color
}

/// Сводка: фаза Луны против гомановской, встреча, возврат, падение. Обновляется со снимком карты (≤ 4 Гц).
struct MapInfoPanel: View {
    let snapshot: MapSnapshot

    /// Разница фаз, при которой пора начинать перелёт, рад.
    static let phaseTolerance = 3 * Double.pi / 180

    var body: some View {
        let phase = Self.phaseLine(snapshot)
        let path = Self.pathLines(snapshot)
        if phase != nil || !path.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let phase {
                    line(phase)
                }
                if snapshot.maneuver != nil, !path.isEmpty {
                    Text("ПОСЛЕ УЗЛА")
                        .font(.system(size: HUDFont.caption, weight: .heavy))
                        .foregroundStyle(MapPalette.afterManeuver)
                }
                ForEach(path) { item in
                    line(item)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .hudBackground(corner: 10)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }

    private func line(_ item: MapInfoLine) -> some View {
        Text(item.text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(item.color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// Фаза Луны относительно корабля и нужная для гомановского перелёта; «пора» — разница < 3°.
    static func phaseLine(_ s: MapSnapshot) -> MapInfoLine? {
        guard let phase = s.lunaPhase, let target = s.hohmannPhase else { return nil }
        let diff = remainder(phase - target, 2 * Double.pi)
        let ready = abs(diff) < phaseTolerance
        var text = "Фаза Луны \(MapText.degrees(phase)) · нужна \(MapText.degrees(target))"
        if ready {
            text += " · пора"
        } else if let wait = waitTime(s, diff: diff) {
            text += " · " + waitText(wait)
        }
        return MapInfoLine(id: "phase", text: text, color: ready ? MapPalette.ready : Color.white)
    }

    /// Время до нужной фазы, с: разница фаз / (угловая скорость корабля − угловая скорость Луны).
    static func waitTime(_ s: MapSnapshot, diff: Double) -> Double? {
        guard let period = ManeuverPanel.period(s) else { return nil }
        let relative = 2 * Double.pi / period - World.lunaAngularRate
        guard relative > 1e-9 else { return nil }
        let ahead = diff < 0 ? diff + 2 * Double.pi : diff
        let wait = ahead / relative
        return wait.isFinite ? wait : nil
    }

    /// «через ~7 мин», «через ~3 ч».
    static func waitText(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes >= 120 ? "через ~\(minutes / 60) ч" : "через ~\(minutes) мин"
    }

    /// Встреча, возврат, падение — по траектории после узла, без узла — по текущей.
    static func pathLines(_ s: MapSnapshot) -> [MapInfoLine] {
        var out: [MapInfoLine] = []
        guard let trajectory = s.maneuver?.trajectory ?? s.trajectory else { return out }
        if let e = trajectory.encounter {
            out.append(MapInfoLine(
                id: "encounter",
                text: "Встреча с \(MapText.instrumental(e.body)) · \(MapText.periapsis(e.periapsisAltitude)) · через \(HUDFormat.countdown(e.time - s.time))",
                color: MapPalette.encounter))
        }
        if let r = trajectory.returnToTerra {
            out.append(MapInfoLine(
                id: "return",
                text: "Возврат к Терре · \(MapText.periapsis(r.periapsisAltitude))",
                color: MapPalette.returnTrip))
        }
        if let i = trajectory.impact {
            out.append(MapInfoLine(
                id: "impact",
                text: "Падение на \(MapText.accusative(i.body)) · через \(HUDFormat.countdown(i.time - s.time))",
                color: MapPalette.impact))
        }
        return out
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

// MARK: - Правая колонка

/// Правая колонка карты. Просто: карточка «Результат», «Выполнить манёвр» и компактная «Ступень».
/// «Эксперт»: панель узла (или подсказка) и «Ступень».
struct MapSideColumn: View {
    let model: FlightHUDModel

    static let width: CGFloat = 196
    /// Зазор между «Выполнить» и «Ступень», pt.
    static let stageGap: CGFloat = 16

    var body: some View {
        VStack(spacing: 6) {
            ScrollView {
                VStack(spacing: 6) {
                    if model.deletedNode != nil, !model.hasManeuver {
                        DeletedNodeBar(model: model)
                    }
                    if model.mapExpert { expert } else { simple }
                }
            }
            .scrollIndicators(.visible)
            if !model.mapExpert || model.isAutoBurning {
                ManeuverExecuteButton(model: model)
            }
            StageButton(model: model, compact: true)
                .padding(.top, MapSideColumn.stageGap - 6)
        }
        .frame(width: Self.width)
    }

    @ViewBuilder
    private var simple: some View {
        if model.hasManeuver {
            ManeuverResultCard(model: model)
        } else {
            let text = model.availableGoals.isEmpty
                ? "Манёвры появятся на орбите"
                : "Выберите цель слева: игра сама поставит узел"
            MapHintCard(text: text) {
                model.setMapExpert(true)
            } label: {
                "Эксперт"
            }
        }
    }

    @ViewBuilder
    private var expert: some View {
        if model.hasManeuver {
            ManeuverPanel(model: model)
        } else {
            MapHintCard(text: "Тапните по орбите, чтобы поставить узел манёвра") {
                model.setMapExpert(false)
            } label: {
                "Просто"
            }
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

/// Карточка-подсказка справа с кнопкой переключения режима.
struct MapHintCard: View {
    let text: String
    let action: () -> Void
    let label: () -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HUDStyle.secondaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
            Button(action: action) {
                Text(label())
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 10)
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel(label() == "Эксперт" ? "Режим «Эксперт»" : "Простой режим")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudBackground(corner: 10)
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

/// Карточка «Результат»: итог цели, Δv и время, «Подправить» (−, ползунок, +), «Эксперт».
struct ManeuverResultCard: View {
    let model: FlightHUDModel

    var body: some View {
        let outcome = model.map.snapshot.maneuver.map {
            ManeuverPlanner.outcome(model.maneuverGoal, trajectory: $0.trajectory)
        }
        let busy = model.isAutoBurning
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("ИТОГ")
                    .font(.system(size: HUDFont.caption, weight: .heavy))
                    .foregroundStyle(HUDStyle.secondaryText)
                Spacer(minLength: 0)
                Button {
                    model.deleteManeuver()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HUDStyle.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(minHeight: HUDStyle.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HUDPressStyle())
                .padding(.vertical, -14)
                // Зазор до «Эксперт» ≥ 16 pt (4 между кнопками + 12 здесь).
                .padding(.trailing, 12)
                .accessibilityLabel("Удалить узел")
                .longPressHint("Удалить узел манёвра")
                Button {
                    model.setMapExpert(true)
                } label: {
                    Text("Эксперт")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(HUDStyle.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(minHeight: HUDStyle.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HUDPressStyle())
                // Высота строки — по заголовку, касание — полные 44 pt.
                .padding(.vertical, -14)
                .accessibilityLabel("Режим «Эксперт»")
                .longPressHint("Эксперт — ручки Δv, оси и время узла вручную")
            }
            if let outcome {
                Text(ManeuverResultText.headline(outcome))
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(outcome.isGood ? MapPalette.ready : HUDStyle.accent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(ManeuverResultText.headline(outcome).replacingOccurrences(of: "✓", with: "цель достигнута"))
            } else {
                Text(HUDFormat.dash)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(HUDStyle.secondaryText)
            }
            ManeuverResultDetail(model: model)
            if busy {
                Text("Идёт прожиг — сначала Стоп")
                    .font(.system(size: HUDFont.caption, weight: .semibold))
                    .foregroundStyle(HUDStyle.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text("ПОДПРАВИТЬ")
                .font(.system(size: HUDFont.caption, weight: .heavy))
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
    }
}

/// «Δv 857 м/с · через 31:41» — единственная часть карточки, читающая кадр.
struct ManeuverResultDetail: View {
    let model: FlightHUDModel

    var body: some View {
        if let m = model.maneuver {
            Text(ManeuverResultText.detail(m))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
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

/// Панель узла: сводка (каждый кадр — только `ManeuverReadout`), компоненты Δv, точные шаги,
/// сдвиг по времени, «К узлу», удаление.
struct ManeuverPanel: View {
    let model: FlightHUDModel

    @State private var axis: ManeuverAxis = .prograde
    /// Выбранный шаг подстройки, м/с.
    @State private var step: Double = 1

    /// Шаги подстройки, м/с: тонко 0.1, 1 и грубо 10 (кнопки «−» и «+» берут выбранный).
    private static let stepChoices: [Double] = [0.1, 1, 10]

    var body: some View {
        let node = model.maneuverNode
        let period = Self.period(model.map.snapshot)
        let busy = model.isAutoBurning
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    model.setMapExpert(false)
                } label: {
                    Text("Просто")
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(HUDButtonStyle())
                .accessibilityLabel("Простой режим")
                Spacer(minLength: 0)
                Button {
                    model.warpToManeuver()
                } label: {
                    Text("К узлу")
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(HUDButtonStyle())
                .disabled(!model.canWarpToManeuver)
                .opacity(model.canWarpToManeuver ? 1 : 0.4)
                .tutorialAnchor(.mapToNode)
                .accessibilityLabel("Ускорить время до узла")
                Button {
                    model.deleteManeuver()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(HUDButtonStyle())
                // Зазор до «К узлу» ≥ 16 pt (4 между кнопками + 12 здесь).
                .padding(.leading, 12)
                .accessibilityLabel("Удалить узел")
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

            HStack(spacing: 4) {
                ForEach(ManeuverAxis.allCases, id: \.self) { item in
                    Button {
                        axis = item
                    } label: {
                        VStack(spacing: 0) {
                            Text(item.shortName)
                                .font(.system(size: HUDFont.caption, weight: .heavy))
                            Text(HUDFormat.fixed(node.map { item.value($0) } ?? 0, digits: 1))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HUDButtonStyle(isActive: axis == item))
                    .accessibilityLabel("Компонента \(item.fullName)")
                }
            }
            .disabled(busy)
            .opacity(busy ? 0.4 : 1)

            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Self.stepChoices, id: \.self) { choice in
                        Button {
                            step = choice
                        } label: {
                            Text(HUDFormat.fixed(choice, digits: choice < 1 ? 1 : 0))
                                .font(.system(size: HUDFont.body, weight: .bold).monospacedDigit())
                                .foregroundStyle(step == choice ? Color.black : Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(step == choice ? MapPalette.ready : HUDStyle.control, in: Capsule())
                                .frame(height: HUDStyle.minTouch)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HUDPressStyle())
                        // Видимая капсула 28 pt, касание — полные 44.
                        .padding(.vertical, -8)
                        .accessibilityLabel("Шаг \(HUDFormat.fixed(choice, digits: choice < 1 ? 1 : 0)) м/с")
                        .accessibilityAddTraits(step == choice ? .isSelected : [])
                    }
                }
                HStack(spacing: 8) {
                    ExpertStepButton(model: model, axis: axis, step: step, direction: -1)
                    ExpertStepButton(model: model, axis: axis, step: step, direction: 1)
                }
            }
            .disabled(busy)
            .opacity(busy ? 0.4 : 1)

            HStack(spacing: 4) {
                timeButton(period.map { -$0 }, text: HUDFormat.minus + "об", label: "На оборот раньше")
                timeButton(-60, text: HUDFormat.minus + "1м", label: "На минуту раньше")
                timeButton(60, text: "+1м", label: "На минуту позже")
                timeButton(period, text: "+об", label: "На оборот позже")
            }
            .disabled(busy)
            .opacity(busy ? 0.4 : 1)
        }
        .padding(5)
        .hudBackground()
        .tutorialAnchor(.mapPanel)
    }

    private func timeButton(_ seconds: Double?, text: String, label: String) -> some View {
        Button {
            if let seconds { model.shiftManeuver(by: seconds) }
        } label: {
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(HUDButtonStyle())
        .disabled(seconds == nil)
        .opacity(seconds == nil ? 0.45 : 1)
        .accessibilityLabel(label)
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

/// Числа узла — единственная часть панели, читающая кадр.
struct ManeuverReadout: View {
    let model: FlightHUDModel

    var body: some View {
        if let m = model.maneuver {
            VStack(alignment: .leading, spacing: 2) {
                Self.row("Δv", HUDFormat.speed(m.deltaV), "ост", HUDFormat.speed(m.remainingDeltaV))
                Self.row("до узла", m.timeToNode < 0 ? "позади" : HUDFormat.countdown(m.timeToNode),
                         "прожиг", HUDFormat.countdown(m.burnTime))
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
                    Self.row("начало через", HUDFormat.countdown(m.timeToBurn), nil, nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func row(_ label1: String, _ value1: String, _ label2: String?, _ value2: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label1)
                .font(.system(size: HUDFont.caption, weight: .bold))
                .foregroundStyle(HUDStyle.secondaryText)
            Text(value1)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            if let label2, let value2 {
                Spacer(minLength: 2)
                Text(label2)
                    .font(.system(size: HUDFont.caption, weight: .bold))
                    .foregroundStyle(HUDStyle.secondaryText)
                Text(value2)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .lineLimit(1)
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
