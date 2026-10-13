import OrbitPhysics
import SwiftUI

/// Правая колонка цеха: редактор ступеней. Строки снизу вверх (1 — первая), значки деталей ступени,
/// Δv / TWR / время. Значок можно перетащить в другую строку или на «+ новая ступень»; тап подсвечивает деталь.
struct HangarStagePanel: View {
    let model: HangarModel

    var body: some View {
        let rows = model.report.rows
        VStack(spacing: 4) {
            HStack {
                Text("Ступени").font(.system(size: 13, weight: .heavy))
                Spacer(minLength: 0)
                Button { model.resetStaging() } label: {
                    Text("Авто").font(.system(size: 12, weight: .bold)).padding(.horizontal, 8)
                        .frame(minHeight: 30)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(model.design.customStaging ? 0.18 : 0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Расставить ступени автоматически")
            }
            .foregroundStyle(.white)

            ScrollView {
                VStack(spacing: 4) {
                    if !rows.isEmpty {
                        newStageZone("+ новая ступень", drop: .newLast)
                    }
                    ForEach(rows.reversed()) { row in
                        StageRowView(row: row, model: model)
                    }
                    if !rows.isEmpty {
                        newStageZone("+ перед первой", drop: .newFirst)
                    } else {
                        Text("Двигатели, разделители, парашют и обтекатели попадут сюда.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HUDStyle.secondaryText)
                            .padding(.top, 10)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(6)
        .hudBackground(Color.black.opacity(0.6))
    }

    private func newStageZone(_ title: String, drop: StageEditing.Drop) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(HUDStyle.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 28)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .dropDestination(for: String.self) { items, _ in
                guard let item = items.first, let id = StageEditing.parse(item) else { return false }
                model.dropStage(drop, partID: id)
                return true
            }
    }
}

/// Строка ступени: номер, значки, сводка.
private struct StageRowView: View {
    let row: HangarStageRow
    let model: HangarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(row.number)")
                    .font(.system(size: 12, weight: .heavy))
                    .frame(width: 18)
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(row.badges) { badge in
                            StageBadgeView(badge: badge)
                                .onTapGesture { model.highlight(badge.id) }
                                .draggable(StageEditing.dragItem(badge.id))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if let info = row.info {
                summary(info)
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(.white)
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, let id = StageEditing.parse(item) else { return false }
            model.dropStage(.stage(row.stage), partID: id)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ступень \(row.number)")
    }

    private func summary(_ info: StageInfo) -> some View {
        let lowTWR = info.twr > 0 && info.twr < 1
        return HStack(spacing: 8) {
            Text("Δv " + HUDFormat.speed(info.deltaV))
            Text("TWR " + HUDFormat.twr(info.twr))
                .foregroundStyle(lowTWR ? HUDStyle.accent : Color.white)
            Text(StageEditing.burnText(info.burnTime))
        }
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(.white)
    }
}

/// Значок детали ступени 32 × 32 pt; у копий симметрии — счётчик.
private struct StageBadgeView: View {
    let badge: HangarStageRow.Badge

    var body: some View {
        StageGlyph(kind: PartGlyph.kind(badge.part))
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            .frame(width: 18, height: 18)
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if badge.count > 1 {
                    Text("×\(badge.count)").font(.system(size: 8, weight: .heavy)).padding(2)
                }
            }
            .accessibilityLabel(badge.part.spec.name + (badge.count > 1 ? " ×\(badge.count)" : ""))
    }
}
