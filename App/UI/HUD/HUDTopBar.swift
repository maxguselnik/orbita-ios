import OrbitPhysics
import SwiftUI

/// Верхняя полоса: телеметрия в две строки, ускорение времени, язычок панели ступеней, пауза.
struct HUDTopBar: View {
    let model: FlightHUDModel

    var body: some View {
        let t = model.telemetry
        HStack(spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    HUDMetric(label: "ВЫС", value: HUDFormat.distance(t.altitude))
                    HUDMetric(label: "СКОР", value: HUDFormat.speed(t.speed))
                    HUDMetric(label: "ВЕРТ", value: HUDFormat.signedSpeed(t.verticalSpeed))
                    HUDMetric(label: "ГРУНТ", value: HUDFormat.distance(t.heightAboveTerrain))
                }
                GridRow {
                    HUDMetric(label: "Ап", value: HUDFormat.distance(t.orbit?.apoapsisAltitude))
                    HUDMetric(label: "Пе", value: HUDFormat.distance(t.orbit?.periapsisAltitude))
                    HUDMetric(label: "до Ап", value: HUDFormat.countdown(t.orbit?.timeToApoapsis))
                    HUDMetric(label: "Т+", value: HUDFormat.clock(t.missionTime))
                }
            }
            .padding(.leading, 4)

            Spacer(minLength: 0)

            WarpMenu(model: model)

            Button {
                withAnimation(.snappy(duration: 0.25)) { model.isPanelOpen.toggle() }
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(HUDButtonStyle(isActive: model.isPanelOpen))
            .accessibilityLabel("Ступени, топливо, Δv")

            Button {
                model.pause()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Пауза")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .hudBackground()
    }
}

/// Подпись и значение телеметрии.
struct HUDMetric: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(HUDStyle.secondaryText)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(minWidth: 66, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Ускорение времени: тап — список уровней из `TimeWarp.levels`.
struct WarpMenu: View {
    let model: FlightHUDModel

    var body: some View {
        let t = model.telemetry
        Menu {
            if let reason = t.warpBlocked {
                Text(verbatim: "Выше \(HUDFormat.warp(TimeWarp.levels[TimeWarp.physicalCount - 1])) нельзя: \(FlightHUDModel.warpReasonText(reason))")
            }
            ForEach(Array(TimeWarp.levels.enumerated()), id: \.offset) { index, factor in
                Button {
                    model.send(.setWarp(index: index))
                } label: {
                    if index == t.warpIndex {
                        Label(HUDFormat.warp(factor), systemImage: "checkmark")
                    } else {
                        Text(HUDFormat.warp(factor))
                    }
                }
                .disabled(t.warpBlocked != nil && index >= TimeWarp.physicalCount)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: t.warpIndex > 0 ? "forward.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(HUDFormat.warp(t.warpFactor))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(t.warpIndex > 0 ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .frame(minWidth: 64, minHeight: HUDStyle.minTouch)
            .contentShape(Rectangle())
            .hudBackground(t.warpIndex > 0 ? HUDStyle.accent : HUDStyle.control, corner: 10)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Ускорение времени \(HUDFormat.warp(t.warpFactor))")
    }
}
