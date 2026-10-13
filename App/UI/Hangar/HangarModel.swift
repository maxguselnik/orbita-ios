import CoreGraphics
import Foundation
import Observation
import OrbitPhysics

/// Состояние и правки сборочного цеха: выделение, инструменты, симметрия, отмена, перетаскивание, гизмо.
/// Проект живёт снаружи (`GameFlow.design`) — модель читает и пишет его через замыкания, сцену обновляет сама.
@MainActor
@Observable
final class HangarModel {
    enum Tool: CaseIterable, Identifiable {
        case attach, offset, rotate, root

        var id: Self { self }

        var title: String {
            switch self {
            case .attach: "Крепить"
            case .offset: "Сдвиг"
            case .rotate: "Поворот"
            case .root: "Корень"
            }
        }

        var icon: String {
            switch self {
            case .attach: "plus.circle"
            case .offset: "arrow.up.and.down.and.arrow.left.and.right"
            case .rotate: "arrow.triangle.2.circlepath"
            case .root: "house"
            }
        }
    }

    enum SymmetryKind: CaseIterable {
        case radial, mirror

        var title: String { self == .radial ? "Радиальная" : "Зеркальная" }
    }

    enum Feedback { case tap, warning }

    /// Что под пальцем в момент касания вида.
    enum Touch: Equatable {
        case camera
        case part(Int)
        case gizmo(Int)
    }

    /// Для интерфейса во время перетаскивания.
    struct DragInfo: Equatable {
        enum Verdict { case none, valid, invalid }
        var part: PartID
        var isDeleting: Bool
        var verdict: Verdict
    }

    /// Расчёты по проекту: пересчитываются только при правках.
    struct Report {
        var infos: [StageInfo] = []
        var issues: [DesignIssue] = []
        var rows: [HangarStageRow] = []
        var markers: DesignMarkers?
        var totalDV = 0.0
        var twr: Double?
        var mass = 0.0
        var count = 0
    }

    static let undoLimit = 40

    @ObservationIgnored private let readDesign: @MainActor () -> VesselDesign
    @ObservationIgnored private let writeDesign: @MainActor (VesselDesign) -> Void
    @ObservationIgnored private let unlocked: @MainActor (PartID) -> Bool
    @ObservationIgnored private let feedback: @MainActor (Feedback) -> Void
    @ObservationIgnored let scene: any HangarPreview
    @ObservationIgnored private var drag: HangarDragModel?
    @ObservationIgnored private var gizmo: GizmoSession?
    @ObservationIgnored private var lastDesign: VesselDesign?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?

    /// Размер вида 3D (pt), выставляет интерфейс.
    var viewSize = CGSize(width: 400, height: 240)
    private(set) var selectedID: Int?
    private(set) var tool: Tool = .attach
    private(set) var symmetryKind: SymmetryKind = .radial
    private(set) var symmetryCount = 1
    /// Шаг 15° и 0.1 м; false — плавно.
    private(set) var fineStep = true
    /// Деталь выбрана в каталоге: точки крепления поверх 3D (запасной путь).
    private(set) var armed: PartID?
    private(set) var armedTargets: [AttachTarget] = []
    private(set) var environment: HangarEnvironment = .terra
    var showCOM = true
    var showCOT = true
    var showCOP = true
    private(set) var report = Report()
    private(set) var toast: String?
    private(set) var dragInfo: DragInfo?
    private(set) var highlighted: Int?
    private(set) var undoStack: [VesselDesign] = []
    private(set) var redoStack: [VesselDesign] = []

    init(scene: any HangarPreview, design: @escaping @MainActor () -> VesselDesign,
         setDesign: @escaping @MainActor (VesselDesign) -> Void,
         isUnlocked: @escaping @MainActor (PartID) -> Bool = { _ in true },
         feedback: @escaping @MainActor (Feedback) -> Void = { _ in }) {
        self.scene = scene
        readDesign = design
        writeDesign = setDesign
        unlocked = isUnlocked
        self.feedback = feedback
        recompute()
        refreshScene()
    }

    // MARK: - Чтение

    var design: VesselDesign { readDesign() }

    var selectedNode: DesignPart? { selectedID.flatMap { design.node($0) } }

    /// Выделенные детали: выбранная и её копии симметрии.
    var selection: Set<Int> {
        guard let id = selectedID, let node = design.node(id) else { return [] }
        if let group = node.symmetryGroup {
            return Set(design.nodes.filter { $0.symmetryGroup == group }.map(\.id))
        }
        return [id]
    }

    /// Число копий при креплении сбоку.
    var effectiveSymmetry: Int { symmetryKind == .mirror ? 2 : symmetryCount }
    var effectiveMirror: Bool { symmetryKind == .mirror }

    var isDragging: Bool { drag != nil }

    /// Точки крепления, к которым сейчас можно притянуть деталь «в руке» (для оверлея), и выбранная.
    var dragCandidatePositions: [Vec3] { drag?.candidateTargets.map(\.position) ?? [] }
    var dragSnapPosition: Vec3? { drag?.snap?.target.position }

    func isUnlocked(_ part: PartID) -> Bool { unlocked(part) }

    // MARK: - Настройки

    func setTool(_ new: Tool) {
        tool = new
        feedback(.tap)
        refreshScene()
    }

    func setSymmetry(kind: SymmetryKind) {
        symmetryKind = kind
        recomputeArmed()
    }

    func setSymmetry(count: Int) {
        symmetryCount = max(1, min(4, count))
        recomputeArmed()
    }

    func toggleStep() { fineStep.toggle() }

    func setEnvironment(_ new: HangarEnvironment) {
        environment = new
        recompute()
    }

    /// Выбор в каталоге: нажатие на выбранную деталь снимает выбор.
    func arm(_ part: PartID?) {
        armed = (armed == part) ? nil : part
        recomputeArmed()
        feedback(.tap)
    }

    func select(_ id: Int?) {
        selectedID = id
        refreshScene()
    }

    // MARK: - Пересчёт

    /// Проект изменился (снаружи или правкой): пересчитать отчёт, точки, сцену.
    func designChanged() {
        let current = design
        guard current != lastDesign else { return }
        if let id = selectedID, current.node(id) == nil { selectedID = nil }
        recompute()
        recomputeArmed()
        refreshScene()
    }

    private func recompute() {
        let d = design
        lastDesign = d
        let infos = d.stageInfos(pressure: environment.pressure, gravity: environment.gravity)
        var r = Report()
        r.infos = infos
        r.issues = d.issues()
        r.rows = StageEditing.rows(design: d, infos: infos)
        r.markers = d.nodes.isEmpty ? nil : d.markers()
        r.totalDV = infos.reduce(0) { $0 + $1.deltaV }
        r.twr = infos.first?.twr
        r.mass = d.mass
        r.count = d.nodes.count
        report = r
    }

    private func recomputeArmed() {
        if let armed {
            armedTargets = VesselEditing.attachTargets(for: armed, symmetry: effectiveSymmetry, in: design)
        } else {
            armedTargets = []
        }
    }

    // MARK: - Сцена

    func refreshScene() {
        if let drag {
            scene.show(design: drag.sceneDesign, selected: [], ghost: drag.ghost)
            scene.showFloating(drag.showsFloating ? drag.part : nil, at: drag.finger, viewSize: viewSize)
        } else {
            var shown = selection
            if let highlighted { shown.insert(highlighted) }
            scene.show(design: design, selected: shown, ghost: nil)
            scene.showFloating(nil, at: .zero, viewSize: viewSize)
        }
        updateGizmo()
    }

    private func updateGizmo() {
        guard drag == nil, let id = selectedID, design.node(id) != nil else {
            scene.showGizmo(nil)
            return
        }
        switch tool {
        case .rotate: scene.showGizmo(.rotate(id))
        case .offset: scene.showGizmo(.offset(id))
        case .attach, .root: scene.showGizmo(nil)
        }
    }

    /// Деталь корабля подсветить на 1.5 с (тап по значку в редакторе ступеней).
    func highlight(_ id: Int) {
        highlighted = id
        refreshScene()
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            highlighted = nil
            refreshScene()
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, let self else { return }
            toast = nil
        }
    }

    // MARK: - Правки

    /// Записать проект и запомнить прежний для отмены.
    private func commit(_ new: VesselDesign) {
        let old = design
        guard new != old else { return }
        undoStack.append(old)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        writeDesign(new)
        designChanged()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(design)
        writeDesign(previous)
        designChanged()
        feedback(.tap)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(design)
        writeDesign(next)
        designChanged()
        feedback(.tap)
    }

    /// Новый проект загружен снаружи: история и выделение сбрасываются.
    func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        selectedID = nil
        armed = nil
        designChanged()
        recomputeArmed()
        refreshScene()
    }

    func lockedText(_ part: PartID) -> String {
        let tech = TechTree.node(TechTree.tech(for: part))
        return "Закрыто: откроется в «\(tech.title)»"
    }

    /// Поставить деталь в точку крепления (запасной путь и общий итог перетаскивания).
    @discardableResult
    func place(_ part: PartID, at target: AttachTarget) -> Bool {
        guard unlocked(part) else {
            showToast(lockedText(part))
            feedback(.warning)
            return false
        }
        var d = design
        let ids = VesselEditing.attach(part, to: target, symmetry: effectiveSymmetry, mirror: effectiveMirror, in: &d)
        guard !ids.isEmpty else {
            showToast(d.nodes.count >= VesselDesign.maxParts ? "Лимит: \(VesselDesign.maxParts) деталей" : "Сюда нельзя")
            feedback(.warning)
            return false
        }
        commit(d)
        selectedID = ids.first
        feedback(.tap)
        refreshScene()
        return true
    }

    func rename(_ name: String) {
        var d = design
        d.name = name
        commit(d)
    }

    /// Заменить проект целиком (очистка) с шагом отмены.
    func replaceDesign(_ new: VesselDesign) {
        selectedID = nil
        commit(new)
        refreshScene()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        var d = design
        let removed = VesselEditing.remove(id, in: &d)
        guard !removed.isEmpty else { return }
        selectedID = nil
        commit(d)
        feedback(.tap)
        refreshScene()
    }

    func makeRoot(_ id: Int) {
        var d = design
        if VesselEditing.setRoot(id, in: &d) {
            commit(d)
            selectedID = id
            feedback(.tap)
        } else {
            showToast("Нельзя: деталь на боку")
            feedback(.warning)
        }
        refreshScene()
    }

    func dropStage(_ drop: StageEditing.Drop, partID: Int) {
        var d = design
        if StageEditing.apply(drop, id: partID, to: &d) {
            commit(d)
            feedback(.tap)
        }
    }

    func resetStaging() {
        var d = design
        VesselEditing.resetStaging(in: &d)
        commit(d)
        feedback(.tap)
    }

    // MARK: - Касания вида

    func classify(_ point: CGPoint) -> Touch {
        if drag != nil { return .camera }
        if tool == .rotate || tool == .offset, selectedID != nil,
           let axis = scene.pickGizmoAxis(at: point, viewSize: viewSize) {
            return .gizmo(axis)
        }
        if let id = scene.pickPart(at: point, viewSize: viewSize) { return .part(id) }
        return .camera
    }

    /// Тап без перетаскивания: точка крепления выбранной детали каталога, деталь корабля или пустое место.
    func tap(at point: CGPoint) {
        if let armed, let target = nearestArmedTarget(to: point, within: 30) {
            place(armed, at: target)
            return
        }
        if let id = scene.pickPart(at: point, viewSize: viewSize) {
            if tool == .root {
                makeRoot(id)
            } else {
                selectedID = id
                feedback(.tap)
                refreshScene()
            }
        } else if selectedID != nil {
            selectedID = nil
            refreshScene()
        }
    }

    private func nearestArmedTarget(to point: CGPoint, within radius: CGFloat) -> AttachTarget? {
        var best: AttachTarget?
        var bestDistance = radius
        for target in armedTargets {
            guard let p = scene.project(target.position, viewSize: viewSize) else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= bestDistance {
                best = target
                bestDistance = d
            }
        }
        return best
    }

    func doubleTap(at point: CGPoint) {
        if tool == .rotate || tool == .offset, selectedID != nil,
           scene.pickGizmoAxis(at: point, viewSize: viewSize) != nil {
            resetGizmo()
        } else {
            scene.apply(CameraInput(reset: true))
        }
    }

    // MARK: - Перетаскивание детали

    /// Начать перетаскивание; `point` — в координатах вида 3D.
    func beginDrag(_ source: HangarDragModel.Source, at point: CGPoint) {
        var isOpen = true
        if case .catalog(let part) = source {
            isOpen = unlocked(part)
            guard isOpen else {
                showToast(lockedText(part))
                feedback(.warning)
                return
            }
        }
        if case .vessel(let id) = source { selectedID = id }
        let scene = scene
        let size = viewSize
        drag = HangarDragModel(source: source, design: design, symmetry: effectiveSymmetry, mirror: effectiveMirror,
                               isUnlocked: isOpen, at: point, project: { scene.project($0, viewSize: size) })
        publishDrag()
        refreshScene()
    }

    func moveDrag(to point: CGPoint) {
        guard var d = drag else { return }
        let outside = point.x < 0 || point.x > viewSize.width || point.y < 0 || point.y > viewSize.height
        let changed = d.update(to: point, overCatalog: point.x < 0, outside: outside)
        drag = d
        if changed {
            if d.snap != nil { feedback(.tap) }
            scene.show(design: d.sceneDesign, selected: [], ghost: d.ghost)
            publishDrag()
        }
        scene.showFloating(d.showsFloating ? d.part : nil, at: point, viewSize: viewSize)
        let deleting = DragInfo(part: d.part, isDeleting: d.isDeleting, verdict: verdict(d))
        if dragInfo != deleting { dragInfo = deleting }
    }

    func endDrag() {
        guard let d = drag else { return }
        drag = nil
        dragInfo = nil
        switch d.finish() {
        case .attach(let new, let ids):
            commit(new)
            selectedID = ids.first
            feedback(.tap)
        case .move(let new, let id):
            commit(new)
            selectedID = id
            feedback(.tap)
        case .remove(let id):
            var edited = design
            let removed = VesselEditing.remove(id, in: &edited)
            if !removed.isEmpty {
                selectedID = nil
                commit(edited)
                feedback(.tap)
            }
        case .cancel:
            if d.snap != nil { feedback(.warning) }
        }
        refreshScene()
    }

    func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
        dragInfo = nil
        refreshScene()
    }

    private func verdict(_ d: HangarDragModel) -> DragInfo.Verdict {
        guard let snap = d.snap else { return .none }
        return snap.valid ? .valid : .invalid
    }

    private func publishDrag() {
        guard let d = drag else { return }
        let info = DragInfo(part: d.part, isDeleting: d.isDeleting, verdict: verdict(d))
        if dragInfo != info { dragInfo = info }
    }

    // MARK: - Гизмо

    private struct GizmoSession {
        var id: Int
        var axis: Int
        var rotate: Bool
        var startDesign: VesselDesign
        var startValue: Double
        var start: CGPoint
        var last: CGPoint
        var center: CGPoint
        var accumulated = 0.0
        var sign = 1.0
        var direction = CGVector(dx: 1, dy: 0)
        var pointsPerMeter = 1.0
    }

    func beginGizmo(axis: Int, at point: CGPoint) {
        guard let id = selectedID, let node = design.node(id), let index = design.index(of: id) else { return }
        let layout = design.layout()
        guard layout.indices.contains(index) else { return }
        let c3 = layout[index].center
        let center = scene.project(c3, viewSize: viewSize) ?? point
        let rotate = tool == .rotate
        var s = GizmoSession(id: id, axis: axis, rotate: rotate, startDesign: design,
                             startValue: HangarGizmoMath.component(rotate ? node.rotation : node.offset, axis),
                             start: point, last: point, center: center)
        if rotate {
            let (u, v) = HangarGizmoMath.ringAxes(axis)
            let su = scene.screenDirection(of: HangarGizmoMath.axis(u), at: c3, viewSize: viewSize)
            let sv = scene.screenDirection(of: HangarGizmoMath.axis(v), at: c3, viewSize: viewSize)
            s.sign = HangarGizmoMath.handedness(first: su, second: sv)
        } else {
            s.direction = scene.screenDirection(of: HangarGizmoMath.axis(axis), at: c3, viewSize: viewSize)
            let tip = Vec3(c3.x + HangarGizmoMath.axis(axis).x, c3.y + HangarGizmoMath.axis(axis).y,
                           c3.z + HangarGizmoMath.axis(axis).z)
            if let a = scene.project(c3, viewSize: viewSize), let b = scene.project(tip, viewSize: viewSize) {
                s.pointsPerMeter = Double(hypot(b.x - a.x, b.y - a.y))
            }
        }
        gizmo = s
    }

    func moveGizmo(to point: CGPoint) {
        guard var s = gizmo else { return }
        let step = fineStep
        if s.rotate {
            s.accumulated += s.sign * HangarGizmoMath.angleDelta(center: s.center, from: s.last, to: point)
            s.last = point
            let value = HangarGizmoMath.wrapped(s.startValue + s.accumulated)
            apply(HangarGizmoMath.snapped(value, step: step ? HangarGizmoMath.angleStep : nil), to: s)
        } else {
            let delta = CGSize(width: point.x - s.start.x, height: point.y - s.start.y)
            let meters = HangarGizmoMath.offsetMeters(translation: delta, direction: s.direction,
                                                      pointsPerMeter: s.pointsPerMeter)
            apply(HangarGizmoMath.snapped(s.startValue + meters, step: step ? HangarGizmoMath.offsetStep : nil), to: s)
        }
        gizmo = s
    }

    func endGizmo() {
        guard let s = gizmo else { return }
        gizmo = nil
        if design != s.startDesign {
            undoStack.append(s.startDesign)
            if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
            redoStack.removeAll()
        }
    }

    /// Записать компоненту вращения или сдвига (без шага отмены — он ставится в `endGizmo`).
    private func apply(_ value: Double, to s: GizmoSession) {
        guard let node = design.node(s.id) else { return }
        var d = design
        if s.rotate {
            VesselEditing.setRotation(s.id, HangarGizmoMath.setting(node.rotation, s.axis, to: value), in: &d)
        } else {
            VesselEditing.setOffset(s.id, HangarGizmoMath.setting(node.offset, s.axis, to: value), in: &d)
        }
        guard d != design else { return }
        writeDesign(d)
        designChanged()
    }

    /// Кнопки ± на панели: шаг 15° (или 1° плавно) и 0.1 м (или 0.02 м).
    func nudge(axis: Int, by direction: Double) {
        guard let id = selectedID, let node = design.node(id) else { return }
        var d = design
        if tool == .rotate {
            let step = fineStep ? HangarGizmoMath.angleStep : 1
            let value = HangarGizmoMath.wrapped(HangarGizmoMath.component(node.rotation, axis) + direction * step)
            VesselEditing.setRotation(id, HangarGizmoMath.setting(node.rotation, axis, to: value), in: &d)
        } else {
            let step = fineStep ? HangarGizmoMath.offsetStep : 0.02
            let value = HangarGizmoMath.component(node.offset, axis) + direction * step
            VesselEditing.setOffset(id, HangarGizmoMath.setting(node.offset, axis, to: value), in: &d)
        }
        commit(d)
    }

    /// «Сбросить»: поворот или сдвиг выбранной детали в ноль.
    func resetGizmo() {
        guard let id = selectedID else { return }
        var d = design
        if tool == .rotate {
            VesselEditing.setRotation(id, Vec3(0, 0, 0), in: &d)
        } else {
            VesselEditing.setOffset(id, Vec3(0, 0, 0), in: &d)
        }
        commit(d)
        feedback(.tap)
    }
}
