import OrbitPhysics
import SwiftUI

/// Верхняя полоса: телеметрия в строку и мелкая вторая строка, ускорение времени, язычок панели ступеней, пауза.
/// Каждый кадр перерисовываются только числа (`TopBarMetrics`), кнопки — при смене своих полей.
struct HUDTopBar: View {
    let model: FlightHUDModel

    var body: some View {
        HStack(spacing: 10) {
            TopBarMetrics(model: model)
                .layoutPriority(1)

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

/// Главные величины одной строкой (подпись над значением) и мелкая вторая строка с остальным —
/// единственная часть полосы, читающая кадр.
struct TopBarMetrics: View {
    let model: FlightHUDModel

    var body: some View {
        let t = model.telemetry
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 12) {
                HUDMetric(label: "Высота", value: HUDFormat.distance(t.altitude))
                HUDMetric(label: "Скорость", value: HUDFormat.speed(t.surfaceSpeed))
                HUDMetric(label: "Апоцентр", value: HUDFormat.distance(t.orbit?.apoapsisAltitude))
                HUDMetric(label: "Перицентр", value: HUDFormat.periapsis(t.orbit?.periapsisAltitude))
                HUDMetric(label: "До апоцентра", value: HUDFormat.countdown(t.orbit?.timeToApoapsis))
            }
            Text("Вертикальная скорость \(HUDFormat.signedSpeed(t.verticalSpeed)) · над землёй \(HUDFormat.distance(t.heightAboveTerrain)) · \(HUDFormat.missionTime(t.missionTime))")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(HUDStyle.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.leading, 4)
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
        .frame(minWidth: 52, alignment: .leading)
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
            HStack(spacing: 4) {
                Image(systemName: t.index > 0 ? "forward.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(HUDFormat.warp(t.factor))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(t.index > 0 ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .frame(minWidth: 64, minHeight: HUDStyle.minTouch)
            .contentShape(Rectangle())
            .hudBackground(t.index > 0 ? HUDStyle.accent : HUDStyle.control, corner: 10)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Ускорение времени \(HUDFormat.warp(t.factor))")
    }
}
