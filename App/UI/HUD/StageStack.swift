import OrbitPhysics
import SwiftUI

/// Вид детали на значке ступени.
enum StageGlyphKind: Hashable {
    case tank, engine, solid, decoupler, chute, pod, legs, rcs, mono, fairing, fin, shield
    // Ровер (6.3)
    case wheel, roverFrame, battery, solar, seat
}

/// Значок для детали (каталог, редактор ступеней, исследования, HUD).
enum PartGlyph {
    static func kind(_ part: PartID) -> StageGlyphKind {
        let spec = part.spec
        switch spec.kind {
        case .tank: return .tank
        case .engine: return spec.isSolid ? .solid : .engine
        case .decoupler: return .decoupler
        case .chute: return .chute
        case .pod, .probe: return .pod
        case .legs: return .legs
        case .wheel: return .wheel
        case .roverFrame: return .roverFrame
        case .battery: return .battery
        case .solar: return .solar
        case .seat: return .seat
        case .rcs: return .rcs
        case .monoTank: return .mono
        case .fairing: return .fairing
        case .fin, .instrument: return .fin
        case .heatShield: return .shield
        }
    }
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

    /// Группы сверху вниз (последняя ступень первой, текущая внизу). Значки — по `StageInfo.parts` (что срабатывает
    /// в ступени); если деталей нет — по флагам `StageInfo`.
    static func groups(stages: [StageInfo]) -> [StageGroup] {
        stages.enumerated().reversed().map { index, info in
            let glyphs = info.parts.isEmpty ? flagItems(info) : items(of: info.parts)
            return StageGroup(number: index + 1, items: glyphs, info: info)
        }
    }

    /// Одинаковые детали объединяются со счётчиком; порядок — по первому появлению сверху вниз.
    private static func items(of section: [PartID]) -> [Item] {
        var out: [Item] = []
        for part in section {
            let kind = PartGlyph.kind(part)
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
        for dropped in [StageGlyphKind.legs, .rcs, .mono, .pod, .fin, .seat, .battery, .solar, .roverFrame] where out.count > maxItems {
            out.removeAll { $0.kind == dropped }
        }
        return Array(out.prefix(maxItems))
    }
}

/// Левая стопка ступеней (Б4): до четырёх строк по 28 pt, текущая ступень внизу, в зелёной рамке. Тап открывает
/// панель ступеней (топливо, Δv, TWR).
struct StageStackView: View {
    let model: FlightHUDModel

    static let width: CGFloat = 150
    /// Сколько ступеней показывается в стопке (ближайшие к текущей); остальные — в панели.
    static let maxRows = 4

    /// Сколько строк сейчас в стопке (0…`maxRows`).
    static func rowCount(model: FlightHUDModel) -> Int {
        min(StageGroup.groups(stages: model.telemetry.stages).count, maxRows)
    }

    var body: some View {
        let groups = StageGroup.groups(stages: model.telemetry.stages)
        if !groups.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.25)) { model.isPanelOpen.toggle() }
            } label: {
                VStack(spacing: 3) {
                    ForEach(groups.suffix(Self.maxRows)) { group in
                        StageGroupRow(group: group)
                    }
                }
                .frame(width: Self.width)
            }
            .buttonStyle(HUDPressStyle())
            .accessibilityHint("Открыть панель ступеней")
        }
    }
}

/// Одна строка 28 pt: номер, значки деталей и подпись — «N %» топлива или «парашют» / «капсула»;
/// у текущей ступени справа ещё мини-шкала топлива (красная ниже 15 %).
struct StageGroupRow: View {
    let group: StageGroup

    static let height: CGFloat = 28

    var body: some View {
        let current = group.isCurrent
        let hasFuel = (group.info?.fuelCapacity ?? 0) > 0
        let fraction: Double = min(max(group.info?.fuelFraction ?? 0, 0), 1)
        HStack(spacing: 4) {
            Text("\(group.number)")
                .font(.system(size: HUDFont.caption, weight: .heavy))
                .foregroundStyle(current ? Color.white : HUDPalette.text)
            HStack(spacing: 1) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    StageGlyphCell(item: item, isCurrent: current)
                }
            }
            Text(hasFuel ? HUDFormat.percent(fraction) : emptyCaption)
                .font(.system(size: HUDFont.caption).monospacedDigit())
                .foregroundStyle(hasFuel ? (fraction < 0.15 ? Color.red : HUDPalette.green) : HUDPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            if current, hasFuel {
                FuelStrip(fraction: fraction)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: Self.height)
        .background(current ? HUDPalette.greenDark.opacity(0.5) : HUDPalette.panel.opacity(0.8),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(current ? HUDPalette.greenRing : Color.clear, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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

/// Значок детали 14 × 16 pt; при нескольких одинаковых — маленький счётчик.
struct StageGlyphCell: View {
    let item: StageGroup.Item
    let isCurrent: Bool

    var body: some View {
        let tint = isCurrent ? Color(red: 0.81, green: 0.914, blue: 0.827) : HUDPalette.muted
        StageGlyph(kind: item.kind)
            .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            .frame(width: 11, height: 11)
            .frame(width: 14, height: 16)
            .overlay(alignment: .topTrailing) {
                if item.count > 1 {
                    Text("\(item.count)")
                        // Счётчик на значке 14 × 16 pt: 10 pt — меньше не стоит, больше не влезает.
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(tint)
                        .offset(x: 2, y: -1)
                }
            }
    }
}

/// Горизонтальная полоска 30 × 4 pt: заполнение слева направо.
struct FuelStrip: View {
    let fraction: Double

    var body: some View {
        let level = CGFloat(min(max(fraction, 0), 1))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.15))
            Capsule()
                .fill(fraction < 0.15 ? Color.red : HUDPalette.green)
                .frame(width: 30 * level)
        }
        .frame(width: 30, height: 4)
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
        case .rcs:
            // Блок РСУ: квадрат и четыре сопла по сторонам.
            p.addRect(CGRect(x: ox + 4 * s, y: oy + 4 * s, width: 4 * s, height: 4 * s))
            p.move(to: pt(6, 1)); p.addLine(to: pt(6, 4))
            p.move(to: pt(6, 8)); p.addLine(to: pt(6, 11))
            p.move(to: pt(1, 6)); p.addLine(to: pt(4, 6))
            p.move(to: pt(8, 6)); p.addLine(to: pt(11, 6))
        case .fairing:
            // Обтекатель: оживальный нос с шпангоутом.
            p.move(to: pt(6, 0.5))
            p.addQuadCurve(to: pt(9.5, 10), control: pt(9.5, 4))
            p.addLine(to: pt(2.5, 10))
            p.addQuadCurve(to: pt(6, 0.5), control: pt(2.5, 4))
            p.move(to: pt(3.5, 7)); p.addLine(to: pt(8.5, 7))
        case .shield:
            // Теплозащитный экран: выпуклое днище с абляционными полосами.
            p.move(to: pt(1, 4)); p.addLine(to: pt(11, 4))
            p.addQuadCurve(to: pt(1, 4), control: pt(6, 14))
            p.move(to: pt(4, 6)); p.addLine(to: pt(4, 8))
            p.move(to: pt(8, 6)); p.addLine(to: pt(8, 8))
        case .fin:
            // Стабилизатор: крыло-трапеция у стенки.
            p.move(to: pt(2, 1)); p.addLine(to: pt(2, 11))
            p.move(to: pt(2, 3)); p.addLine(to: pt(10, 8)); p.addLine(to: pt(10, 11)); p.addLine(to: pt(2, 11))
        case .wheel:
            // Колесо: обод со ступицей.
            p.addEllipse(in: CGRect(x: ox + 1.5 * s, y: oy + 1.5 * s, width: 9 * s, height: 9 * s))
            p.addEllipse(in: CGRect(x: ox + 5 * s, y: oy + 5 * s, width: 2 * s, height: 2 * s))
        case .roverFrame:
            // Рама: платформа на двух осях.
            p.addRect(CGRect(x: ox + 1 * s, y: oy + 4 * s, width: 10 * s, height: 3 * s))
            p.move(to: pt(3, 7)); p.addLine(to: pt(3, 10))
            p.move(to: pt(9, 7)); p.addLine(to: pt(9, 10))
        case .battery:
            // Батарея: корпус с контактом и молнией.
            p.addRect(CGRect(x: ox + 2 * s, y: oy + 3 * s, width: 8 * s, height: 7 * s))
            p.addRect(CGRect(x: ox + 4.5 * s, y: oy + 1.5 * s, width: 3 * s, height: 1.5 * s))
            p.move(to: pt(6.5, 4.5)); p.addLine(to: pt(5, 7)); p.addLine(to: pt(7, 7)); p.addLine(to: pt(5.5, 9.5))
        case .solar:
            // Панель: наклонный параллелограмм с сеткой.
            p.move(to: pt(3, 2)); p.addLine(to: pt(11, 2)); p.addLine(to: pt(9, 9)); p.addLine(to: pt(1, 9))
            p.closeSubpath()
            p.move(to: pt(6, 2)); p.addLine(to: pt(4.5, 9))
            p.move(to: pt(2, 5.5)); p.addLine(to: pt(10, 5.5))
            p.move(to: pt(5, 9)); p.addLine(to: pt(5, 11))
        case .seat:
            // Кресло: спинка и сиденье.
            p.move(to: pt(3, 1)); p.addLine(to: pt(3, 8)); p.addLine(to: pt(10, 8))
            p.move(to: pt(3, 8)); p.addLine(to: pt(3, 11))
            p.move(to: pt(10, 8)); p.addLine(to: pt(10, 11))
        case .mono:
            // Бак монотоплива: маленькая капсула со шпангоутом.
            p.addRoundedRect(in: CGRect(x: ox + 4 * s, y: oy + 2 * s, width: 4 * s, height: 8 * s),
                             cornerSize: CGSize(width: 2 * s, height: 2 * s))
            p.move(to: pt(4, 6)); p.addLine(to: pt(8, 6))
        }
        return p
    }
}
