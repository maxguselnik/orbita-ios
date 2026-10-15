import OrbitPhysics
import SwiftUI

/// Исследовательский центр: дерево технологий по `TechTree`, открытие за науку, архив вех.
struct ResearchView: View {
    let flow: GameFlow

    @State private var selected: TechID?
    @State private var showArchive = false

    private static let nodeSize = CGSize(width: 128, height: 58)
    private static let gap = CGSize(width: 36, height: 22)
    private static let pad: CGFloat = 14

    private static let green = Color(red: 0.3, green: 0.8, blue: 0.45)
    private static let blue = Color(red: 0.3, green: 0.6, blue: 1.0)

    var body: some View {
        let progress = flow.progress ?? GameProgress(mode: .sandbox)
        VStack(spacing: 6) {
            topBar(progress)
            ZStack(alignment: .bottomTrailing) {
                tree(progress)
                if let selected {
                    TechCard(tech: selected, progress: progress,
                             onResearch: { _ = flow.research(selected) },
                             onClose: { self.selected = nil })
                        .padding(8)
                }
                if showArchive {
                    MilestoneArchive(progress: progress, onClose: { showArchive = false })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.55))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HUDStyle.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HUDStyle.corner, style: .continuous)
                .strokeBorder(HUDStyle.stroke, lineWidth: 1))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea())
    }

    // MARK: - Верхняя полоса

    private func topBar(_ progress: GameProgress) -> some View {
        HStack(spacing: 8) {
            Button { flow.open(.spaceCenter) } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .bold))
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("В космоцентр")
            Text("ИССЛЕДОВАНИЯ").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
            if progress.mode == .sandbox {
                Text("Песочница: всё открыто")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HUDPalette.green)
            } else {
                Text("⚛ \(progress.science)")
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundStyle(HUDStyle.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
            Button { showArchive.toggle() } label: {
                Label("Архив вех", systemImage: "archivebox")
                    .font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(HUDButtonStyle(isActive: showArchive))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .hudBackground()
    }

    // MARK: - Дерево

    private func origin(_ node: TechNode) -> CGPoint {
        CGPoint(x: Self.pad + CGFloat(node.column) * (Self.nodeSize.width + Self.gap.width),
                y: Self.pad + CGFloat(node.row) * (Self.nodeSize.height + Self.gap.height))
    }

    private var treeSize: CGSize {
        let columns = CGFloat((TechTree.nodes.map(\.column).max() ?? 0) + 1)
        let rows = CGFloat((TechTree.nodes.map(\.row).max() ?? 0) + 1)
        return CGSize(width: Self.pad * 2 + columns * Self.nodeSize.width + (columns - 1) * Self.gap.width,
                      height: Self.pad * 2 + rows * Self.nodeSize.height + (rows - 1) * Self.gap.height)
    }

    private func tree(_ progress: GameProgress) -> some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                links(progress)
                ForEach(TechTree.nodes) { node in
                    let position = origin(node)
                    TechNodeView(node: node,
                                 state: SpaceCenterLogic.state(of: node.id, progress: progress),
                                 isSelected: selected == node.id)
                        .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
                        .offset(x: position.x, y: position.y)
                        .onTapGesture { selected = node.id }
                }
            }
            .frame(width: treeSize.width, height: treeSize.height, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .background(Color.black.opacity(0.35))
    }

    /// Связи кривыми от правого края предыдущей технологии к левому краю следующей.
    private func links(_ progress: GameProgress) -> some View {
        Canvas { context, _ in
            for node in TechTree.nodes {
                let end = origin(node)
                for requirement in node.requires {
                    let start = origin(TechTree.node(requirement))
                    let a = CGPoint(x: start.x + Self.nodeSize.width, y: start.y + Self.nodeSize.height / 2)
                    let b = CGPoint(x: end.x, y: end.y + Self.nodeSize.height / 2)
                    var path = Path()
                    path.move(to: a)
                    let dx = (b.x - a.x) / 2
                    path.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
                    let done = progress.isResearched(requirement) && progress.isResearched(node.id)
                    let open = progress.isResearched(requirement)
                    context.stroke(path, with: .color(done ? Self.green : (open ? Self.blue.opacity(0.8) : Color.white.opacity(0.25))),
                                   lineWidth: 2)
                }
            }
        }
        .frame(width: treeSize.width, height: treeSize.height)
        .allowsHitTesting(false)
    }
}

/// Узел дерева: название, цена или отметка; цвет по состоянию.
struct TechNodeView: View {
    let node: TechNode
    let state: SpaceCenterLogic.TechState
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(node.title)
                .font(.system(size: 12.5, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isSelected ? Color.white : stroke, lineWidth: isSelected ? 2.5 : 1.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.title + ", " + caption)
    }

    private var caption: String {
        switch state {
        case .researched: "✓ открыто"
        case .available, .needsScience: "⚛ \(node.cost)"
        case .locked: "закрыто"
        }
    }

    private var fill: Color {
        switch state {
        case .researched: Color(red: 0.12, green: 0.38, blue: 0.2)
        case .available: Color(red: 0.12, green: 0.28, blue: 0.55)
        case .needsScience, .locked: Color(red: 0.2, green: 0.22, blue: 0.27)
        }
    }

    private var stroke: Color {
        switch state {
        case .researched: Color(red: 0.3, green: 0.8, blue: 0.45)
        case .available: Color(red: 0.3, green: 0.6, blue: 1.0)
        case .needsScience: Color.white.opacity(0.35)
        case .locked: Color.white.opacity(0.15)
        }
    }

    private var textColor: Color {
        state == .locked ? Color.white.opacity(0.45) : Color.white
    }
}

/// Карточка технологии: детали, цена, «Открыть» или причина.
struct TechCard: View {
    let tech: TechID
    let progress: GameProgress
    let onResearch: () -> Void
    let onClose: () -> Void

    var body: some View {
        let node = TechTree.node(tech)
        let state = SpaceCenterLogic.state(of: tech, progress: progress)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(node.title).font(.system(size: 15, weight: .heavy))
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть карточку")
            }
            ForEach(node.parts, id: \.self) { part in
                HStack(spacing: 6) {
                    StageGlyph(kind: PartGlyph.kind(part))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                        .frame(width: 16, height: 16)
                    Text(part.spec.name).font(.system(size: 12, weight: .semibold))
                }
            }
            action(node, state)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(width: 250, alignment: .leading)
        .hudBackground(Color.black.opacity(0.88), corner: 12)
    }

    @ViewBuilder
    private func action(_ node: TechNode, _ state: SpaceCenterLogic.TechState) -> some View {
        switch state {
        case .researched:
            Label("Открыто", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(HUDPalette.green)
        case .available:
            Button(action: onResearch) {
                Text("Открыть за ⚛ \(node.cost)")
                    .font(.system(size: 14, weight: .heavy))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(HUDButtonStyle(isActive: true))
        case .needsScience, .locked:
            VStack(alignment: .leading, spacing: 2) {
                Text("Цена ⚛ \(node.cost)").font(.system(size: 12, weight: .semibold))
                Text((SpaceCenterLogic.researchBlock(tech, progress: progress) ?? "").capitalizedFirst)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(HUDStyle.accent)
            }
        }
    }
}

private extension String {
    /// Первая буква заглавная («нужна наука» → «Нужна наука»).
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Архив вех: достигнутые отмечены, у каждой — награда в науке.
struct MilestoneArchive: View {
    let progress: GameProgress
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Архив вех").font(.system(size: 17, weight: .heavy))
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).frame(width: 40, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть архив")
            }
            Text("Веха даёт науку один раз. Дальше наука — за данные приборов и экипажа, вернувшиеся на Терру.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HUDStyle.secondaryText)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Milestone.allCases, id: \.self) { milestone in
                        row(milestone)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 400)
        .frame(maxHeight: 300)
        .hudBackground(Color.black.opacity(0.9), corner: 14)
    }

    private func row(_ milestone: Milestone) -> some View {
        let done = progress.milestones.contains(milestone)
        return HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? HUDPalette.green : HUDStyle.secondaryText)
            Text(milestone.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(done ? Color.white : HUDStyle.secondaryText)
            Spacer(minLength: 0)
            Text("+⚛ \(milestone.science)")
                .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                .foregroundStyle(done ? HUDStyle.accent : HUDStyle.secondaryText)
        }
        .frame(minHeight: 30)
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "достигнута" : "не достигнута")
    }
}
