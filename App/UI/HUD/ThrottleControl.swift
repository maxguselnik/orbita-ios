import SwiftUI

/// Левая колонка: вертикальный ползунок тяги, MAX и 0, кнопка «Карта».
struct ThrottleColumn: View {
    @Bindable var model: FlightHUDModel

    var body: some View {
        VStack(spacing: 6) {
            ThrottleSlider(value: $model.throttle, solidLocked: model.telemetry.stages.first?.hasSolid == true && model.telemetry.solidBurning)
            HStack(spacing: 6) {
                Button { model.throttle = 1 } label: { Text("MAX").frame(maxWidth: .infinity) }
                    .buttonStyle(HUDButtonStyle())
                    .accessibilityLabel("Полная тяга")
                Button { model.throttle = 0 } label: { Text("0").frame(maxWidth: .infinity) }
                    .buttonStyle(HUDButtonStyle())
                    .accessibilityLabel("Тяга ноль")
            }
            .font(.system(size: 15, weight: .bold))
            Button {
                model.notify("Карта — на этапе 5")
            } label: {
                Label("Карта", systemImage: "map")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HUDButtonStyle())
        }
        .frame(width: 96)
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
            let level = CGFloat(min(max(value, 0), 1))
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
                    Text(HUDFormat.percent(value))
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                    Text(solidLocked ? "РДТТ" : "ТЯГА")
                        .font(.system(size: 9, weight: .bold))
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
                        guard height > 0 else { return }
                        value = Double(min(max(1 - drag.location.y / height, 0), 1))
                    }
            )
        }
        .frame(minHeight: 120)
        .accessibilityElement()
        .accessibilityLabel("Тяга")
        .accessibilityValue(HUDFormat.percent(value))
        .accessibilityAdjustableAction { direction in
            if direction == .increment {
                value = min(1, value + 0.1)
            } else if direction == .decrement {
                value = max(0, value - 0.1)
            }
        }
    }
}
