import OrbitPhysics
import SwiftUI

/// Итоги полёта: панель снизу по центру поверх навбола, центр кадра свободен.
/// Рассчитана на ширину между колонками управления (≈ 430 pt).
struct FlightResultPanel: View {
    let result: FlightResult
    /// Результатов, потерянных с разбитым кораблём (0 — не показывать).
    var lostData = 0
    let onHangar: () -> Void
    let onSpaceCenter: () -> Void
    /// Начисляет ещё не учтённые вехи полёта и возвращает итог полёта (повторный вызов ничего не добавляет).
    let onFinish: (MissionRecord) -> FlightAwardSummary
    let onRetry: () -> Void
    let onContinue: () -> Void

    @State private var award: FlightAwardSummary?

    var body: some View {
        let m = result.mission
        VStack(spacing: 8) {
            Text(result.title)
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(result.outcome == .crashed ? Color(red: 1.0, green: 0.4, blue: 0.35) : .white)

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 4) {
                    stat("Макс. высота", HUDFormat.distance(m.maxAltitude))
                    stat("Макс. скорость", HUDFormat.speed(m.maxSpeed))
                    stat("Макс. перегрузка", HUDFormat.fixed(m.maxGForce, digits: 1) + " g")
                    stat("Время миссии", HUDFormat.clock(result.missionTime))
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 3) {
                    achievement("Космос", m.reachedSpace)
                    achievement("Орбита", m.reachedOrbit)
                    achievement("Луна (SOI)", m.enteredLunaSOI)
                    achievement("Орбита Луны", m.lunaOrbit)
                    achievement("Посадка на Луну", m.landedLuna)
                    achievement("Другая планета", !m.visitedPlanets.isEmpty)
                    achievement("Возврат", m.returnedFromSpace)
                }
                .frame(width: 150, alignment: .leading)
            }

            awardLine

            HStack(spacing: 8) {
                button("В ангар", systemImage: "wrench.and.screwdriver", action: onHangar)
                button("В космоцентр", systemImage: "building.2", action: onSpaceCenter)
                button("Начать заново", systemImage: "arrow.counterclockwise", action: onRetry)
                if result.canContinue {
                    button("Продолжить", systemImage: "play.fill", primary: true, action: onContinue)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 430)
        .hudBackground(Color.black.opacity(0.82), corner: 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .onAppear {
            if award == nil { award = onFinish(result.mission) }
        }
    }

    /// «+⚛ N  Данные D  Вехи M», новые вехи и потерянные данные; без науки и потерь — пусто (урок, сценарий).
    @ViewBuilder private var awardLine: some View {
        if let award, award.science > 0 || lostData > 0 {
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if award.science > 0 {
                        Text("+⚛ \(award.science)")
                            .font(.system(size: 17, weight: .heavy).monospacedDigit())
                            .foregroundStyle(HUDStyle.accent)
                    }
                    if award.data > 0 {
                        split("Данные", award.data)
                        split("Вехи", award.science - award.data)
                    }
                }
                if lostData > 0 {
                    Text("Потеряно с кораблём: \(lostData) " + (lostData == 1 ? "результат" : lostData < 5 ? "результата" : "результатов"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.54, blue: 0.48))
                }
                if !award.fresh.isEmpty {
                    Text("Новые вехи: " + award.fresh.map(\.title).joined(separator: ", "))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(HUDPalette.green)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func split(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(HUDStyle.secondaryText)
            Text("\(value)").foregroundStyle(.white)
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(HUDStyle.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func achievement(_ title: String, _ done: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(done ? Color.green : HUDStyle.secondaryText.opacity(0.6))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(done ? Color.white : HUDStyle.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "выполнено" : "не выполнено")
    }

    private func button(_ title: String, systemImage: String, primary: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(HUDButtonStyle(isActive: primary))
    }
}

/// Плашка подсказки: сверху по центру, ниже тоста. Крестик скрывает подсказки до конца полёта.
struct HintBanner: View {
    let hint: HUDHint
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HUDStyle.accent)
                .padding(.leading, 12)
            Text(hint.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Скрыть подсказки")
        }
        .padding(.vertical, 2)
        .padding(.trailing, 2)
        .frame(maxWidth: 440)
        .hudBackground(Color.black.opacity(0.7), corner: 12)
        .id(hint)
    }
}
