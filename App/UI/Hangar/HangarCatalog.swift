import OrbitPhysics
import SwiftUI

/// Левая колонка ангара: вкладки по типу детали и карточки каталога. Тап — добавить деталь.
struct HangarCatalog: View {
    @Binding var tab: CatalogTab
    /// Достигнут лимит деталей: карточки неактивны.
    let isFull: Bool
    let onAdd: (PartID) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(CatalogTab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: item.systemImage).font(.system(size: 14, weight: .semibold))
                            Text(item.title)
                                .font(.system(size: 9, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: HUDStyle.minTouch)
                    }
                    .buttonStyle(HUDButtonStyle(isActive: tab == item))
                    .accessibilityLabel(item.title)
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(tab.parts, id: \.id) { spec in
                        PartCard(spec: spec, isDisabled: isFull) { onAdd(spec.id) }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Карточка детали: название, 1–2 ключевых числа, «+» справа.
struct PartCard: View {
    let spec: PartSpec
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    ForEach(HangarFormat.details(spec), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(HUDStyle.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(isDisabled ? HUDStyle.secondaryText : HUDStyle.active)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        }
        .buttonStyle(HUDButtonStyle())
        .opacity(isDisabled ? 0.4 : 1)
        .allowsHitTesting(!isDisabled)
        .accessibilityLabel("Добавить: \(spec.name)")
    }
}
