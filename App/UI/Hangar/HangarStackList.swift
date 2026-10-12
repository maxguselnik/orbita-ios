import OrbitPhysics
import SwiftUI

/// Правая колонка ангара: состав корабля сверху вниз по ступеням, действия над выделенной деталью, итоговый Δv.
struct HangarStackList: View {
    let parts: [PartID]
    /// `design.stageInfos()`: [0] — первая (нижняя) ступень.
    let stages: [StageInfo]
    let selected: Int?
    let onSelect: (Int) -> Void
    let onUp: () -> Void
    let onDown: () -> Void
    let onDelete: () -> Void
    let attachment: Int
    let onAttachment: (Int) -> Void
    let onDrop: (String, Int) -> Bool

    var body: some View {
        let sections = HangarEditing.sections(of: parts)
        VStack(spacing: 6) {
            HStack {
                Text("Состав").font(.system(size: 13, weight: .heavy))
                Spacer()
                Text("\(parts.count)/\(VesselDesign.maxParts)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(HUDStyle.secondaryText)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { k, range in
                        let stageIndex = sections.count - 1 - k
                        SectionHeader(number: stageIndex + 1,
                                      info: stages.indices.contains(stageIndex) ? stages[stageIndex] : nil,
                                      isFirst: stageIndex == 0)
                        ForEach(Array(range), id: \.self) { i in
                            attachmentSlot(i)
                            row(i)
                        }
                    }
                    attachmentSlot(parts.count)
                    if parts.isEmpty {
                        Text("Начните с капсулы. Перетащите деталь к + или нажмите на карточку.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(HUDStyle.secondaryText)
                            .padding(.top, 12)
                    }
                }
            }
            .scrollIndicators(.hidden)

            HStack {
                Text("Итого Δv").foregroundStyle(HUDStyle.secondaryText)
                Spacer()
                Text(HUDFormat.speed(stages.reduce(0) { $0 + $1.deltaV }))
            }
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
        }
        .padding(8)
        .hudBackground(Color.black.opacity(0.6))
    }

    @ViewBuilder
    private func row(_ i: Int) -> some View {
        let spec = parts[i].spec
        let isSelected = selected == i
        VStack(spacing: 4) {
            Button { onSelect(i) } label: {
                HStack(spacing: 6) {
                    Text(spec.name)
                        .font(.system(size: 13, weight: isSelected ? .heavy : .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Text(HangarFormat.mass(spec.wetMass))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(HUDStyle.secondaryText)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: HUDStyle.minTouch, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .draggable("move:\(i)")
            .accessibilityLabel(spec.name)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected {
                HStack(spacing: 4) {
                    action("chevron.up", "Выше", disabled: i == 0, action: onUp)
                    action("chevron.down", "Ниже", disabled: i == parts.count - 1, action: onDown)
                    action("xmark", "Удалить", tint: Color(red: 1.0, green: 0.4, blue: 0.35), action: onDelete)
                }
            }
        }
        .padding(.horizontal, isSelected ? 4 : 0)
        .padding(.bottom, isSelected ? 4 : 0)
        .background(isSelected ? HUDStyle.active.opacity(0.28) : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isSelected ? HUDStyle.active : .clear, lineWidth: 1.5))
    }

    private func attachmentSlot(_ index: Int) -> some View {
        Button { onAttachment(index) } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                Text(attachment == index ? "Крепить сюда" : "Место крепления")
                    .font(.system(size: 9, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(attachment == index ? HUDStyle.active : HUDStyle.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, items.count == 1 else { return false }
            return onDrop(item, index)
        }
        .accessibilityLabel("Место крепления \(index + 1)")
        .accessibilityAddTraits(attachment == index ? .isSelected : [])
    }

    private func action(_ systemImage: String, _ label: String, disabled: Bool = false,
                        tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: HUDStyle.minTouch)
        }
        .buttonStyle(HUDButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(label)
    }
}

/// Заголовок секции: номер ступени по порядку срабатывания, Δv, TWR (у земли для первой, вакуум для остальных), время работы.
private struct SectionHeader: View {
    let number: Int
    let info: StageInfo?
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Ступень \(number)").font(.system(size: 12, weight: .heavy))
                Spacer(minLength: 0)
                if let info, hasEngine(info) {
                    Text("Δv " + HUDFormat.speed(info.deltaV))
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                }
            }
            Text(detail)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(HUDStyle.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func hasEngine(_ info: StageInfo) -> Bool {
        info.twrVacuum > 0 || info.twr > 0
    }

    private var detail: String {
        guard let info, hasEngine(info) else { return "без двигателей" }
        let twr = isFirst ? info.twr : info.twrVacuum
        let burn = info.burnTime > 0 ? " · работа " + HUDFormat.countdown(info.burnTime) : ""
        return "TWR " + HUDFormat.twr(twr) + (isFirst ? " у земли" : " в вакууме") + burn
    }
}
