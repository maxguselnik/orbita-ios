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
    public static let maxParts = 30

    /// Замечания к проекту: блокирующие первыми. Индекс ступени — как в `StageInfo` (0 — нижняя секция).
    public func issues() -> [DesignIssue] {
        if parts.isEmpty { return [.empty] }
        var blocking: [DesignIssue] = []
        var warnings: [DesignIssue] = []

        let kinds = parts.map { $0.spec.kind }
        if !kinds.contains(where: { $0 == .pod || $0 == .probe }) { blocking.append(.noCommand) }
        if parts.count > Self.maxParts { blocking.append(.tooManyParts(limit: Self.maxParts)) }

        let ship = Ship(design: self)
        // Секции снизу вверх: индекс = номер ступени.
        let secs = Array(ship.sections.reversed())
        func isEngine(_ i: Int) -> Bool { kinds[i] == .engine }
        let hasEngine = kinds.contains(.engine)
        if !hasEngine { warnings.append(.noEngine) }

        if hasEngine {
            // Топливо: жидкостный двигатель без баков в той же секции.
            for (k, r) in secs.enumerated() {
                let hasLiquidEngine = r.contains { isEngine($0) && !parts[$0].spec.isSolid }
                if hasLiquidEngine && ship.liquidFuel(in: r) <= 1e-9 { warnings.append(.noFuel(stage: k)) }
            }
            // Тяга первой ступени с двигателем.
            if let k = secs.firstIndex(where: { $0.contains(where: isEngine) }) {
                let infos = ship.stageInfos(pressure: 1, gravity: Bodies.terra.surfaceGravity)
                if k < infos.count, infos[k].twr > 0, infos[k].twr < 1 {
                    warnings.append(.lowTWR(stage: k, twr: infos[k].twr))
                }
            }
            // Секции ниже командной без двигателей.
            if let cmd = secs.firstIndex(where: { $0.contains { kinds[$0] == .pod || kinds[$0] == .probe } }) {
                for k in 0..<cmd where !secs[k].contains(where: isEngine) { warnings.append(.emptyStage(stage: k)) }
            }
        }

        if kinds.last == .decoupler { warnings.append(.decouplerAtBottom) }
        if parts.contains(where: { $0.spec.crew > 0 }) && !parts.contains(.chute) { warnings.append(.noChute) }
        if kinds.contains(.monoTank) && !kinds.contains(.rcs) { warnings.append(.monoWithoutRCS) }
        return blocking + warnings
    }
}
