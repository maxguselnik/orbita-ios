import OrbitPhysics
import SwiftUI

/// Выдвижная панель: топливо, Δv, TWR по ступеням; «Наука» и «Контракты» — заглушки.
struct StagePanel: View {
    let model: FlightHUDModel

    enum Tab: String, CaseIterable, Identifiable {
        case stages = "Ступени"
        case science = "Наука"
        case contracts = "Контракты"
        var id: Self { self }
    }

    @State private var tab: Tab = .stages

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HUDButtonStyle(isActive: tab == item))
                }
                Button {
                    withAnimation(.snappy(duration: 0.25)) { model.isPanelOpen = false }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(HUDButtonStyle())
                .accessibilityLabel("Закрыть панель")
            }

            switch tab {
            case .stages:
                stagesList
            case .science:
                stub("Приборы и данные появятся на этапе 7.", systemImage: "flask")
            case .contracts:
                stub("Контракты появятся на этапе 8.", systemImage: "doc.text")
            }
        }
        .padding(8)
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .hudBackground(Color.black.opacity(0.78))
    }

    private var stagesList: some View {
        let stages = model.telemetry.stages
        let total = stages.reduce(0) { $0 + $1.deltaV }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Всего Δv").foregroundStyle(HUDStyle.secondaryText)
                Spacer()
                Text(HUDFormat.speed(total))
            }
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                        StageRow(number: stages.count - index, stage: stage, isCurrent: index == 0)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func stub(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 26))
            Text(text).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
        }
        .foregroundStyle(HUDStyle.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Строка ступени: топливо полосой, Δv, TWR (атм./вак.), время работы.
struct StageRow: View {
    let number: Int
    let stage: StageInfo
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Ступень \(number)").font(.system(size: 12, weight: .heavy))
                if stage.hasSolid {
                    Text("РДТТ")
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(HUDStyle.accent.opacity(0.8), in: Capsule())
                }
                if isCurrent {
                    Text("текущая").font(.system(size: 10, weight: .semibold)).foregroundStyle(HUDStyle.active)
                }
                Spacer()
                Text(HUDFormat.percent(stage.fuelFraction))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(stage.fuelFraction < 0.15 ? Color.red : Color.green.opacity(0.85))
                        .frame(width: geo.size.width * CGFloat(min(max(stage.fuelFraction, 0), 1)))
                }
            }
            .frame(height: 6)
            HStack(spacing: 10) {
                labeled("Δv", HUDFormat.speed(stage.deltaV))
                labeled("TWR", "\(HUDFormat.twr(stage.twr)) / \(HUDFormat.twr(stage.twrVacuum))")
                labeled("MAX", HUDFormat.countdown(stage.burnTime > 0 ? stage.burnTime : nil))
            }
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(isCurrent ? Color.white.opacity(0.12) : Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(HUDStyle.secondaryText)
            Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit()).lineLimit(1)
        }
    }
}
