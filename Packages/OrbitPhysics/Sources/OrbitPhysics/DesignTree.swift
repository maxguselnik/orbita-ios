import Foundation

// Контракт этапа 5.2 (ведущий): проект корабля — дерево деталей. Описание — docs/CONTRACTS.md, «Конструктор».
// Типы и сигнатуры менять только ведущему. Тела, помеченные «A», реализует поток A.

/// Узел, которым деталь крепится к родителю.
public enum AttachNode: String, Sendable, Hashable, Codable {
    /// Верхний узел родителя: деталь стоит над родителем, её стек растёт вверх.
    case top
    /// Нижний узел родителя: деталь под родителем, стек растёт вниз.
    case bottom
    /// Боковая поверхность родителя: азимут `angle`, высота `height`. Ось детали параллельна оси родителя.
    case radial
}

/// Как деталь может крепиться к родителю.
public enum PartMount: Sendable, Hashable {
    /// Только узлы `.top`/`.bottom`.
    case axial
    /// Только `.radial`.
    case radial
    /// И так, и так.
    case any
}

/// Деталь в дереве проекта.
public struct DesignPart: Sendable, Hashable, Codable, Identifiable {
    /// Уникален в проекте, не меняется при правках (выделение, ступени ссылаются на него).
    public var id: Int
    public var part: PartID
    /// nil — корень (ровно один на проект).
    public var parent: Int?
    /// Узел родителя; у корня не используется.
    public var node: AttachNode
    /// `.radial`: азимут вокруг оси родителя, градусы: 0 — +X (правый борт), 90 — +Z (спина).
    public var angle: Double
    /// `.radial`: высота точки крепления по оси родителя: 0 — низ родителя, 1 — верх.
    public var height: Double
    /// Детали одной группы симметрии — копии с азимутами через 360°/n (n = 2…4). nil — без симметрии.
    public var symmetryGroup: Int?
    /// Ступень активации (0 — первая, по кнопке «Ступень» на старте) для двигателей, разделителей,
    /// парашюта, обтекателя. nil — деталь не активируется.
    public var stage: Int?
    /// Поворот, градусы: x — тангаж, y — крен вокруг оси детали, z — рыскание; относительно положения
    /// по умолчанию на узле (у боковой — в системе узла: +Z — наружу). Поворот — вокруг точки крепления.
    public var rotation: Vec3
    /// Сдвиг от точки крепления в осях корабля, м.
    public var offset: Vec3
    /// Копия зеркальной симметрии (отражение относительно плоскости YZ корабля).
    public var mirrored: Bool = false

    public init(id: Int, part: PartID, parent: Int?, node: AttachNode = .bottom, angle: Double = 0,
                height: Double = 0.5, symmetryGroup: Int? = nil, stage: Int? = nil,
                rotation: Vec3 = .zero, offset: Vec3 = .zero) {
        self.id = id
        self.part = part
        self.parent = parent
        self.node = node
        self.angle = angle
        self.height = height
        self.symmetryGroup = symmetryGroup
        self.stage = stage
        self.rotation = rotation
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey {
        case id, part, parent, node, angle, height, symmetryGroup, stage, rotation, offset, mirrored
    }

    /// Поля 5.2 (`rotation`, `offset`, `mirrored`) необязательны: ранние файлы v2 читаются.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        part = try c.decode(PartID.self, forKey: .part)
        parent = try c.decodeIfPresent(Int.self, forKey: .parent)
        node = try c.decodeIfPresent(AttachNode.self, forKey: .node) ?? .bottom
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.5
        symmetryGroup = try c.decodeIfPresent(Int.self, forKey: .symmetryGroup)
        stage = try c.decodeIfPresent(Int.self, forKey: .stage)
        rotation = try c.decodeIfPresent(Vec3.self, forKey: .rotation) ?? .zero
        offset = try c.decodeIfPresent(Vec3.self, forKey: .offset) ?? .zero
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? false
    }
}

/// Проект корабля: дерево деталей. Сохраняется в Documents/hangar.json (версия 2);
/// старый формат `{"name","parts":[...]}` (стек сверху вниз) читается как линейное дерево с авто-ступенями.
public struct VesselDesign: Sendable, Hashable {
    public var name: String
    /// Детали в порядке обхода в глубину от корня (родитель раньше детей; для линейного стека — сверху вниз).
    /// Этот порядок — индексы `parts`, `layout()`, `VesselState.parts/layout/firingEngines`.
    public var nodes: [DesignPart]
    /// Ступени расставлены вручную (редактор ступеней). false — пересчитываются авто-правилом после каждой правки.
    public var customStaging: Bool

    public init(name: String, nodes: [DesignPart], customStaging: Bool = false) {
        self.name = name
        self.nodes = nodes
        self.customStaging = customStaging
    }

    /// Линейный стек сверху вниз (старый формат): корень — `parts[0]`, каждая следующая — на нижнем узле
    /// предыдущей; ступени — по авто-правилу (повторяет прежнее поведение кнопки «Ступень»).
    public init(name: String, parts: [PartID]) {
        self.name = name
        nodes = parts.enumerated().map { i, p in
            DesignPart(id: i, part: p, parent: i == 0 ? nil : i - 1, node: .bottom)
        }
        customStaging = false
        self = autoStaged()
    }

    /// Детали в порядке `nodes`.
    public var parts: [PartID] { nodes.map(\.part) }

    public var root: DesignPart? { nodes.first { $0.parent == nil } }

    public func node(_ id: Int) -> DesignPart? { nodes.first { $0.id == id } }

    /// Индекс в `nodes` по id.
    public func index(of id: Int) -> Int? { nodes.firstIndex { $0.id == id } }

    /// Следующий свободный id.
    public var nextID: Int { (nodes.map(\.id).max() ?? -1) + 1 }
}

extension VesselDesign: Codable {
    private enum Keys: String, CodingKey { case name, version, nodes, customStaging, parts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let name = try c.decode(String.self, forKey: .name)
        if let nodes = try c.decodeIfPresent([DesignPart].self, forKey: .nodes) {
            self.init(name: name, nodes: nodes,
                      customStaging: try c.decodeIfPresent(Bool.self, forKey: .customStaging) ?? false)
        } else {
            self.init(name: name, parts: try c.decode([PartID].self, forKey: .parts))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encode(2, forKey: .version)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(customStaging, forKey: .customStaging)
    }
}

// MARK: - Раскладка

/// Положение детали в осях корабля (нос +Y, спина +Z, правый борт +X), м.
/// Начало координат — на оси корня, на уровне самой нижней точки корабля (= `VesselState.position`):
/// у всех деталей `bottom ≥ 0`, у самой нижней — 0.
public struct PartPlacement: Sendable, Hashable {
    /// Центр детали.
    public var center: Vec3
    /// Радиальная деталь: единичный вектор наружу в плоскости XZ (стабилизатор смотрит пером наружу,
    /// боковой разделитель — плоскостью к родителю). Осевая — `.zero`.
    public var outward: Vec3
    public var height: Double
    public var diameter: Double
    /// Поворот из осей детали в оси корабля (осевая без поворота — identity).
    public var orientation: Quat

    public var bottom: Double { center.y - height / 2 }
    public var top: Double { center.y + height / 2 }

    public init(center: Vec3, outward: Vec3 = .zero, height: Double, diameter: Double,
                orientation: Quat = .identity) {
        self.center = center
        self.outward = outward
        self.height = height
        self.diameter = diameter
        self.orientation = orientation
    }
}

/// Маркеры конструктора в осях раскладки.
public struct DesignMarkers: Sendable, Hashable {
    /// Центр масс (полные баки).
    public var centerOfMass: Vec3
    /// Центр тяги двигателей ступени `stage` (точка на линии суммарной тяги на уровне сопел); nil — нет двигателей.
    public var centerOfThrust: Vec3?
    /// Плечо асимметрии: |момент тяги вокруг ЦМ| / суммарная тяга, м. ≈0 — тяга через ЦМ.
    public var thrustOffset: Double
    /// Центр давления (аэродинамический фокус: площади деталей, стабилизаторы — с большим весом); nil — нет деталей.
    public var centerOfPressure: Vec3?

    public init(centerOfMass: Vec3, centerOfThrust: Vec3?, thrustOffset: Double, centerOfPressure: Vec3?) {
        self.centerOfMass = centerOfMass
        self.centerOfThrust = centerOfThrust
        self.thrustOffset = thrustOffset
        self.centerOfPressure = centerOfPressure
    }
}

/// Куда можно прикрепить деталь (точка крепления для UI).
public struct AttachTarget: Sendable, Hashable {
    /// nil — пустой проект: деталь станет корнем.
    public var parent: Int?
    public var node: AttachNode
    public var angle: Double
    public var height: Double
    /// Точка крепления в осях раскладки (для маркера на экране через `HangarPreview.project`).
    public var position: Vec3

    public init(parent: Int?, node: AttachNode, angle: Double = 0, height: Double = 0.5, position: Vec3) {
        self.parent = parent
        self.node = node
        self.angle = angle
        self.height = height
        self.position = position
    }
}

// MARK: - Правки (A)

/// Правки дерева проекта: чистые функции, проверяются тестами. После каждой структурной правки
/// `nodes` упорядочены обходом в глубину; при `customStaging == false` ступени пересчитываются авто-правилом,
/// при `true` новые активируемые детали получают ступень по авто-правилу (не больше числа ступеней).
/// Лимит — `VesselDesign.maxParts` (с учётом копий симметрии).
public enum VesselEditing {
    /// Можно ли крепить деталь `part` к узлу: правило `PartSpec.mount`, узел `.top/.bottom` у радиальных
    /// деталей-родителей — только по оси самой радиальной детали, боковой разделитель принимает
    /// только `.radial`-ребёнка наружу, стабилизатор детей не принимает. Занятый осевой узел допустим:
    /// новая деталь встаёт между (прежний ребёнок переходит на её узел с той же стороны).
    public static func canAttach(_ part: PartID, to target: AttachTarget, in design: VesselDesign) -> Bool {
        canAttachImpl(part, target, design)
    }

    /// Точки крепления для детали `part`: осевые (верх/низ каждой подходящей детали, включая занятые —
    /// вставка) и радиальные (8 азимутов через 45° на высоте 0.5 у деталей, принимающих бок; у бокового
    /// разделителя — одна наружу). Для пустого проекта — одна точка с `parent == nil`.
    /// При `symmetry` > 1 радиальные точки — те, для которых все n копий помещаются.
    public static func attachTargets(for part: PartID, symmetry: Int, in design: VesselDesign) -> [AttachTarget] {
        attachTargetsImpl(part, symmetry, design)
    }

    /// Прикрепить деталь. Радиальное крепление при `symmetry` n = 2…4 ставит n копий через 360°/n в одну
    /// группу симметрии; если родитель сам в группе симметрии из m копий — деталь ставится к каждой из m
    /// (с тем же относительным азимутом), группа — общая. `mirror` при n = 2 — копия зеркально относительно
    /// плоскости YZ корабля (азимут 180° − a, `mirrored`). Возвращает id новых деталей (первая — у `target`);
    /// пусто — нельзя (правило, лимит).
    @discardableResult
    public static func attach(_ part: PartID, to target: AttachTarget, symmetry: Int, mirror: Bool = false,
                              in design: inout VesselDesign) -> [Int] {
        attachImpl(part, target, symmetry, mirror, &design)
    }

    /// Поворот детали (градусы, см. `DesignPart.rotation`); копии симметрии — согласованно (боковые — тот же
    /// поворот в своей системе узла, зеркальные — отражённый), так что симметричная группа не даёт момента.
    public static func setRotation(_ id: Int, _ rotation: Vec3, in design: inout VesselDesign) {
        setRotationImpl(id, rotation, &design)
    }

    /// Сдвиг детали от точки крепления (оси корабля, м), ограничен габаритом родителя: по оси — не больше
    /// половины высоты родителя, вбок — не больше его радиуса. Копии — согласованно.
    public static func setOffset(_ id: Int, _ offset: Vec3, in design: inout VesselDesign) {
        setOffsetImpl(id, offset, &design)
    }

    /// Переподвесить дерево на новый корень: рёбра пути к прежнему корню разворачиваются, узлы top↔bottom
    /// меняются так, что раскладка не меняется. false — на пути боковое крепление (или поворот/сдвиг).
    @discardableResult
    public static func setRoot(_ id: Int, in design: inout VesselDesign) -> Bool {
        setRootImpl(id, &design)
    }

    /// Убрать деталь вместе с копиями симметрии. Осевой ребёнок на противоположном узле (продолжение стека)
    /// переходит к родителю на тот же узел; остальные потомки убираются. Корень: если у него один осевой
    /// ребёнок — тот становится корнем, иначе проект пустеет. Возвращает id всех убранных.
    @discardableResult
    public static func remove(_ id: Int, in design: inout VesselDesign) -> [Int] {
        removeImpl(id, &design)
    }

    /// Перенести деталь с её поддеревом к другой точке (id сохраняются; группа симметрии детали снимается).
    /// Нельзя к себе или своему потомку. false — без изменений.
    @discardableResult
    public static func move(_ id: Int, to target: AttachTarget, in design: inout VesselDesign) -> Bool {
        moveImpl(id, target, &design)
    }

    /// Редактор ступеней: перенести деталь (и копии симметрии) в ступень `stage`; `stage == stageCount` —
    /// новая ступень в конце, `stage < 0` — новая ступень в начале (остальные сдвигаются).
    /// Пустые ступени схлопываются. Включает `customStaging`. Неактивируемые детали — без изменений.
    public static func setStage(_ id: Int, to stage: Int, in design: inout VesselDesign) {
        setStageImpl(id, stage, &design)
    }

    /// Поменять ступени местами (перетаскивание строки ступени). Включает `customStaging`.
    public static func swapStages(_ a: Int, _ b: Int, in design: inout VesselDesign) {
        swapStagesImpl(a, b, &design)
    }

    /// Вернуть авто-ступени (`customStaging = false`).
    public static func resetStaging(in design: inout VesselDesign) {
        design = design.autoStaged()
    }
}

extension VesselDesign {
    /// Раскладка деталей в порядке `nodes` (A).
    public func layout() -> [PartPlacement] {
        computeLayout()
    }

    /// Ступени активации по возрастанию (0 — первая), в каждой — id деталей; пустых нет (A).
    /// `stageInfos()` возвращает столько же элементов, в том же порядке.
    public var stageGroups: [[Int]] {
        computeStageGroups()
    }

    /// Ступени по авто-правилу (A): двигатель — в ступень срабатывания ближайшего разделителя ниже него по
    /// нижним узлам (нет такого — 0); разделитель на глубине d (число разделителей от корня до него,
    /// включая его) — в `maxDepth − d + 1`; обтекатель — с первым срабатыванием разделителя (без
    /// разделителей — после двигателей); парашют — последняя ступень. Для старых линейных стеков даёт
    /// прежнюю последовательность: зажигание → разделение + зажигание следующей → … → парашют.
    public func autoStaged() -> VesselDesign {
        computeAutoStaged()
    }

    /// Маркеры для ступени активации `stage` (тяга — двигатели, зажжённые к этой ступени и ещё не отделённые);
    /// nil — первая ступень с двигателями (A).
    public func markers(stage: Int? = nil) -> DesignMarkers {
        computeMarkers(stage: stage)
    }
}
