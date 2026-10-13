import OrbitPhysics
import SwiftUI

/// Название именованной системы координат экрана цеха (перетаскивание из каталога).
let hangarSpace = "hangar"

/// Левая колонка цеха: поиск, вкладки, плитки деталей. Палец на плитке ведёт деталь на корабль;
/// тап выбирает деталь (карточка характеристик и точки крепления).
struct HangarCatalog: View {
    let model: HangarModel
    @Binding var tab: CatalogTab
    @Binding var query: String
    let onDragBegan: (PartID, CGPoint) -> Void
    let onDragMoved: (CGPoint) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            searchField
            tabs
            list
        }
        .padding(5)
        .hudBackground(Color.black.opacity(0.6))
        .overlay {
            if model.dragInfo?.isDeleting == true {
                RoundedRectangle(cornerRadius: HUDStyle.corner, style: .continuous)
                    .fill(Color.red.opacity(0.35))
                    .overlay(Label("Убрать", systemImage: "trash").font(.system(size: 14, weight: .heavy)))
                    .allowsHitTesting(false)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
                .foregroundStyle(HUDStyle.secondaryText)
            TextField("Поиск", text: $query)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 3) {
                ForEach(CatalogTab.allCases) { item in
                    Button { tab = item; query = "" } label: {
                        VStack(spacing: 1) {
                            Image(systemName: item.systemImage).font(.system(size: 13, weight: .semibold))
                            Text(item.title)
                                .font(.system(size: 8.5, weight: .bold))
                                .lineLimit(1)
                        }
                        .frame(width: 58, height: 36)
                    }
                    .buttonStyle(CatalogTabStyle(isActive: tab == item && query.isEmpty))
                    .accessibilityLabel(item.title)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 38)
    }

    private var list: some View {
        let specs = CatalogTab.parts(tab: tab, query: query)
        return ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(specs, id: \.id) { spec in
                    PartTile(spec: spec,
                             isLocked: !model.isUnlocked(spec.id),
                             isArmed: model.armed == spec.id,
                             onTap: { model.arm(spec.id) },
                             onDragBegan: onDragBegan, onDragMoved: onDragMoved, onDragEnded: onDragEnded)
                }
                if specs.isEmpty {
                    Text("Ничего не найдено")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HUDStyle.secondaryText)
                        .padding(.top, 10)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// Вкладка каталога: компактная плитка с подсветкой активной.
private struct CatalogTabStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? Color.black : Color.white)
            .background(isActive ? HUDStyle.active : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Плитка детали: значок, название, масса; замок у закрытых. Палец, ушедший в сторону, берёт деталь в руку.
struct PartTile: View {
    let spec: PartSpec
    let isLocked: Bool
    let isArmed: Bool
    let onTap: () -> Void
    let onDragBegan: (PartID, CGPoint) -> Void
    let onDragMoved: (CGPoint) -> Void
    let onDragEnded: () -> Void

    private enum Phase { case idle, dragging, scrolling }
    @State private var phase: Phase = .idle

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                StageGlyph(kind: PartGlyph.kind(spec.id))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.name)
                        .font(.system(size: 12.5, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(isLocked ? "закрыто" : HangarFormat.mass(spec.wetMass))
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(HUDStyle.secondaryText)
                }
                Spacer(minLength: 0)
                if isLocked { Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(HUDStyle.accent) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(isArmed ? HUDStyle.active.opacity(0.35) : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isArmed ? HUDStyle.active : Color.clear, lineWidth: 1.5))
            .opacity(isLocked ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(dragGesture)
        .accessibilityLabel(isLocked ? "\(spec.name), закрыто" : "\(spec.name): выбрать или перетащить на корабль")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(hangarSpace))
            .onChanged { value in
                if phase == .idle {
                    // Вбок — берём деталь; вверх-вниз — прокрутка списка.
                    let dx = abs(value.translation.width), dy = abs(value.translation.height)
                    if !isLocked, dx >= dy * 0.8 {
                        phase = .dragging
                        onDragBegan(spec.id, value.location)
                    } else {
                        phase = .scrolling
                    }
                }
                if phase == .dragging { onDragMoved(value.location) }
            }
            .onEnded { _ in
                if phase == .dragging { onDragEnded() }
                phase = .idle
            }
    }
}

/// Карточка характеристик выбранной детали (над видом, слева).
struct PartCardView: View {
    let spec: PartSpec
    let lockedText: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(spec.name).font(.system(size: 14, weight: .heavy)).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Закрыть карточку")
            }
            ForEach(HangarFormat.details(spec), id: \.self) { line in
                Text(line).font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(HUDStyle.secondaryText)
            }
            Text(HangarFormat.size(spec) + " · " + HangarFormat.mountText(spec))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(HUDStyle.secondaryText)
            if let lockedText {
                Label(lockedText, systemImage: "lock.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(HUDStyle.accent)
            } else {
                Text("Перетащите на корабль или нажмите точку крепления")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HUDStyle.active)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 210, alignment: .leading)
        .hudBackground(Color.black.opacity(0.78), corner: 10)
    }
}
