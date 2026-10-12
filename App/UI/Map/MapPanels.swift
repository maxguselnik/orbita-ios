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
        }
    }

    /// «Луной», «Террой».
    static func instrumental(_ body: BodyID) -> String {
        switch body {
        case .terra: "Террой"
        case .luna: "Луной"
        }
    }

    /// «Луну», «Терру».
    static func accusative(_ body: BodyID) -> String {
        switch body {
        case .terra: "Терру"
        case .luna: "Луну"
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

/// Кнопка «Карта» ↔ «Полёт».
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
        .accessibilityLabel(open ? "Закрыть карту" : "Открыть карту")
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
                    Text("УЗЕЛ").font(.system(size: 8, weight: .bold))
                }
                .frame(maxWidth: .infinity, minHeight: HUDStyle.minTouch)
            }
            .buttonStyle(HUDButtonStyle(isActive: current == .maneuver))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityLabel("SAS по узлу манёвра")
        }
    }
}

// MARK: - Центр

/// Середина экрана на карте: сводка сверху слева, остальное — свободно для жестов и ручек.
struct MapCenterColumn: View {
    let model: FlightHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MapInfoPanel(snapshot: model.map.snapshot)
            if model.map.snapshot.lunaPhase != nil, !model.hasManeuver {
                lunaButton
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// «К Луне»: узел гомановского перелёта сам (ближайшая точка орбиты с нужной фазой).
    private var lunaButton: some View {
        Button {
            model.send(.setManeuver(DemoScenario.lunaTransferNode(model.snapshot)))
        } label: {
            Label("К Луне", systemImage: "moon.fill")
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .padding(.horizontal, 10)
        }
        .buttonStyle(HUDButtonStyle())
        .accessibilityLabel("Поставить узел перелёта к Луне")
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
                        .font(.system(size: 9, weight: .heavy))
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

/// Фокус камеры карты: корабль, Терра, Луна. Снизу по центру, на месте навбола.
struct MapFocusPicker: View {
    let model: FlightHUDModel
    /// Кнопка «?» открывает легенду карты.
    @Binding var showLegend: Bool

    var body: some View {
        let focus = model.map.focus
        HStack(spacing: 4) {
            ForEach(MapFocus.allCases, id: \.self) { item in
                Button {
                    model.setMapFocus(item)
                } label: {
                    Text(Self.name(item))
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(HUDButtonStyle(isActive: focus == item))
                .accessibilityLabel("Центр карты: \(Self.name(item))")
            }
            Button {
                showLegend.toggle()
            } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(HUDButtonStyle(isActive: showLegend))
            .accessibilityLabel("Легенда карты и подсказки")
        }
        .padding(4)
        .hudBackground()
    }

    static func name(_ focus: MapFocus) -> String {
        switch focus {
        case .vessel: "Корабль"
        case .terra: "Терра"
        case .luna: "Луна"
        }
    }
}

// MARK: - Правая колонка

/// Правая колонка карты: панель узла (или подсказка) и низкая «Ступень».
struct MapSideColumn: View {
    let model: FlightHUDModel

    var body: some View {
        VStack(spacing: 6) {
            if model.hasManeuver {
                ManeuverPanel(model: model)
            } else {
                Text("Тапните по орбите, чтобы поставить узел манёвра")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudBackground(corner: 10)
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            StageButton(model: model, compact: true)
        }
        .frame(width: ControlsColumn.width)
    }
}

/// Панель узла: сводка (каждый кадр — только `ManeuverReadout`), компоненты Δv, точные шаги,
/// сдвиг по времени, «К узлу», удаление.
struct ManeuverPanel: View {
    let model: FlightHUDModel

    @State private var axis: ManeuverAxis = .prograde

    private static let steps: [Double] = [-10, -1, 1, 10]

    var body: some View {
        let node = model.maneuverNode
        let period = Self.period(model.map.snapshot)
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                SASIcon(mode: .maneuver)
                    .foregroundStyle(NavballPalette.maneuver)
                    .frame(width: 22, height: 22)
                    .accessibilityLabel("Узел манёвра")
                Spacer(minLength: 0)
                Button {
                    model.warpToManeuver()
                } label: {
                    Label("К узлу", systemImage: "forward.end.fill")
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(HUDButtonStyle())
                .disabled(!model.canWarpToManeuver)
                .opacity(model.canWarpToManeuver ? 1 : 0.4)
                .accessibilityLabel("Ускорить время до узла")
                Button {
                    model.deleteManeuver()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(HUDButtonStyle())
                .accessibilityLabel("Удалить узел")
            }

            ManeuverReadout(model: model)

            HStack(spacing: 4) {
                ForEach(ManeuverAxis.allCases, id: \.self) { item in
                    Button {
                        axis = item
                    } label: {
                        VStack(spacing: 0) {
                            Text(item.shortName)
                                .font(.system(size: 9, weight: .heavy))
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

            HStack(spacing: 4) {
                ForEach(Self.steps, id: \.self) { step in
                    Button {
                        model.adjustManeuver(axis, by: step)
                    } label: {
                        Text(Self.signed(step))
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HUDButtonStyle())
                    .accessibilityLabel("\(Self.signed(step)) м/с \(axis.fullName)")
                }
            }

            HStack(spacing: 4) {
                timeButton(period.map { -$0 }, text: HUDFormat.minus + "об", label: "На оборот раньше")
                timeButton(-60, text: HUDFormat.minus + "1м", label: "На минуту раньше")
                timeButton(60, text: "+1м", label: "На минуту позже")
                timeButton(period, text: "+об", label: "На оборот позже")
            }
        }
        .padding(5)
        .hudBackground()
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
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(HUDStyle.secondaryText)
            Text(value1)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            if let label2, let value2 {
                Spacer(minLength: 2)
                Text(label2)
                    .font(.system(size: 10, weight: .bold))
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
                Text(Self.subtitle(status))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(status.isDone ? MapPalette.ready : HUDStyle.secondaryText)
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
