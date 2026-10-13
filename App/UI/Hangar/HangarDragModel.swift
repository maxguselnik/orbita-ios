import CoreGraphics
import OrbitPhysics

/// Перетаскивание детали пальцем в цехе: чистая логика без SwiftUI и сцены.
/// Деталь «в руке» — из каталога или с корабля (вместе с поддеревом). Пока палец ведёт, ближайшая к нему точка
/// крепления (на экране, не дальше `snapRadius`) становится целью: считается предпросмотр (копия проекта с уже
/// прикреплённой деталью) и призрак для сцены. Проекция точек — функция `project` (в приложении — `HangarPreview.project`).
struct HangarDragModel {
    enum Source: Equatable {
        /// Новая деталь из каталога.
        case catalog(PartID)
        /// Деталь корабля (id) с поддеревом: перенос или, если бросить над каталогом, удаление.
        case vessel(Int)
    }

    /// Что делать, когда палец отпущен.
    enum Outcome: Equatable {
        /// Новая деталь прикреплена: проект после правки и id новых деталей.
        case attach(VesselDesign, newIDs: [Int])
        /// Деталь перенесена.
        case move(VesselDesign, id: Int)
        /// Бросили над каталогом — убрать деталь с корабля.
        case remove(Int)
        case cancel
    }

    /// Выбранная цель и вердикт.
    struct Snap: Equatable {
        var target: AttachTarget
        /// Где цель на экране.
        var screen: CGPoint
        var valid: Bool
    }

    /// Радиус притяжения к точке крепления, pt.
    static let snapRadius: CGFloat = 40
    /// Цель, уже выбранная, удерживается, пока не найдётся другая заметно ближе, pt.
    static let hysteresis: CGFloat = 8

    let source: Source
    /// Деталь «в руке».
    let part: PartID
    /// Проект на момент начала перетаскивания (во время жеста не меняется).
    let base: VesselDesign
    let symmetry: Int
    let mirror: Bool
    /// Деталь открыта (закрытая показывается красным призраком и не берётся).
    let isUnlocked: Bool

    private let candidates: [(target: AttachTarget, screen: CGPoint)]
    /// Поддерево переносимой детали (пусто для детали из каталога).
    let moving: Set<Int>

    private(set) var finger: CGPoint
    /// Палец ушёл влево за границу вида — над каталогом.
    private(set) var overCatalog = false
    private(set) var snap: Snap?
    /// Проект с применённой правкой (или с красным призраком); nil — цели нет или нельзя.
    private(set) var preview: VesselDesign?
    /// Призрак для сцены; nil — нет цели или нет что показать.
    private(set) var ghost: HangarGhost?
    /// id новых деталей предпросмотра (для деталей из каталога).
    private(set) var previewIDs: [Int] = []

    /// - Parameters:
    ///   - project: точка раскладки → точка экрана; nil — за камерой (такая цель пропускается).
    init(source: Source, design: VesselDesign, symmetry: Int, mirror: Bool, isUnlocked: Bool,
         at finger: CGPoint, project: (Vec3) -> CGPoint?) {
        self.source = source
        self.base = design
        self.mirror = mirror
        self.isUnlocked = isUnlocked
        self.finger = finger
        let part: PartID
        var moving: Set<Int> = []
        var count = max(1, min(symmetry, 4))
        switch source {
        case .catalog(let id):
            part = id
        case .vessel(let id):
            part = design.node(id)?.part ?? .t100
            moving = Self.subtree(of: id, in: design)
            count = 1
        }
        self.part = part
        self.symmetry = count
        self.moving = moving
        var list: [(target: AttachTarget, screen: CGPoint)] = []
        for target in VesselEditing.attachTargets(for: part, symmetry: count, in: design) {
            if let parent = target.parent, moving.contains(parent) { continue }
            if let point = project(target.position) { list.append((target, point)) }
        }
        candidates = list
        _ = update(to: finger, overCatalog: false)
    }

    /// Все цели с экранными точками (для отладки и тестов).
    var candidateTargets: [AttachTarget] { candidates.map(\.target) }

    /// Показывать деталь «в руке» под пальцем: цели нет или предпросмотр не построен.
    var showsFloating: Bool { ghost == nil }

    /// Палец над каталогом с деталью корабля: отпускание удалит деталь.
    var isDeleting: Bool {
        if case .vessel = source { return overCatalog }
        return false
    }

    /// Проект для сцены: предпросмотр или исходный.
    var sceneDesign: VesselDesign { preview ?? base }

    /// Палец сдвинулся. `overCatalog` — вышел влево за вид; `outside` — вышел за вид в любую сторону (цели нет).
    /// Возвращает true, если цель сменилась (для вибрации и пересборки сцены).
    @discardableResult
    mutating func update(to point: CGPoint, overCatalog: Bool, outside: Bool = false) -> Bool {
        finger = point
        self.overCatalog = overCatalog
        let before = snap?.target
        let found = (overCatalog || outside) ? nil : nearest(to: point)
        if found?.target != before {
            apply(found)
            return true
        }
        return false
    }

    /// Результат отпускания.
    func finish() -> Outcome {
        if let snap, snap.valid, let preview {
            switch source {
            case .catalog: return .attach(preview, newIDs: previewIDs)
            case .vessel(let id): return .move(preview, id: id)
            }
        }
        if case .vessel(let id) = source, overCatalog { return .remove(id) }
        return .cancel
    }

    // MARK: - Внутреннее

    private func nearest(to point: CGPoint) -> (target: AttachTarget, screen: CGPoint)? {
        var best: (target: AttachTarget, screen: CGPoint)?
        var bestDistance = Self.snapRadius
        var currentDistance: CGFloat?
        for item in candidates {
            let d = hypot(item.screen.x - point.x, item.screen.y - point.y)
            if item.target == snap?.target { currentDistance = d }
            if d <= bestDistance {
                best = item
                bestDistance = d
            }
        }
        // Удерживаем текущую цель, пока другая не заметно ближе.
        if let current = snap, let currentDistance, currentDistance <= Self.snapRadius,
           currentDistance <= bestDistance + Self.hysteresis,
           let keep = candidates.first(where: { $0.target == current.target }) {
            return keep
        }
        return best
    }

    private mutating func apply(_ found: (target: AttachTarget, screen: CGPoint)?) {
        preview = nil
        ghost = nil
        previewIDs = []
        guard let found else {
            snap = nil
            return
        }
        let target = found.target
        var valid = false
        switch source {
        case .catalog(let id):
            evaluateCatalog(id, target: target, valid: &valid)
        case .vessel(let id):
            var copy = base
            if VesselEditing.move(id, to: target, in: &copy) {
                valid = true
                preview = copy
                ghost = HangarGhost(ids: moving, valid: true)
            }
        }
        snap = Snap(target: target, screen: found.screen, valid: valid)
    }

    private mutating func evaluateCatalog(_ id: PartID, target: AttachTarget, valid: inout Bool) {
        guard VesselEditing.canAttach(id, to: target, in: base) else { return }
        if isUnlocked, base.nodes.count < VesselDesign.maxParts {
            var copy = base
            let ids = VesselEditing.attach(id, to: target, symmetry: symmetry, mirror: mirror, in: &copy)
            if !ids.isEmpty {
                valid = true
                preview = copy
                previewIDs = ids
                ghost = HangarGhost(ids: Set(ids), valid: true)
                return
            }
        }
        // Закрыта или лимит: красный призрак на этой же точке (одна деталь без правил).
        var copy = base
        let ghostID = copy.nextID
        copy.nodes.append(DesignPart(id: ghostID, part: id, parent: target.parent, node: target.node,
                                     angle: target.angle, height: target.height))
        preview = copy
        previewIDs = [ghostID]
        ghost = HangarGhost(ids: [ghostID], valid: false)
    }

    /// Деталь и все её потомки.
    static func subtree(of id: Int, in design: VesselDesign) -> Set<Int> {
        var result: Set<Int> = [id]
        var grew = true
        while grew {
            grew = false
            for node in design.nodes {
                if let parent = node.parent, result.contains(parent), result.insert(node.id).inserted { grew = true }
            }
        }
        return result
    }
}
