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
    @State private var attachment = 0
    @State private var undoStack: [VesselDesign] = []
    @State private var redoStack: [VesselDesign] = []
    @State private var renaming = false
    @State private var draftName = ""
    /// Пресет, ожидающий подтверждения замены проекта.
    @State private var pendingPreset: VesselDesign?
    /// Предложение урока «Первый полёт» при первом показе ангара.
    @State private var showTutorialOffer = false
    /// Список уроков (кнопка «Обучение»).
    @State private var showLessons = false

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
                                onSelect: { selected = $0; attachment = $0 + 1; feedbackTap() },
                                onUp: moveUp, onDown: moveDown, onDelete: delete,
                                attachment: attachment,
                                onAttachment: { attachment = $0; feedbackTap() }, onDrop: drop)
                    .frame(width: Self.stackWidth)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea())
        .onChange(of: design.parts, initial: true) {
            attachment = undoStack.isEmpty && selected == nil ? design.parts.count : min(attachment, design.parts.count)
            refreshScene()
        }
        .overlay { tutorialOffer }
        .overlay { lessonList }
        .onAppear {
            // Сцены отладки/CI (`-screen`) предложение не показывают.
            if !TutorialProgress.wasOffered, DemoScenario.fromArguments == nil { showTutorialOffer = true }
        }
        .onChange(of: selected) { refreshScene() }
        .onChange(of: attachment) { scene.markAttachment(attachment) }
        .alert("Название корабля", isPresented: $renaming) {
            TextField("Название", text: $draftName)
            Button("Сохранить") {
                let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    remember()
                    flow.design.name = String(name.prefix(40))
                }
            }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog(
            "Заменить текущий проект на «\(pendingPreset?.name ?? "")»?",
            isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }),
            titleVisibility: .visible
        ) {
            Button("Заменить", role: .destructive) {
                if let preset = pendingPreset { load(preset) }
                pendingPreset = nil
            }
            Button("Отмена", role: .cancel) { pendingPreset = nil }
        } message: {
            Text("Замену можно отменить стрелкой назад.")
        }
    }

    // MARK: - Верхняя полоса

    private func topBar(_ design: VesselDesign, stages: [StageInfo], blocked: Bool) -> some View {
        let totalDV = stages.reduce(0) { $0 + $1.deltaV }
        let twr = stages.first?.twr
        return HStack(spacing: 6) {
            Menu {
                ForEach(Array(VesselDesign.presets.enumerated()), id: \.offset) { _, preset in
                    Button(preset.name) { requestLoad(preset) }
                }
                Divider()
                Button("С нуля", role: .destructive) { requestLoad(HangarEditing.cleared) }
            } label: {
                HStack(spacing: 4) {
                    Text("Проект").font(.system(size: 14, weight: .bold))
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: HUDStyle.minTouch)
                .contentShape(Rectangle())
                .hudBackground(HUDStyle.control, corner: 10)
            }
            .accessibilityLabel("Новый корабль или готовый проект")

            Button { draftName = design.name; renaming = true } label: {
                Text(design.name)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Переименовать корабль")

            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(HUDButtonStyle()).disabled(undoStack.isEmpty)
                .accessibilityLabel("Отменить правку")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(HUDButtonStyle()).disabled(redoStack.isEmpty)
                .accessibilityLabel("Повторить правку")

            Button { showLessons = true } label: {
                Label("Обучение", systemImage: "graduationcap")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("Обучение: список уроков")

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
                    .frame(minWidth: 104, minHeight: 48)
            }
            .buttonStyle(HUDButtonStyle(isActive: !blocked))
            .opacity(blocked ? 0.55 : 1)
            .accessibilityHint(blocked ? "Сначала исправьте ошибки проекта" : "")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .hudBackground()
    }

    /// Список уроков: «Начать» — новый полёт по уроку.
    @ViewBuilder private var lessonList: some View {
        if showLessons {
            ZStack {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { showLessons = false }
                TutorialListPanel(context: .hangar,
                                  onStart: { id in
                                      showLessons = false
                                      flow.startTutorial(id)
                                  },
                                  onClose: { showLessons = false })
            }
        }
    }

    /// Карточка-предложение урока: «Начать» запускает урок, «Позже» прячет предложение; оба помечают его показанным.
    @ViewBuilder private var tutorialOffer: some View {
        if showTutorialOffer {
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 10) {
                    Text(TutorialID.firstFlight.title)
                        .font(.system(size: 20, weight: .heavy))
                    Text("Научим выходить на орбиту за 5 минут")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(HUDStyle.secondaryText)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        Button("Позже") {
                            TutorialProgress.markOffered()
                            showTutorialOffer = false
                        }
                        .buttonStyle(HUDButtonStyle())
                        Button("Начать") {
                            TutorialProgress.markOffered()
                            showTutorialOffer = false
                            flow.startTutorial(.firstFlight)
                        }
                        .buttonStyle(HUDButtonStyle(isActive: true))
                    }
                    .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(18)
                .frame(width: 340)
                .hudBackground(Color.black.opacity(0.85), corner: 18)
            }
        }
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
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text(flow.design.parts.isEmpty ? "СОБЕРИТЕ КОРАБЛЬ" : "КРЕПЛЕНИЕ \(attachment + 1)")
                    .font(.system(size: 11, weight: .heavy))
                Text(flow.design.parts.isEmpty ? "Капсула → бак → двигатель" : "Тап по детали · перенос из каталога · + между деталями")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(8)
            .hudBackground(Color.black.opacity(0.8), corner: 8)
            .padding(6)
            .allowsHitTesting(false)
            ZStack(alignment: .bottom) {
            GeometryReader { geo in
                HangarSceneView(scene: scene)
                HangarGestureLayer { scene.apply($0) }
                    .simultaneousGesture(SpatialTapGesture().onEnded { event in
                        if let index = scene.pickPart(at: event.location, viewSize: geo.size) {
                            selected = index
                            attachment = index + 1
                            feedbackTap()
                        }
                    })
                    .dropDestination(for: String.self) { items, location in
                        guard let item = items.first, items.count == 1 else { return false }
                        let index = scene.nearestAttachment(at: location, viewSize: geo.size)
                        return drop(item, at: index)
                    }
            }
            warnings(issues)
                .padding(6)
                .allowsHitTesting(false)
            }
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
        guard let index = VesselAssembly.insert(id, into: &parts, at: attachment) else { return }
        remember()
        flow.design.parts = parts
        selected = index
        attachment = index + 1
        feedbackTap()
    }

    private func moveUp() {
        guard let i = validSelection else { return }
        var parts = flow.design.parts
        guard let new = HangarEditing.moveUp(&parts, index: i) else { return }
        remember()
        flow.design.parts = parts
        selected = new
        attachment = new + 1
        feedbackTap()
    }

    private func moveDown() {
        guard let i = validSelection else { return }
        var parts = flow.design.parts
        guard let new = HangarEditing.moveDown(&parts, index: i) else { return }
        remember()
        flow.design.parts = parts
        selected = new
        attachment = new + 1
        feedbackTap()
    }

    private func delete() {
        guard let i = validSelection else { return }
        var parts = flow.design.parts
        let next = HangarEditing.remove(&parts, index: i)
        remember()
        flow.design.parts = parts
        selected = next
        attachment = min(i, parts.count)
        feedbackTap()
    }

    /// Спрашивает подтверждение, если текущий проект не пуст и отличается от нового.
    private func requestLoad(_ design: VesselDesign) {
        let current = flow.design.parts
        if current.isEmpty || current == design.parts {
            load(design)
        } else {
            pendingPreset = design
        }
    }

    private func load(_ design: VesselDesign) {
        remember()
        flow.design = design
        selected = nil
        attachment = design.parts.count
        if design.parts.isEmpty { tab = .pods }
        feedbackTap()
    }

    private func drop(_ item: String, at index: Int) -> Bool {
        var parts = flow.design.parts
        let newSelection: Int?
        if item.hasPrefix("part:"), let id = PartID(rawValue: String(item.dropFirst(5))) {
            newSelection = VesselAssembly.insert(id, into: &parts, at: index)
        } else if item.hasPrefix("move:"), let source = Int(item.dropFirst(5)) {
            newSelection = VesselAssembly.move(&parts, from: source, to: index)
        } else { return false }
        guard let newSelection else { return false }
        if parts != flow.design.parts {
            remember()
            flow.design.parts = parts
        }
        selected = newSelection
        attachment = newSelection + 1
        feedbackTap()
        return true
    }

    private func remember() {
        undoStack.append(flow.design)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(flow.design)
        flow.design = previous
        selected = nil
        attachment = previous.parts.count
        refreshScene()
        feedbackTap()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(flow.design)
        flow.design = next
        selected = nil
        attachment = next.parts.count
        refreshScene()
        feedbackTap()
    }

    private func refreshScene() {
        scene.show(parts: flow.design.parts, selected: validSelection)
        scene.markAttachment(attachment)
    }

    private func feedbackTap() {
        if settings.hapticsEnabled { UIFeedback.tap() }
    }

    private func feedbackWarning() {
        if settings.hapticsEnabled { UIFeedback.warning() }
    }
}
