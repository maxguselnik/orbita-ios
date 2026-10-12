import OrbitPhysics
import SwiftUI

/// Верхняя полоса одной строкой: высота, скорость, Ап, Пе (и «До Ап», когда есть смысл); тап по цифрам
/// добавляет вертикальную скорость, высоту над землёй и T+. Справа малые кнопки: время, ступени, пауза.
/// Каждый кадр перерисовываются только числа (`TopBarMetrics`), кнопки — при смене своих полей.
struct HUDTopBar: View {
    let model: FlightHUDModel

    var body: some View {
        HStack(spacing: 6) {
            TopBarMetrics(model: model)
                .layoutPriority(1)

            Spacer(minLength: 0)

            WarpMenu(model: model)

            Button {
                withAnimation(.snappy(duration: 0.25)) { model.isPanelOpen.toggle() }
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.isPanelOpen ? Color.black : Color.white)
                    .frame(width: 38, height: 34)
                    .hudBackground(model.isPanelOpen ? HUDStyle.active : HUDStyle.control, corner: 9)
                    .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityLabel("Ступени, топливо, Δv")

            Button {
                model.pause()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 34)
                    .hudBackground(HUDStyle.control, corner: 9)
                    .frame(width: HUDStyle.minTouch, height: HUDStyle.minTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityLabel("Пауза")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .hudBackground()
    }
}

/// Главные величины одной строкой (подпись над значением); тап раскрывает вторую группу в той же строке.
/// Единственная часть полосы, читающая кадр.
struct TopBarMetrics: View {
    let model: FlightHUDModel

    @State private var expanded = false

    var body: some View {
        let t = model.telemetry
        Button {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                HUDMetric(label: "Высота", value: HUDFormat.distance(t.altitude))
                HUDMetric(label: "Скорость", value: HUDFormat.speed(t.surfaceSpeed))
                HUDMetric(label: "Апоцентр", value: HUDFormat.distance(t.orbit?.apoapsisAltitude))
                HUDMetric(label: "Перицентр", value: HUDFormat.periapsis(t.orbit?.periapsisAltitude))
                if Self.showsTimeToApoapsis(t) {
                    HUDMetric(label: "До Ап", value: HUDFormat.countdown(t.orbit?.timeToApoapsis))
                }
                if expanded {
                    HUDMetric(label: "Верт. скорость", value: HUDFormat.signedSpeed(t.verticalSpeed))
                    HUDMetric(label: "Над землёй", value: HUDFormat.distance(t.heightAboveTerrain))
                    HUDMetric(label: "T+", value: HUDFormat.missionTime(t.missionTime))
                }
                Image(systemName: expanded ? "chevron.left" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(HUDStyle.secondaryText)
            }
            .padding(.leading, 4)
            .frame(minHeight: HUDStyle.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Показать или скрыть вертикальную скорость, высоту над землёй и время полёта")
    }

    /// «До Ап» нужно в полёте и на орбите, пока апоцентр впереди; на площадке и на земле — нет.
    static func showsTimeToApoapsis(_ t: FlightTelemetry) -> Bool {
        let inFlight = t.situation == .flying || t.situation == .suborbital || t.situation == .orbiting
        guard inFlight, let toApo = t.orbit?.timeToApoapsis, toApo.isFinite else { return false }
        return toApo > 0
    }
}

/// Подпись над значением телеметрии.
struct HUDMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(HUDStyle.secondaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                // Самое длинное значение («−198.2 км», «12.00 Мм») сжимается, а не обрезается многоточием.
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: 46, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Ускорение времени: тап — список уровней из `TimeWarp.levels` и «До узла манёвра», если узел есть.
struct WarpMenu: View {
    let model: FlightHUDModel

    var body: some View {
        let t = model.warp
        Menu {
            if let reason = t.blocked {
                Text(verbatim: "Выше \(HUDFormat.warp(TimeWarp.levels[TimeWarp.physicalCount - 1])) нельзя: \(FlightHUDModel.warpReasonText(reason))")
            }
            if model.hasManeuver {
                Button {
                    model.warpToManeuver()
                } label: {
                    Label("До узла манёвра", systemImage: "forward.end.fill")
                }
                .disabled(!model.canWarpToManeuver)
            }
            ForEach(Array(TimeWarp.levels.enumerated()), id: \.offset) { index, factor in
                Button {
                    model.send(.setWarp(index: index))
                } label: {
                    if index == t.index {
                        Label(HUDFormat.warp(factor), systemImage: "checkmark")
                    } else {
                        Text(HUDFormat.warp(factor))
                    }
                }
                .disabled(t.blocked != nil && index >= TimeWarp.physicalCount)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: t.index > 0 ? "forward.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(HUDFormat.warp(t.factor))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(t.index > 0 ? Color.black : Color.white)
            .padding(.horizontal, 8)
            .frame(minWidth: 52, minHeight: 34)
            .hudBackground(t.index > 0 ? HUDStyle.accent : HUDStyle.control, corner: 9)
            .frame(minHeight: HUDStyle.minTouch)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Ускорение времени \(HUDFormat.warp(t.factor))")
    }
}
