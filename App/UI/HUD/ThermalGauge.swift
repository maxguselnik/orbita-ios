import OrbitPhysics
import SwiftUI

/// Что показывает шкала нагрева: чистая логика (видимость, цвет, подписи) без UI.
struct ThermalDisplay: Equatable {
    enum Level: Equatable {
        case normal, warning, danger
    }

    /// Порог появления шкалы.
    static let showThreshold = 0.3
    /// Жёлтый выше, красный выше.
    static let warningThreshold = 0.7
    static let dangerThreshold = 0.9
    /// Предупреждение «экран не к потоку» при нагреве выше.
    static let misalignedThreshold = 0.5

    var partName: String
    var fraction: Double
    var level: Level
    var hasShield: Bool
    /// Остаток абляционного покрытия 0…1 (при наличии экрана).
    var ablatorFraction: Double
    var shieldMisaligned: Bool

    var percentText: String { "\(Int((min(max(fraction, 0), 9.99) * 100).rounded())) %" }

    static func level(_ hottest: Double) -> Level {
        if hottest > dangerThreshold { return .danger }
        if hottest > warningThreshold { return .warning }
        return .normal
    }

    /// nil — шкала скрыта (холодно).
    static func make(_ t: ThermalStatus) -> ThermalDisplay? {
        guard t.hottest > showThreshold else { return nil }
        let hasShield = t.ablatorCapacity > 0
        return ThermalDisplay(
            partName: t.hottestPart?.spec.name ?? "Деталь",
            fraction: t.hottest,
            level: level(t.hottest),
            hasShield: hasShield,
            ablatorFraction: hasShield ? min(max(t.ablator / t.ablatorCapacity, 0), 1) : 0,
            shieldMisaligned: hasShield && t.hottest > misalignedThreshold && !t.shieldFacingFlow)
    }
}

/// Компактная шкала нагрева под строкой состояния: деталь, %, «ЭКРАН» с остатком покрытия, предупреждение.
struct ThermalGauge: View {
    let model: FlightHUDModel

    var body: some View {
        if let d = ThermalDisplay.make(model.telemetry.thermal) {
            VStack(spacing: 2) {
                pill(d)
                if d.shieldMisaligned {
                    Text("Экран не к потоку — SAS ретроград")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.red)
                        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                }
            }
            .frame(maxWidth: 340)
            .accessibilityElement(children: .combine)
            .allowsHitTesting(false)
        }
    }

    private func pill(_ d: ThermalDisplay) -> some View {
        let tint = color(d.level)
        return HStack(spacing: 5) {
            Image(systemName: "flame.fill").font(.system(size: 9))
            Text(d.partName).lineLimit(1).minimumScaleFactor(0.7)
            Text(d.percentText).font(.system(size: 10, weight: .heavy).monospacedDigit())
            if d.hasShield {
                Text("ЭКРАН \(Int((d.ablatorFraction * 100).rounded())) %")
                    .font(.system(size: 9, weight: .heavy).monospacedDigit())
                    .foregroundStyle(HUDPalette.muted)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(HUDPalette.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 1))
    }

    private func color(_ level: ThermalDisplay.Level) -> Color {
        switch level {
        case .normal: HUDPalette.text
        case .warning: HUDPalette.advice
        case .danger: Color.red
        }
    }
}
