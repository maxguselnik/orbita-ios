import Foundation

// Проверка проекта корабля в ангаре (docs/SPEC.md, «Детали и ступени»).

public enum DesignIssue: Sendable, Hashable {
    /// Нет деталей — блокирует.
    case empty
    /// Нет капсулы или модуля управления — блокирует.
    case noCommand
    /// Больше `VesselDesign.maxParts` — блокирует.
    case tooManyParts(limit: Int)
    /// Нет ни одного двигателя.
    case noEngine
    /// Первая работающая ступень: TWR у земли Терры < 1 (ракета не оторвётся).
    case lowTWR(stage: Int, twr: Double)
    /// В секции жидкостный двигатель без баков с топливом.
    case noFuel(stage: Int)
    /// Секция ниже командной без двигателей (лишний разделитель).
    case emptyStage(stage: Int)
    /// Нижняя деталь — разделитель.
    case decouplerAtBottom
    /// Есть экипаж, нет парашюта.
    case noChute
    /// Есть бак монотоплива, но нет блока РСУ.
    case monoWithoutRCS
    /// Тяга ступени проходит мимо центра масс (плечо > 0.1 м) — корабль закрутит.
    case asymmetricThrust(stage: Int)

    public var isBlocking: Bool {
        switch self {
        case .empty, .noCommand, .tooManyParts: true
        default: false
        }
    }

    /// Короткая строка для UI по-русски. Номер ступени — с единицы.
    public var text: String {
        switch self {
        case .empty:
            "В проекте нет деталей"
        case .noCommand:
            "Нет капсулы или модуля управления"
        case .tooManyParts(let limit):
            "Слишком много деталей: максимум \(limit)"
        case .noEngine:
            "Нет ни одного двигателя"
        case .lowTWR(let stage, let twr):
            "TWR \(Self.stageWord(stage)) \(String(format: "%.2f", twr)) — ракета не оторвётся"
        case .noFuel(let stage):
            "\(Self.stageWord(stage, capitalized: true)): двигатель без топливных баков"
        case .emptyStage(let stage):
            "\(Self.stageWord(stage, capitalized: true)) без двигателей — лишний разделитель"
        case .decouplerAtBottom:
            "Внизу стоит разделитель"
        case .noChute:
            "Есть экипаж, но нет парашюта"
        case .monoWithoutRCS:
            "Бак монотоплива без блока РСУ"
        case .asymmetricThrust(let stage):
            "\(Self.stageWord(stage, capitalized: true)): тяга мимо центра масс — корабль закрутит"
        }
    }

    private static func stageWord(_ stage: Int, capitalized: Bool = false) -> String {
        let n = stage + 1
        if n == 1 && !capitalized { return "первой ступени" }
        return capitalized ? "Ступень \(n)" : "ступени \(n)"
    }
}

extension VesselDesign {
    /// Предельное число деталей в проекте.
    public static let maxParts = 60

    /// Плечо асимметрии тяги, выше которого — предупреждение, м.
    static let asymmetryLimit = 0.1

    /// Замечания к проекту: блокирующие первыми. Индекс ступени — ступень активации, как в `stageInfos()`.
    public func issues() -> [DesignIssue] {
        if nodes.isEmpty { return [.empty] }
        var blocking: [DesignIssue] = []
        var warnings: [DesignIssue] = []
        func add(_ i: DesignIssue) { if !warnings.contains(i) { warnings.append(i) } }

        let kinds = parts.map { $0.spec.kind }
        if !kinds.contains(where: { $0 == .pod || $0 == .probe }) { blocking.append(.noCommand) }
        if nodes.count > Self.maxParts { blocking.append(.tooManyParts(limit: Self.maxParts)) }

        let ship = Ship(design: self)
        let groups = stageGroups
        let kids = childrenMap()
        let hasEngine = kinds.contains(.engine)
        if !hasEngine { warnings.append(.noEngine) }

        if hasEngine {
            // Топливо: жидкостный двигатель без баков в своей группе.
            for (i, n) in nodes.enumerated() where n.part.spec.kind == .engine && !n.part.spec.isSolid {
                if ship.liquidFuel(group: ship.group[i]) <= 1e-9 { add(.noFuel(stage: ship.parts[i].stage ?? 0)) }
            }
            // Тяга первой ступени с двигателем.
            if let k = groups.firstIndex(where: { g in g.contains { node($0)?.part.spec.kind == .engine } }) {
                let infos = ship.stageInfos(pressure: 1, gravity: Bodies.terra.surfaceGravity)
                if k < infos.count, infos[k].twr > 0, infos[k].twr < 1 {
                    add(.lowTWR(stage: k, twr: infos[k].twr))
                }
            }
            // Разделитель, который уносит часть без двигателей (и без командного модуля), — лишний.
            for n in nodes where n.part.spec.kind == .decoupler && n.parent != nil {
                let sub = subtreeIDs(n.id)
                if sub.contains(where: { id in node(id).map { $0.part.spec.kind == .pod || $0.part.spec.kind == .probe } ?? false }) {
                    continue
                }
                // Секция разделителя: его поддерево до следующих разделителей.
                var section: [DesignPart] = []
                var stack = kids[n.id] ?? []
                while let x = stack.popLast() {
                    section.append(x)
                    if x.part.spec.kind != .decoupler { stack += kids[x.id] ?? [] }
                }
                if !section.contains(where: { $0.part.spec.kind == .engine }) {
                    add(.emptyStage(stage: ship.parts[index(of: n.id) ?? 0].stage ?? 0))
                }
            }
        }

        if nodes.contains(where: { n in n.part.spec.kind == .decoupler && kids[n.id] == nil }) {
            warnings.append(.decouplerAtBottom)
        }
        if parts.contains(where: { $0.spec.crew > 0 }) && !parts.contains(.chute) { warnings.append(.noChute) }
        if kinds.contains(.monoTank) && !kinds.contains(.rcs) { warnings.append(.monoWithoutRCS) }
        // Асимметрия тяги по ступеням с двигателями.
        for (k, g) in groups.enumerated() where g.contains(where: { node($0)?.part.spec.kind == .engine }) {
            if markers(stage: k).thrustOffset > Self.asymmetryLimit { add(.asymmetricThrust(stage: k)) }
        }
        return blocking + warnings
    }
}
