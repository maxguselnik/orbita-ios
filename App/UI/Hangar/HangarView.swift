import OrbitPhysics
import SwiftUI

/// Сборочный цех: каталог слева, 3D-вид с корабле-деревом в центре, редактор ступеней справа,
/// сверху проекты и «Старт», снизу инструменты. Проект — `flow.design` (сохраняется сам).
/// Деталь берётся пальцем (с плитки каталога или с корабля) и ставится на ближайшую точку крепления.
struct HangarView: View {
    let flow: GameFlow
    let scene: HangarScene

    @State private var model: HangarModel
    @State private var tab: CatalogTab = .pods
    @State private var query = ""
    @State private var previewFrame: CGRect = .zero
    @State private var projects: [ShipStore.Entry] = []
    @State private var renaming = false
    @State private var draftName = ""
    @State private var showLessons = false
    @State private var showCrew = false
    @State private var confirmClear = false

    private static let catalogWidth: CGFloat = 158
    private static let stageWidth: CGFloat = 172

    init(flow: GameFlow, scene: HangarScene, settings: GameSettings) {
        self.flow = flow
        self.scene = scene
        _model = State(initialValue: HangarModel(
            scene: scene,
            design: { flow.design },
            setDesign: { flow.design = $0 },
            isUnlocked: { flow.isUnlocked($0) },
            feedback: { kind in
                guard settings.hapticsEnabled else { return }
                switch kind {
                case .tap: UIFeedback.tap()
                case .warning: UIFeedback.warning()
                }
            }))
    }

    var body: some View {
        VStack(spacing: 6) {
            topBar
            HStack(spacing: 6) {
                HangarCatalog(model: model, tab: $tab, query: $query,
                              onDragBegan: { part, point in model.beginDrag(.catalog(part), at: local(point)) },
                              onDragMoved: { model.moveDrag(to: local($0)) },
                              onDragEnded: { model.endDrag() })
                    .frame(width: Self.catalogWidth)
                viewport
                HangarStagePanel(model: model)
                    .frame(width: Self.stageWidth)
            }
            HangarToolbar(model: model, crewOpen: showCrew, onCrew: { showCrew.toggle() }, onLessons: { showLessons = true }, onClear: { confirmClear = true })
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea())
        .coordinateSpace(.named(hangarSpace))
        .overlay { lessonList }
        .overlay(alignment: .bottomTrailing) {
            if showCrew {
                HangarCrewPanel(model: model, onClose: { showCrew = false })
                    .frame(width: 330)
                    .padding(.trailing, Self.stageWidth + 14)
                    .padding(.bottom, 54)
            }
        }
        .onAppear {
            projects = ShipStore.list()
            model.designChanged()
            model.refreshScene()
        }
        .onChange(of: model.design, initial: true) { model.designChanged() }
        .alert("Название корабля", isPresented: $renaming) {
            TextField("Название", text: $draftName)
            Button("Сохранить") {
                let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { model.rename(String(name.prefix(40))) }
            }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Очистить проект?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { clearProject() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Очистку можно отменить стрелкой назад.")
        }
    }

    /// Точка экрана цеха → точка вида 3D.
    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - previewFrame.minX, y: point.y - previewFrame.minY)
    }

    // MARK: - Верхняя полоса

    private var topBar: some View {
        let design = model.design
        let locked = flow.lockedParts
        let blocked = model.report.issues.contains { $0.isBlocking }
        let canStart = locked.isEmpty && !blocked
        return HStack(spacing: 6) {
            Button { flow.open(.spaceCenter) } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .bold))
            }
            .buttonStyle(HUDButtonStyle())
            .accessibilityLabel("В космоцентр")

            projectsMenu

            Button { draftName = design.name; renaming = true } label: {
                Text(design.name)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minHeight: HUDStyle.minTouch)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Переименовать корабль")

            Spacer(minLength: 0)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(HUDButtonStyle()).disabled(model.undoStack.isEmpty)
                .accessibilityLabel("Отменить правку")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(HUDButtonStyle()).disabled(model.redoStack.isEmpty)
                .accessibilityLabel("Повторить правку")

            Button { start(locked: locked) } label: {
                Label("СТАРТ", systemImage: "play.fill")
                    .font(.system(size: 16, weight: .heavy))
                    .padding(.horizontal, 10)
                    .frame(minWidth: 100, minHeight: 44)
            }
            .buttonStyle(HUDButtonStyle(isActive: canStart))
            .opacity(canStart ? 1 : 0.55)
            .accessibilityHint(canStart ? "" : "Сначала исправьте ошибки проекта или откройте детали")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .hudBackground()
    }

    private func start(locked: [PartID]) {
        if !locked.isEmpty {
            let names = locked.prefix(3).map { $0.spec.name }.joined(separator: ", ")
            model.showToast("Закрыты детали: \(names). Откройте их в исследованиях")
        } else if let issue = model.report.issues.first(where: \.isBlocking) {
            model.showToast(issue.text)
        } else {
            flow.launch()
        }
    }

    // MARK: - Проекты

    private var projectsMenu: some View {
        Menu {
            Button("Новый", systemImage: "plus") { switchProject { flow.newShip() } }
            Button("Сохранить", systemImage: "square.and.arrow.down") {
                flow.saveShip()
                projects = ShipStore.list()
                model.showToast("Проект сохранён")
            }
            if !projects.isEmpty {
                Menu("Открыть", systemImage: "folder") {
                    ForEach(projects) { entry in
                        Button("\(entry.name) · \(entry.partCount)") { switchProject { flow.openShip(entry.id) } }
                    }
                }
            }
            Menu("Пресеты", systemImage: "square.stack.3d.up") {
                ForEach(Array(VesselDesign.presets.enumerated()), id: \.offset) { _, preset in
                    Button(preset.name) { switchProject { flow.design = preset; flow.shipID = nil } }
                }
                Button(VesselDesign.boosters.name) { switchProject { flow.design = VesselDesign.boosters; flow.shipID = nil } }
            }
            if !projects.isEmpty {
                Menu("Удалить", systemImage: "trash") {
                    ForEach(projects) { entry in
                        Button(entry.name, role: .destructive) { deleteProject(entry.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Проекты").font(.system(size: 14, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: HUDStyle.minTouch)
            .hudBackground(HUDStyle.control, corner: 10)
        }
        .accessibilityLabel("Проекты")
    }

    /// Текущий проект не теряется: непустой сохраняется в список перед заменой.
    private func switchProject(_ change: () -> Void) {
        if !flow.design.nodes.isEmpty { flow.saveShip() }
        change()
        model.resetHistory()
        projects = ShipStore.list()
    }

    private func deleteProject(_ id: String) {
        ShipStore.delete(id)
        if flow.shipID == id { flow.shipID = nil }
        projects = ShipStore.list()
    }

    private func clearProject() {
        var cleared = model.design
        cleared.nodes = []
        cleared.customStaging = false
        model.replaceDesign(cleared)
    }

    // MARK: - Вид

    private var viewport: some View {
        ZStack {
            HangarSceneView(scene: scene)
            HangarGestureLayer(model: model)
            HangarMarkerOverlay(model: model)
            hud
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: HUDStyle.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HUDStyle.corner, style: .continuous)
            .strokeBorder(HUDStyle.stroke, lineWidth: 1))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(hangarSpace)) } action: { previewFrame = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.viewSize = $0 }
    }

    /// Плашки поверх вида: сводка, выбранная деталь, карточка, гизмо, отчёт инженера, тост.
    private var hud: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    HangarStatStrip(model: model)
                    selectedChip
                    armedCard
                }
                Spacer(minLength: 0)
                GizmoPanel(model: model)
            }
            .padding(6)
            Spacer(minLength: 0)
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .hudBackground(Color.black.opacity(0.85), corner: 10)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if model.report.count == 0 {
                Text("Перетащите капсулу из каталога на вид")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
            }
            EngineerReportView(issues: model.report.issues)
                .padding(.bottom, 6)
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }

    @ViewBuilder private var selectedChip: some View {
        if let node = model.selectedNode {
            let spec = node.part.spec
            HStack(spacing: 6) {
                Text(spec.name).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                Text(HangarFormat.mass(spec.wetMass))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(HUDStyle.secondaryText)
                Button { model.deleteSelected() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                        .frame(width: 36, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Убрать деталь")
            }
            .foregroundStyle(.white)
            .padding(.leading, 10)
            .hudBackground(Color.black.opacity(0.7), corner: 10)
        }
    }

    @ViewBuilder private var armedCard: some View {
        if let part = model.armed {
            PartCardView(spec: part.spec,
                         lockedText: model.isUnlocked(part) ? nil : model.lockedText(part),
                         onClose: { model.arm(part) })
        }
    }

    // MARK: - Уроки

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
}
