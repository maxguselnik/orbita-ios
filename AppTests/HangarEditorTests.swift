import CoreGraphics
import OrbitPhysics
import Testing
@testable import Orbita

/// Фиктивная сцена цеха: запоминает вызовы, проекция — плоская (100 pt на метр, начало в (200, 300)).
@MainActor
final class FakeHangarScene: HangarPreview {
    var shown: [VesselDesign] = []
    var ghosts: [HangarGhost?] = []
    var floating: [PartID?] = []
    var gizmo: HangarGizmo?
    var pickedPart: Int?
    var gizmoAxis: Int?

    nonisolated static func plane(_ p: Vec3) -> CGPoint { CGPoint(x: 200 + p.x * 100, y: 300 - p.y * 100) }

    func show(design: VesselDesign, selected: Set<Int>, ghost: HangarGhost?) {
        shown.append(design)
        ghosts.append(ghost)
    }

    func showFloating(_ part: PartID?, at point: CGPoint, viewSize: CGSize) { floating.append(part) }
    func showGizmo(_ gizmo: HangarGizmo?) { self.gizmo = gizmo }
    func gizmoFrame() -> (origin: Vec3, axes: [Vec3])? { nil }
    func pickGizmoAxis(at point: CGPoint, viewSize: CGSize) -> Int? { gizmoAxis }
    func apply(_ camera: CameraInput) {}
    func project(_ point: Vec3, viewSize: CGSize) -> CGPoint? { Self.plane(point) }
    func screenDirection(of axis: Vec3, at point: Vec3, viewSize: CGSize) -> CGVector { CGVector(dx: 1, dy: 0) }
    func pickPart(at point: CGPoint, viewSize: CGSize) -> Int? { pickedPart }
}

@MainActor
@Suite("Цех: перетаскивание, ступени, гизмо")
struct HangarEditorTests {
    private let stack = VesselDesign(name: "Стек", parts: [.podK1, .t200, .molot])

    private func drag(_ source: HangarDragModel.Source, in design: VesselDesign, finger: CGPoint = .zero,
                      unlocked: Bool = true) -> HangarDragModel {
        HangarDragModel(source: source, design: design, symmetry: 1, mirror: false, isUnlocked: unlocked,
                        at: finger, project: FakeHangarScene.plane)
    }

    @Test func fingerOnTargetSnapsAndAttaches() {
        var model = drag(.catalog(.t100), in: stack)
        let target = model.candidateTargets.first
        #expect(target != nil)
        guard let target else { return }
        let changed = model.update(to: FakeHangarScene.plane(target.position), overCatalog: false)
        #expect(changed)
        #expect(model.snap?.valid == true)
        #expect(model.ghost?.valid == true)
        #expect(!model.showsFloating)
        guard case .attach(let result, let ids) = model.finish() else {
            Issue.record("ожидалось крепление")
            return
        }
        #expect(result.nodes.count == stack.nodes.count + 1)
        #expect(ids.count == 1 && result.node(ids[0]) != nil)
    }

    @Test func farFingerHasNoTargetAndCancels() {
        var model = drag(.catalog(.t100), in: stack)
        model.update(to: CGPoint(x: 2000, y: 2000), overCatalog: false)
        #expect(model.snap == nil)
        #expect(model.ghost == nil)
        #expect(model.showsFloating)
        #expect(model.finish() == .cancel)
    }

    @Test func snapRadiusIsForty() {
        var model = drag(.catalog(.t100), in: stack)
        guard let target = model.candidateTargets.first else {
            Issue.record("нет целей")
            return
        }
        let p = FakeHangarScene.plane(target.position)
        model.update(to: CGPoint(x: p.x - 3000, y: p.y), overCatalog: false)
        #expect(model.snap == nil)
        model.update(to: CGPoint(x: p.x, y: p.y), overCatalog: false)
        #expect(model.snap != nil)
        // Палец вышел за вид — цели нет.
        model.update(to: p, overCatalog: false, outside: true)
        #expect(model.snap == nil)
    }

    @Test func closedPartGetsRedGhostAndCannotBeDropped() {
        var model = drag(.catalog(.t100), in: stack, unlocked: false)
        guard let target = model.candidateTargets.first else {
            Issue.record("нет целей")
            return
        }
        model.update(to: FakeHangarScene.plane(target.position), overCatalog: false)
        #expect(model.snap?.valid == false)
        #expect(model.ghost?.valid == false)
        #expect(model.finish() == .cancel)
    }

    @Test func vesselPartDroppedOverCatalogIsRemoved() {
        let id = stack.nodes[1].id
        var model = drag(.vessel(id), in: stack)
        model.update(to: CGPoint(x: -20, y: 100), overCatalog: true)
        #expect(model.isDeleting)
        #expect(model.finish() == .remove(id))
    }

    @Test func movedSubtreeIsNotATarget() {
        let rootID = stack.root?.id ?? 0
        let subtree = HangarDragModel.subtree(of: rootID, in: stack)
        #expect(subtree.count == stack.nodes.count)
        let model = drag(.vessel(rootID), in: stack)
        #expect(model.candidateTargets.allSatisfy { target in target.parent.map { !subtree.contains($0) } ?? true })
    }

    @Test func subtreeContainsOnlyDescendants() {
        // Линейный стек сверху вниз: у последней детали потомков нет.
        let last = stack.nodes[stack.nodes.count - 1].id
        #expect(HangarDragModel.subtree(of: last, in: stack) == [last])
    }

    // MARK: - Модель цеха

    private final class Holder {
        var design: VesselDesign
        init(_ d: VesselDesign) { design = d }
    }

    private func makeModel(_ holder: Holder, scene: FakeHangarScene) -> HangarModel {
        HangarModel(scene: scene, design: { holder.design }, setDesign: { holder.design = $0 })
    }

    @Test func dragFromCatalogCommitsAndUndoRestores() {
        let holder = Holder(stack)
        let scene = FakeHangarScene()
        let model = makeModel(holder, scene: scene)
        model.viewSize = CGSize(width: 2000, height: 2000)
        model.beginDrag(.catalog(.t100), at: .zero)
        #expect(model.isDragging)
        // Самая нижняя цель: её проекция внутри вида (у верхних y < 0 — палец вне вида, перетаскивание отменяется).
        guard let position = model.dragCandidatePositions.min(by: { $0.y < $1.y }) else {
            Issue.record("нет целей")
            return
        }
        model.moveDrag(to: FakeHangarScene.plane(position))
        #expect(scene.ghosts.last??.valid == true)
        model.endDrag()
        #expect(!model.isDragging)
        #expect(holder.design.nodes.count == stack.nodes.count + 1)
        #expect(model.undoStack.count == 1)
        model.undo()
        #expect(holder.design == stack)
        model.redo()
        #expect(holder.design.nodes.count == stack.nodes.count + 1)
    }

    @Test func cancelledDragKeepsDesign() {
        let holder = Holder(stack)
        let model = makeModel(holder, scene: FakeHangarScene())
        model.beginDrag(.catalog(.t100), at: .zero)
        model.moveDrag(to: CGPoint(x: 3000, y: 3000))
        model.endDrag()
        #expect(holder.design == stack)
        #expect(model.undoStack.isEmpty)
    }

    @Test func lockedCatalogPartIsNotPickedUp() {
        let holder = Holder(stack)
        let model = HangarModel(scene: FakeHangarScene(), design: { holder.design }, setDesign: { holder.design = $0 },
                                isUnlocked: { $0 != .titan })
        model.beginDrag(.catalog(.titan), at: .zero)
        #expect(!model.isDragging)
        #expect(model.toast != nil)
    }

    @Test func toolSwitchShowsGizmoForSelection() {
        let holder = Holder(stack)
        let scene = FakeHangarScene()
        let model = makeModel(holder, scene: scene)
        let id = stack.nodes[1].id
        model.select(id)
        model.setTool(.rotate)
        #expect(scene.gizmo == .rotate(id))
        model.setTool(.offset)
        #expect(scene.gizmo == .offset(id))
        model.setTool(.attach)
        #expect(scene.gizmo == nil)
    }

    @Test func deleteSelectedRemovesPartWithUndo() {
        let holder = Holder(stack)
        let model = makeModel(holder, scene: FakeHangarScene())
        let last = stack.nodes[stack.nodes.count - 1].id
        model.select(last)
        model.deleteSelected()
        #expect(holder.design.node(last) == nil)
        #expect(model.selectedID == nil)
        model.undo()
        #expect(holder.design == stack)
    }

    // MARK: - Ступени и гизмо

    @Test func stageRowsFollowStageGroups() {
        let infos = stack.stageInfos()
        let rows = StageEditing.rows(design: stack, infos: infos)
        #expect(rows.count == stack.stageGroups.count)
        #expect(rows.map(\.stage) == Array(rows.indices))
        #expect(rows.first?.number == 1)
    }

    @Test func stageDragItemRoundTrips() {
        #expect(StageEditing.parse(StageEditing.dragItem(7)) == 7)
        #expect(StageEditing.parse("part:t100") == nil)
    }

    @Test func dropOnNewStageAddsStage() {
        var design = VesselDesign.orbit
        let before = design.stageGroups.count
        guard let engine = design.nodes.first(where: { $0.part.spec.kind == .engine }) else {
            Issue.record("нет двигателя")
            return
        }
        StageEditing.apply(.newLast, id: engine.id, to: &design)
        #expect(design.customStaging)
        #expect(design.stageGroups.count >= before - 1)
        #expect(design.stageGroups.last?.contains(engine.id) == true)
    }

    @Test func gizmoMathWrapsAndSnaps() {
        #expect(HangarGizmoMath.wrapped(190) == -170)
        #expect(HangarGizmoMath.wrapped(-190) == 170)
        #expect(HangarGizmoMath.wrapped(180) == 180)
        #expect(HangarGizmoMath.snapped(22, step: 15) == 15)
        #expect(HangarGizmoMath.snapped(23, step: 15) == 30)
        #expect(HangarGizmoMath.snapped(22.4, step: nil) == 22.4)
        #expect(HangarGizmoMath.snapped(0.26, step: 0.1) == 0.3)
    }

    @Test func gizmoAngleFollowsFingerAroundCenter() {
        let center = CGPoint(x: 100, y: 100)
        // Палец справа переходит вниз: по часовой на экране, +90°.
        let quarter = HangarGizmoMath.angleDelta(center: center, from: CGPoint(x: 150, y: 100), to: CGPoint(x: 100, y: 150))
        #expect(abs(quarter - 90) < 1e-6)
        // Переход через разрез ±180 не даёт скачка.
        let across = HangarGizmoMath.angleDelta(center: center, from: CGPoint(x: 50, y: 99), to: CGPoint(x: 50, y: 101))
        #expect(abs(across) < 5)
        #expect(HangarGizmoMath.handedness(first: CGVector(dx: 1, dy: 0), second: CGVector(dx: 0, dy: 1)) == 1)
        #expect(HangarGizmoMath.handedness(first: CGVector(dx: 1, dy: 0), second: CGVector(dx: 0, dy: -1)) == -1)
        let (u, v) = HangarGizmoMath.ringAxes(0)
        #expect(u == 1 && v == 2)
    }

    @Test func offsetFollowsFingerAlongAxis() {
        let m = HangarGizmoMath.offsetMeters(translation: CGSize(width: 50, height: 30), direction: CGVector(dx: 1, dy: 0),
                                             pointsPerMeter: 100)
        #expect(abs(m - 0.5) < 1e-9)
        #expect(HangarGizmoMath.offsetMeters(translation: CGSize(width: 50, height: 0), direction: CGVector(dx: 1, dy: 0),
                                             pointsPerMeter: 0) == 0)
        #expect(HangarGizmoMath.degreesText(-30) == "−30°")
        #expect(HangarGizmoMath.metersText(0.1) == "0.10 м")
    }
}

@Suite("Космоцентр и технологии")
struct SpaceCenterLogicTests {
    @Test func russianPlural() {
        typealias L = SpaceCenterLogic
        #expect(L.plural(1, "проект", "проекта", "проектов") == "1 проект")
        #expect(L.plural(2, "проект", "проекта", "проектов") == "2 проекта")
        #expect(L.plural(5, "проект", "проекта", "проектов") == "5 проектов")
        #expect(L.plural(11, "проект", "проекта", "проектов") == "11 проектов")
        #expect(L.plural(21, "проект", "проекта", "проектов") == "21 проект")
    }

    @Test func buildingStatuses() {
        let fresh = GameProgress(mode: .science, science: 6)
        let research = SpaceCenterLogic.status(of: .research, progress: fresh, projectCount: 0)
        #expect(research.isAccent && research.isActive)
        #expect(research.subtitle.hasPrefix("доступно"))
        let poor = SpaceCenterLogic.status(of: .research, progress: GameProgress(mode: .science), projectCount: 0)
        #expect(!poor.isAccent)
        #expect(SpaceCenterLogic.status(of: .hangar, progress: fresh, projectCount: 3).subtitle == "3 проекта")
        let tracking = SpaceCenterLogic.status(of: .tracking, progress: fresh, projectCount: 0)
        #expect(!tracking.isActive && tracking.subtitle == "этап 9")
        #expect(SpaceCenterLogic.comingText(.missionControl) == "Появится на этапе 8")
        #expect(SpaceCenterLogic.status(of: .launchPad, progress: fresh, projectCount: 0).subtitle == "старт")
        let sandbox = SpaceCenterLogic.status(of: .research, progress: GameProgress(mode: .sandbox), projectCount: 0)
        #expect(!sandbox.isAccent)
    }

    @Test func techStatesAndReasons() {
        var p = GameProgress(mode: .science, science: 5)
        #expect(SpaceCenterLogic.state(of: .basics, progress: p) == .researched)
        #expect(SpaceCenterLogic.state(of: .rocketry, progress: p) == .available)
        #expect(SpaceCenterLogic.state(of: .aero, progress: p) == .locked)
        #expect(SpaceCenterLogic.researchBlock(.aero, progress: p) == "нужна предыдущая технология")
        let opened = p.research(.rocketry)
        #expect(opened)
        #expect(SpaceCenterLogic.state(of: .aero, progress: p) == .needsScience)
        #expect(SpaceCenterLogic.researchBlock(.aero, progress: p) == "нужна наука")
        #expect(SpaceCenterLogic.researchBlock(.rocketry, progress: p) == nil)
    }

    @Test func launchBlockedByClosedParts() {
        let message = SpaceCenterLogic.launchBlock(design: .orbit, locked: [.vikhr])
        #expect(message?.contains("Закрыты") == true)
        #expect(SpaceCenterLogic.launchBlock(design: VesselAssembly.empty, locked: []) != nil)
    }
}
