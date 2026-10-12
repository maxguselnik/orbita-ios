import OrbitPhysics
import SwiftUI

/// Постоянная сводка одной строкой сверху по центру: состояние полёта + совет помощника подъёма
/// (если он включён настройкой подсказок) или краткое пояснение. Видна и без подсказок.
struct FlightStatusView: View {
    let model: FlightHUDModel
    /// Помощник подъёма включён (настройка подсказок).
    var ascentEnabled = true

    var body: some View {
        let t = model.telemetry
        let advice = ascentEnabled ? AscentGuide.advice(t) : nil
        HStack(spacing: 6) {
            Text(title(t)).font(.system(size: 11, weight: .heavy))
            Text(verbatim: "·").foregroundStyle(HUDStyle.secondaryText)
            if let advice {
                Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(NavballPalette.target)
                Text(advice.text).foregroundStyle(NavballPalette.target)
            } else {
                Text(detail(t)).foregroundStyle(HUDStyle.secondaryText)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: 480)
        .hudBackground(Color.black.opacity(0.8), corner: 8)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func title(_ t: FlightTelemetry) -> String {
        switch t.situation {
        case .prelaunch: return t.nextStageAction == .ignite ? "НА СТАРТОВОЙ ПЛОЩАДКЕ" : "ДВИГАТЕЛИ ЗАЖЖЕНЫ"
        case .crashed: return "АВАРИЯ"
        case .landed: return "ПОСАДКА"
        case .splashed: return "ПРИВОДНЕНИЕ"
        case .orbiting: return "НА ОРБИТЕ"
        case .escaping: return "УХОД ОТ \(Bodies.body(t.body).name.uppercased())"
        case .flying, .suborbital:
            if t.verticalSpeed < -5 { return t.heating > 0.1 ? "ВХОД В АТМОСФЕРУ" : "СНИЖЕНИЕ" }
            if t.verticalSpeed > 5 { return t.altitude > 70_000 ? "НАБОР ВЫСОТЫ · КОСМОС" : "НАБОР ВЫСОТЫ" }
            return "У ВЕРШИНЫ ТРАЕКТОРИИ"
        }
    }

    private func detail(_ t: FlightTelemetry) -> String {
        if t.situation == .crashed { return "Перезапустите полёт или вернитесь в ангар" }
        if t.situation == .prelaunch {
            if t.nextStageAction == .ignite {
                return t.stages.first?.hasSolid == true ? "Зажигание сразу запустит РДТТ" : "1. Зажигание  →  2. Тяга MAX"
            }
            if t.thrust < 1 { return "Установите тягу слева; РДТТ работает без регулировки" }
            if let stage = t.stages.first, stage.twr < 1 { return "Тяги недостаточно для взлёта · TWR < 1" }
            return "Двигатели работают · ожидается отрыв"
        }
        if t.chute == .armed { return "Парашют вооружён · ждёт безопасной высоты и скорости" }
        if t.chute == .deploying || t.chute == .open { return "Снижение под парашютом" }
        if (t.stages.first?.fuelCapacity ?? 0) > 0, (t.stages.first?.fuelFraction ?? 1) < 0.01 {
            return t.nextStageAction == .separate ? "Топливо исчерпано · отделите ступень" : "Топливо исчерпано · полёт по инерции"
        }
        if t.situation == .orbiting { return "Замкнутая орбита · двигатель \(t.thrust > 0 ? "работает" : "выключен")" }
        if t.situation == .landed || t.situation == .splashed { return "Скорость " + HUDFormat.speed(t.surfaceSpeed) }
        return "\(t.thrust > 0 ? "Двигатель работает" : "Полёт по инерции") · вертикально \(HUDFormat.signedSpeed(t.verticalSpeed))"
    }
}
