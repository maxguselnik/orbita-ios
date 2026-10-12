import OrbitPhysics
import SwiftUI

/// Вид детали на значке ступени.
enum StageGlyphKind: Hashable {
    case tank, engine, solid, decoupler, chute, pod, legs
}

/// Группа ступени для левой стопки HUD: номер (1 — текущая, нижняя), значки деталей и сводка `StageInfo`.
struct StageGroup: Equatable, Identifiable {
    struct Item: Equatable {
        var kind: StageGlyphKind
        var count: Int
    }

    let number: Int
    let items: [Item]
    let info: StageInfo?

    var id: Int { number }
    var isCurrent: Bool { number == 1 }

    /// Сколько значков помещается в строку.
    static let maxItems = 3

    /// Группы сверху вниз (последняя ступень первой, текущая внизу).
    /// Если состав деталей не сходится с числом ступеней в телеметрии (или деталей нет) —
    /// значки строятся по флагам `StageInfo`.
    static func groups(parts: [PartID], stages: [StageInfo]) -> [StageGroup] {
        let sections = split(parts)
        if !sections.isEmpty, sections.count == stages.count {
            return sections.enumerated().map { index, section in
                let number = sections.count - index
                return StageGroup(number: number, items: items(of: section), info: stages[number - 1])
            }
        }
        return stages.enumerated().reversed().map { index, info in
            StageGroup(number: index + 1, items: flagItems(info), info: info)
        }
    }

    /// Секции по разделителям — так же, как делит корабль физика (`Ship.sections`): разделитель открывает секцию.
    /// Физическая функция не публична, поэтому правило повторено здесь.
    static func split(_ parts: [PartID]) -> [[PartID]] {
        var out: [[PartID]] = []
        var current: [PartID] = []
        for (index, part) in parts.enumerated() {
            if index > 0, part.spec.kind == .decoupler {
                out.append(current)
                current = []
            }
            current.append(part)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func glyph(_ part: PartID) -> StageGlyphKind {
        let spec = part.spec
        switch spec.kind {
        case .tank: return .tank
        case .engine: return spec.isSolid ? .solid : .engine
        case .decoupler: return .decoupler
        case .chute: return .chute
        case .pod, .probe: return .pod
        case .legs: return .legs
        }
    }

    /// Одинаковые детали объединяются со счётчиком; порядок — по первому появлению сверху вниз.
    private static func items(of section: [PartID]) -> [Item] {
        var out: [Item] = []
        for part in section {
            let kind = glyph(part)
            if let index = out.firstIndex(where: { $0.kind == kind }) {
                out[index].count += 1
            } else {
                out.append(Item(kind: kind, count: 1))
            }
        }
        return fit(out)
    }

    private static func flagItems(_ info: StageInfo) -> [Item] {
        var out: [Item] = []
        if info.hasLiquidEngine || (info.fuelCapacity > 0 && !info.hasSolid) { out.append(Item(kind: .tank, count: 1)) }
        if info.hasLiquidEngine { out.append(Item(kind: .engine, count: 1)) }
        if info.hasSolid { out.append(Item(kind: .solid, count: 1)) }
        return out
    }

    /// Не больше `maxItems` значков: сначала отбрасываются опоры и капсула.
    private static func fit(_ items: [Item]) -> [Item] {
        var out = items
        for dropped in [StageGlyphKind.legs, .pod] where out.count > maxItems {
            out.removeAll { $0.kind == dropped }
        }
        return Array(out.prefix(maxItems))
    }
}

/// Левая стопка ступеней: «СТУПЕНИ · Δv всего» и группы сверху вниз; текущая внизу, в зелёной рамке.
struct StageStackView: View {
    let model: FlightHUDModel

    static let width: CGFloat = 156

    var body: some View {
        let stages = model.telemetry.stages
        let groups = StageGroup.groups(parts: model.parts, stages: stages)
        let total = stages.reduce(0) { $0 + $1.deltaV }
        if !groups.isEmpty {
            VStack(spacing: 4) {
                HStack {
                    Text("СТУПЕНИ").tracking(1)
                    Spacer(minLength: 0)
                    Text("Δv " + HUDFormat.grouped(total)).monospacedDigit()
                }
                .font(.system(size: 9))
                .foregroundStyle(HUDPalette.muted)
                .lineLimit(1)

                ForEach(groups) { group in
                    StageGroupRow(group: group)
                }
            }
            .frame(width: Self.width)
            .accessibilityElement(children: .contain)
        }
    }
}

/// Одна группа: бейдж с номером, значки деталей (у баков и двигателей — полоска топлива), «N %» и Δv.
struct StageGroupRow: View {
    let group: StageGroup

    var body: some View {
        let current = group.isCurrent
        HStack(spacing: 4) {
            Text("\(group.number)")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 16, height: 26)
                .background(current ? HUDPalette.greenDark : HUDPalette.stroke,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            HStack(spacing: 3) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    StageGlyphCell(item: item, fuel: fuel(for: item.kind), isCurrent: current)
                }
            }
            Spacer(minLength: 0)
            summary(current: current)
        }
        .padding(3)
        .classicPanel(corner: 7, stroke: current ? HUDPalette.greenRing : HUDPalette.stroke)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// Доля топлива ступени для значка с топливом; nil — полоски нет.
    private func fuel(for kind: StageGlyphKind) -> Double? {
        guard let info = group.info, info.fuelCapacity > 0 else { return nil }
        switch kind {
        case .tank, .engine, .solid: return min(max(info.fuelFraction, 0), 1)
        case .decoupler, .chute, .pod, .legs: return nil
        }
    }

    private func summary(current: Bool) -> some View {
        let hasFuel = (group.info?.fuelCapacity ?? 0) > 0
        let deltaV: Double = group.info?.deltaV ?? 0
        let fraction: Double = group.info?.fuelFraction ?? 0
        let firstLine: String = hasFuel ? HUDFormat.percent(fraction) : emptyCaption
        let secondLine: String = (hasFuel || deltaV > 0) ? "Δv " + HUDFormat.grouped(deltaV) : ""
        return VStack(alignment: .leading, spacing: 0) {
            Text(firstLine)
            Text(secondLine)
        }
        .font(.system(size: 8).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .foregroundStyle(current ? Color(red: 0.81, green: 0.914, blue: 0.827) : HUDPalette.muted)
        .frame(width: 32, alignment: .leading)
    }

    /// Подпись у ступени без топлива: парашют или капсула.
    private var emptyCaption: String {
        if group.items.contains(where: { $0.kind == .chute }) { return "парашют" }
        if group.items.contains(where: { $0.kind == .pod }) { return "капсула" }
        return ""
    }

    private var accessibilityText: String {
        var text = "Ступень \(group.number)" + (group.isCurrent ? ", текущая" : "")
        if let info = group.info {
            if info.fuelCapacity > 0 { text += ", топливо " + HUDFormat.percent(info.fuelFraction) }
            text += ", Δv " + HUDFormat.speed(info.deltaV)
        }
        return text
    }
}

/// Ячейка значка детали 22 × 26: контур детали и узкая вертикальная полоска топлива (красная < 15 %).
struct StageGlyphCell: View {
    let item: StageGroup.Item
    let fuel: Double?
    let isCurrent: Bool

    var body: some View {
        let tint = isCurrent ? Color(red: 0.81, green: 0.914, blue: 0.827) : HUDPalette.muted
        StageGlyph(kind: item.kind)
            .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: 13, height: 13)
            .frame(width: 22, height: 26)
            .background(isCurrent ? HUDPalette.greenDark.opacity(0.45) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let fuel {
                    FuelStrip(fraction: fuel).padding(2)
                }
            }
            .overlay(alignment: .topLeading) {
                if item.count > 1 {
                    Text("\(item.count)")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(tint)
                        .padding(.leading, 2)
                        .padding(.top, 1)
                }
            }
    }
}

/// Полоска 3 × 20 pt: заполнение снизу вверх.
struct FuelStrip: View {
    let fraction: Double

    var body: some View {
        let level = CGFloat(min(max(fraction, 0), 1))
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1, style: .continuous).fill(Color.white.opacity(0.15))
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(fraction < 0.15 ? Color.red : HUDPalette.green)
                .frame(height: 20 * level)
        }
        .frame(width: 3, height: 20)
    }
}

/// Простые векторные значки деталей в сетке 12 × 12.
struct StageGlyph: Shape {
    let kind: StageGlyphKind

    func path(in rect: CGRect) -> Path {
        let s: CGFloat = min(rect.width, rect.height) / 12
        let ox: CGFloat = rect.midX - 6 * s
        let oy: CGFloat = rect.midY - 6 * s
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }
        var p = Path()
        switch kind {
        case .chute:
            p.move(to: pt(1, 6))
            p.addQuadCurve(to: pt(11, 6), control: pt(6, -4))
            p.closeSubpath()
            p.move(to: pt(2, 6))
            p.addLine(to: pt(6, 11))
            p.addLine(to: pt(10, 6))
        case .decoupler:
            p.move(to: pt(1, 5)); p.addLine(to: pt(11, 5))
            p.move(to: pt(1, 8)); p.addLine(to: pt(11, 8))
            p.move(to: pt(6, 1)); p.addLine(to: pt(6, 4))
            p.move(to: pt(6, 9)); p.addLine(to: pt(6, 11))
        case .tank:
            p.addRoundedRect(in: CGRect(x: ox + 3 * s, y: oy + s, width: 6 * s, height: 10 * s),
                             cornerSize: CGSize(width: 2 * s, height: 2 * s))
        case .engine:
            p.move(to: pt(3, 1)); p.addLine(to: pt(9, 1)); p.addLine(to: pt(9, 5))
            p.addLine(to: pt(11, 11)); p.addLine(to: pt(1, 11)); p.addLine(to: pt(3, 5))
            p.closeSubpath()
        case .solid:
            p.move(to: pt(4, 1)); p.addLine(to: pt(8, 1)); p.addLine(to: pt(8, 9))
            p.addLine(to: pt(9, 11)); p.addLine(to: pt(3, 11)); p.addLine(to: pt(4, 9))
            p.closeSubpath()
        case .pod:
            p.move(to: pt(6, 1))
            p.addQuadCurve(to: pt(10, 10), control: pt(10, 3))
            p.addLine(to: pt(2, 10))
            p.addQuadCurve(to: pt(6, 1), control: pt(2, 3))
            p.closeSubpath()
        case .legs:
            p.move(to: pt(6, 2)); p.addLine(to: pt(6, 7))
            p.move(to: pt(6, 7)); p.addLine(to: pt(2, 11))
            p.move(to: pt(6, 7)); p.addLine(to: pt(10, 11))
        }
        return p
    }
}
