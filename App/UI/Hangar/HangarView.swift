import OrbitPhysics
import SwiftUI

/// Ангар: каталог деталей слева, 3D-превью в центре, состав по ступеням справа, сверху пресеты, сводка и «Старт».
/// Проект — `flow.design` (сохраняется сам). Экран 852×393 pt, всё на одном экране.
struct HangarView: View {
    let flow: GameFlow
    let scene: HangarScene

    @Environment(GameSettings.self) private var settings
    @State private var selected: Int?
    @State private var tab: CatalogTab = .pods

    private static let catalogWidth: CGFloat = 216
    private static let stackWidth: CGFloat = 232
    private static let warning = Color(red: 1.0, green: 0.82, blue: 0.25)
    private static let danger = Color(red: 1.0, green: 0.4, blue: 0.35)

    var body: some View {
        let design = flow.design
        let stages = design.stageInfos()
        let issues = design.issues()
        let blocked = issues.contains { $0.isBlocking }

        VStack(spacing: 8) {
            topBar(design, stages: stages, blocked: blocked)

            HStack(spacing: 8) {
                HangarCatalog(tab: $tab, isFull: design.parts.count >= VesselDesign.maxParts, onAdd: add)
                    .frame(width: Self.catalogWidth)

                preview(issues: issues)

                HangarStackList(parts: design.parts, stages: stages, selected: validSelection,
                                onSelect: { selected = $0; feedbackTap() },
                                onUp: moveUp, onDown: moveDown, onDelete: delete)
                    .frame(width: Self.stackWidth)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea())
        .onChange(of: design.parts, initial: true) { refreshScene() }
        .onChange(of: selected) { refreshScene() }
    }

    // MARK: - Верхняя полоса

    private func topBar(_ design: VesselDesign, stages: [StageInfo], blocked: Bool) -> some View {
        let totalDV = stages.reduce(0) { $0 + $1.deltaV }
        let twr = stages.first?.twr
        return HStack(spacing: 10) {
            Menu {
                ForEach(Array(VesselDesign.presets.enumerated()), id: \.offset) { _, preset in
                    Button(preset.name) { load(preset) }
                }
                Divider()
                Button("Очистить", role: .destructive) { load(HangarEditing.cleared) }
            } label: {
                HStack(spacing: 4) {
                    Text("Пресеты").font(.system(size: 14, weight: .bold))
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: HUDStyle.minTouch)
                .contentShape(Rectangle())
                .hudBackground(HUDStyle.control, corner: 10)
            }
            .accessibilityLabel("Пресеты")

            Text(design.name)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                metric("Δv", HUDFormat.speed(totalDV))
                metric("TWR", twr.map(HUDFormat.twr) ?? HUDFormat.dash,
                       color: (twr ?? 1) < 1 ? Self.warning : .white)
                metric("Масса", HangarFormat.mass(design.mass))
            }

            Button {
                if blocked {
                    feedbackWarning()
                } else {
                    flow.launch()
                }
            } label: {
                Label("СТАРТ", systemImage: "play.fill")
                    .font(.system(size: 17, weight: .heavy))
                    .padding(.horizontal, 12)
                    .frame(minWidth: 130, minHeight: 54)
            }
            .buttonStyle(HUDButtonStyle(isActive: !blocked))
            .opacity(blocked ? 0.55 : 1)
            .accessibilityHint(blocked ? "Сначала исправьте ошибки проекта" : "")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .hudBackground()
    }

    private func metric(_ label: String, _ value: String, color: Color = .white) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(HUDStyle.secondaryText)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Центр: превью и предупреждения

    private func preview(issues: [DesignIssue]) -> some View {
        ZStack(alignment: .bottom) {
            HangarSceneView(scene: scene)
            HangarGestureLayer { scene.apply($0) }
            warnings(issues)
                .padding(6)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: HUDStyle.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HUDStyle.corner, style: .continuous)
            .strokeBorder(HUDStyle.stroke, lineWidth: 1))
    }

    /// До двух строк: блокирующие (красные) первыми, остальные — жёлтые.
    @ViewBuilder
    private func warnings(_ issues: [DesignIssue]) -> some View {
        let sorted = issues.filter(\.isBlocking) + issues.filter { !$0.isBlocking }
        let shown = Array(sorted.prefix(2))
        let extra = sorted.count - shown.count
        VStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, issue in
                let color = issue.isBlocking ? Self.danger : Self.warning
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(issue.text + (index == shown.count - 1 && extra > 0 ? " (+\(extra))" : ""))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .hudBackground(Color.black.opacity(0.72), corner: 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel((issue.isBlocking ? "Ошибка: " : "Предупреждение: ") + issue.text)
            }
        }
    }

    // MARK: - Правки

    /// Выделение, приведённое к текущему размеру стека.
    private var validSelection: Int? {
        guard let selected, flow.design.parts.indices.contains(selected) else { return nil }
        return selected
    }

    private func add(_ id: PartID) {
        var parts = flow.design.parts
        guard let index = HangarEditing.add(id, to: &parts, selected: validSelection) else { return }
        flow.design.parts = parts
        selected = index
        feedbackTap()
    }

    private func moveUp() {
        guard let i = validSelection else { return }
        var parts = flow.design.parts
        guard let new = HangarEditing.moveUp(&parts, index: i) else { return }
        flow.design.parts = parts
        selected = new
        feedbackTap()
    }

    private func moveDown() {
        guard let i = validSelection else { return }
        var parts = flow.design.parts
        guard let new = HangarEditing.moveDown(&parts, index: i) else { return }
        flow.design.parts = parts
        selected = new
        feedbackTap()
    }

    private func delete() {
        guard let i = validSelection else { return }
        var parts = flow.design.parts
        HangarEditing.remove(&parts, index: i)
        flow.design.parts = parts
        selected = nil
        feedbackTap()
    }

    private func load(_ design: VesselDesign) {
        flow.design = design
        selected = nil
        feedbackTap()
    }

    private func refreshScene() {
        scene.show(parts: flow.design.parts, selected: validSelection)
    }

    private func feedbackTap() {
        if settings.hapticsEnabled { UIFeedback.tap() }
    }

    private func feedbackWarning() {
        if settings.hapticsEnabled { UIFeedback.warning() }
    }
}
