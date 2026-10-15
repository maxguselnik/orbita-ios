import OrbitPhysics
import SwiftUI

/// Состояние шага миссии «Выход на орбиту».
enum MissionStepState: Equatable {
    case done, current, pending
}

struct MissionStep: Equatable, Identifiable {
    let id: Int
    let title: String
    let state: MissionStepState
}

/// Чек-лист миссии «Орбита 80 км» (Терра, старт с площадки). Чистая логика по телеметрии; пороги — из `AscentGuide`.
enum MissionChecklist {
    static let titles = ["Пуск", "Вертикально до 1 км", "Разворот на восток",
                         "Ап 80 км, тяга 0", "Скругление у Ап"]
    static let goalTitle = "Цель: орбита 80 км"
    static let doneTitle = "Вы на орбите"

    /// Сколько шагов выполнено подряд с начала (0…5) по текущей телеметрии, без памяти.
    static func completed(_ t: FlightTelemetry) -> Int {
        guard t.body == .terra else { return 0 }
        let flags: [Bool] = [
            t.situation != .prelaunch || t.mission.launched || t.thrust > 0,
            t.mission.launched && t.heightAboveTerrain > AscentGuide.verticalLimit,
            (t.orbit?.apoapsisAltitude ?? 0) >= AscentGuide.cutoffApoapsis,
            t.altitude > AscentGuide.spaceAltitude,
            (t.orbit?.periapsisAltitude ?? -.infinity) > AscentGuide.spaceAltitude,
        ]
        return flags.prefix { $0 }.count
    }

    /// Шаги для показа. `reached` — наибольший достигнутый прогресс за полёт (прогресс не откатывается).
    static func steps(_ t: FlightTelemetry, reached: Int = 0) -> [MissionStep] {
        let done = min(max(completed(t), reached), titles.count)
        return titles.enumerated().map { index, title in
            MissionStep(id: index, title: title,
                        state: index < done ? .done : (index == done ? .current : .pending))
        }
    }

    /// Одна строка свёрнутой карточки: «3/5 · Разворот на восток» или «Вы на орбите».
    static func summary(done: Int) -> String {
        done >= titles.count ? doneTitle : "\(done + 1)/\(titles.count) · \(titles[done])"
    }
}

/// Режим высотомера: над рельефом у поверхности (с гистерезисом против дребезга), иначе над средним уровнем тела.
enum AltimeterMode {
    static let enter = 1_000.0
    static let leave = 1_500.0

    static func overTerrain(previous: Bool, _ t: FlightTelemetry) -> Bool {
        switch t.situation {
        case .prelaunch, .landed, .splashed: return true
        default:
            let h = t.heightAboveTerrain
            guard h.isFinite else { return false }
            return h < (previous ? leave : enter)
        }
    }

    /// «над землёй» у поверхности, «над морем» в атмосфере Терры, выше — «над Террой», «над Луной», «над Веллой».
    static func label(overTerrain: Bool, body: BodyID, altitude: Double) -> String {
        if overTerrain { return "над землёй" }
        let b = Bodies.body(body)
        if body == .terra, altitude < b.atmosphereHeight { return "над морем" }
        return "над " + MapText.instrumental(body)
    }
}

/// Карточка миссии слева под стопкой ступеней: развёрнута на площадке, после старта — одна строка; тап переключает.
struct MissionCard: View {
    let model: FlightHUDModel
    /// Подсказки включены в настройках.
    var enabled = true
    /// Развёрнутая карточка помещается над крестовиной: на площадке она развёрнута по умолчанию. Иначе по умолчанию
    /// свёрнута, но тап разворачивает её поверх крестовины (карточка выше в ZStack и перехватывает касания).
    var autoExpand = true

    @State private var override: Bool?

    static let width: CGFloat = 150
    /// Верхняя оценка высоты развёрнутой карточки (цель, 5 шагов, «выполнено»).
    static let expandedHeight: CGFloat = 112
    /// Зазор между стопкой ступеней и карточкой.
    static let gap: CGFloat = 4
    /// Верх стопки ступеней (отступ 36) и зазор между стопкой и карточкой, зазор до блока кнопок.
    static func fitsExpanded(stackHeight: CGFloat, blockTop: CGFloat) -> Bool {
        36 + stackHeight + gap + expandedHeight + 4 <= blockTop
    }

    var body: some View {
        if enabled, model.missionActive {
            let expanded = override ?? (model.onPad && autoExpand)
            let done = model.missionProgress
            let complete = done >= MissionChecklist.titles.count
            Button {
                withAnimation(.snappy(duration: 0.2)) { override = !expanded }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    if expanded {
                        Text(MissionChecklist.goalTitle)
                            .font(.system(size: HUDFont.caption, weight: .heavy))
                            .foregroundStyle(HUDPalette.advice)
                        ForEach(model.missionSteps) { step in
                            MissionStepRow(step: step)
                        }
                        if complete {
                            Text(MissionChecklist.doneTitle)
                                .font(.system(size: HUDFont.caption, weight: .heavy))
                                .foregroundStyle(HUDPalette.green)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: complete ? "checkmark.circle.fill" : "diamond.fill")
                                .font(.system(size: 8))
                            Text(MissionChecklist.summary(done: done)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .font(.system(size: HUDFont.caption, weight: .semibold))
                        .foregroundStyle(complete ? HUDPalette.green : HUDPalette.advice)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(width: Self.width, alignment: .leading)
                .classicPanel(corner: 6)
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(MissionChecklist.goalTitle). \(MissionChecklist.summary(done: done))")
            .accessibilityHint(expanded ? "Свернуть список шагов" : "Показать список шагов")
        }
    }
}

private struct MissionStepRow: View {
    let step: MissionStep

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: HUDFont.caption, weight: .bold))
                .frame(width: 11)
            Text(step.title).lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.system(size: HUDFont.caption, weight: step.state == .current ? .heavy : .medium))
        .foregroundStyle(color)
    }

    private var icon: String {
        switch step.state {
        case .done: return "checkmark"
        case .current: return "diamond.fill"
        case .pending: return "circle"
        }
    }

    private var color: Color {
        switch step.state {
        case .done: return HUDPalette.green
        case .current: return HUDPalette.advice
        case .pending: return HUDPalette.muted.opacity(0.8)
        }
    }
}
