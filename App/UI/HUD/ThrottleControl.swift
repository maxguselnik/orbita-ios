import OrbitPhysics
import SwiftUI

/// Левая колонка: узкий ползунок тяги с MAX сверху и 0 снизу, рядом — один блок топлива и ступени,
/// ниже кнопка «Карта». На карте над ней — SAS и «по узлу»: прожиг можно вести, не выходя из карты.
struct ThrottleColumn: View {
    @Bindable var model: FlightHUDModel

    static let width: CGFloat = 156

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                VStack(spacing: 4) {
                    Button { model.throttle = 1 } label: { Text("MAX").font(.system(size: 12, weight: .bold)) }
                        .buttonStyle(HUDButtonStyle())
                        .accessibilityLabel("Полная тяга")
                    ThrottleSlider(value: $model.throttle, solidLocked: model.solidLocked)
                        .frame(width: HUDStyle.minTouch)
                        .frame(maxHeight: 150)
                    Button { model.throttle = 0 } label: { Text("0").font(.system(size: 15, weight: .bold)) }
                        .buttonStyle(HUDButtonStyle())
                        .accessibilityLabel("Тяга ноль")
                }
                .frame(width: HUDStyle.minTouch)
                FuelReadout(model: model)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if model.map.isOpen {
                MapSASRow(model: model)
            }
            MapToggleButton(model: model)
        }
        .frame(width: Self.width)
    }
}

/// Вертикальный ползунок 0…1: касание ставит тягу в точку, ведение пальцем — плавно.
struct ThrottleSlider: View {
    @Binding var value: Double
    /// РДТТ горит — тяга не регулируется, показываем это.
    var solidLocked = false

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let displayed = solidLocked ? 1 : value
            let level = CGFloat(min(max(displayed, 0), 1))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(HUDStyle.control)

                // Деления каждые 25 %.
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { _ in
                        Spacer(minLength: 0)
                        Rectangle().fill(.white.opacity(0.25)).frame(height: 1).padding(.horizontal, 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 1)

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [HUDStyle.accent.opacity(0.85), Color.yellow.opacity(0.9)],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(height: height * level)

                // Ручка.
                Capsule()
                    .fill(.white)
                    .frame(height: 6)
                    .padding(.horizontal, 6)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(y: -max(0, height * level - 6))

                VStack(spacing: 2) {
                    Text(HUDFormat.percent(displayed))
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(solidLocked ? "РДТТ" : "ТЯГА")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(HUDStyle.secondaryText)
                }
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 2)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HUDStyle.stroke, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard height > 0, !solidLocked else { return }
                        value = Double(min(max(1 - drag.location.y / height, 0), 1))
                    }
            )
        }
        .frame(minHeight: 70)
        .accessibilityElement()
        .accessibilityLabel("Тяга")
        .accessibilityValue(solidLocked ? "РДТТ работает на полной тяге, регулировка невозможна" : HUDFormat.percent(value))
        .accessibilityAdjustableAction { direction in
            guard !solidLocked else { return }
            if direction == .increment {
                value = min(1, value + 0.1)
            } else if direction == .decrement {
                value = max(0, value - 0.1)
            }
        }
    }
}

/// Один блок: топливо текущей ступени, «Ступень N из M», Δv ступени и всего, TWR и время работы.
struct FuelReadout: View {
    let model: FlightHUDModel

    var body: some View {
        let t = model.telemetry
        let stages = t.stages
        let stage = stages.first
        let fraction = min(1, max(0, stage?.fuelFraction ?? 0))
        let hasFuelTank = (stage?.fuelCapacity ?? 0) > 0
        let color: Color = fraction < 0.15 ? .red : .cyan
        let reserve = stages.dropFirst().reduce(0) { $0 + $1.fuelMass }
        let totalDeltaV = stages.reduce(0) { $0 + $1.deltaV }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("ТОПЛИВО").font(.system(size: 9, weight: .heavy))
                Spacer(minLength: 0)
                Text(hasFuelTank ? HUDFormat.percent(fraction) : HUDFormat.dash)
                    .font(.system(size: 13, weight: .heavy).monospacedDigit())
                    .foregroundStyle(hasFuelTank ? color : HUDStyle.secondaryText)
            }
            ProgressView(value: fraction).tint(color)
            if let stage {
                line("Ступень \(max(model.totalStages, stages.count) - stages.count + 1) из \(max(model.totalStages, stages.count))", bold: true)
                line("Δv \(HUDFormat.grouped(stage.deltaV)) / \(HUDFormat.grouped(totalDeltaV)) м/с")
                line("TWR \(HUDFormat.twr(stage.twr))" + Self.burnText(stage, throttle: model.throttle, thrust: t.thrust))
                line(hasFuelTank ? HangarFormat.mass(stage.fuelMass) + (reserve > 0 ? " · рез. " + HangarFormat.mass(reserve) : "")
                                 : "топлива нет в ступени", secondary: true)
            }
        }
        .foregroundStyle(.white)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudBackground(Color.black.opacity(0.82), corner: 10)
        .accessibilityElement(children: .combine)
    }

    /// Оставшееся время работы на текущей тяге: запас на полной тяге делится на дроссель.
    /// Ничего не показываем, если двигатель не жжёт топливо этой ступени.
    static func burnText(_ stage: StageInfo, throttle: Double, thrust: Double) -> String {
        guard stage.burnTime > 0, stage.burnTime.isFinite else { return "" }
        let level = stage.hasSolid ? 1 : (thrust > 0 ? max(throttle, 0.05) : 1)
        let label = thrust > 0 ? " · ещё " : " · при MAX "
        return label + HUDFormat.countdown(stage.burnTime / level)
    }

    private func line(_ text: String, bold: Bool = false, secondary: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: bold ? .heavy : .semibold).monospacedDigit())
            .foregroundStyle(secondary ? HUDStyle.secondaryText : Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
