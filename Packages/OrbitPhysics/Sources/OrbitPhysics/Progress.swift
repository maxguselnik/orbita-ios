import Foundation

// Контракт этапа 5.2 (ведущий): режимы игры, дерево технологий, наука за вехи полёта.
// Описание — docs/CONTRACTS.md, «Космоцентр и технологии». Состояние хранит приложение (JSON в Documents).

/// Режим игры, выбирается при новой игре.
public enum GameMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Все детали открыты, наука не нужна.
    case sandbox
    /// Детали открываются за науку в исследовательском центре.
    case science
    /// Средства, репутация, контракты — этап 8; пока ведёт себя как `science`.
    case career

    public var title: String {
        switch self {
        case .sandbox: "Песочница"
        case .science: "Наука"
        case .career: "Карьера"
        }
    }
}

/// Технология дерева исследовательского центра.
public enum TechID: String, Sendable, Hashable, Codable, CaseIterable {
    case basics, rocketry, stability, aero, liquid, landing, control, crew, heavy
}

public struct TechNode: Sendable, Hashable, Identifiable {
    public let id: TechID
    public let title: String
    /// Цена в науке.
    public let cost: Int
    /// Нужна хотя бы одна из предыдущих (как в KSP); пусто — корень.
    public let requires: [TechID]
    public let parts: [PartID]
    /// Место в сетке дерева: столбец (уровень) и строка.
    public let column: Int
    public let row: Int
}

public enum TechTree {
    public static let nodes: [TechNode] = [
        TechNode(id: .basics, title: "Основы", cost: 0, requires: [],
                 parts: [.podK1, .chute, .t100, .t200, .molot, .decoupler], column: 0, row: 1),
        TechNode(id: .rocketry, title: "Ракетостроение", cost: 5, requires: [.basics],
                 parts: [.t400, .shtil], column: 1, row: 0),
        TechNode(id: .stability, title: "Устойчивость", cost: 5, requires: [.basics],
                 parts: [.fin, .heatShield], column: 1, row: 2),
        TechNode(id: .aero, title: "Аэродинамика", cost: 10, requires: [.rocketry],
                 parts: [.fairing, .decouplerRadial], column: 2, row: 0),
        TechNode(id: .liquid, title: "Жидкие ЖРД", cost: 10, requires: [.rocketry],
                 parts: [.vikhr, .t800], column: 2, row: 1),
        TechNode(id: .landing, title: "Посадка", cost: 15, requires: [.stability],
                 parts: [.legs], column: 2, row: 2),
        TechNode(id: .control, title: "Управление", cost: 15, requires: [.liquid],
                 parts: [.probe, .rcsBlock, .m100], column: 3, row: 1),
        TechNode(id: .crew, title: "Экипаж", cost: 25, requires: [.control, .landing],
                 parts: [.podK3], column: 4, row: 2),
        TechNode(id: .heavy, title: "Тяжёлые ракеты", cost: 30, requires: [.aero, .liquid],
                 parts: [.titan, .j64, .decouplerXL, .fairingXL, .heatShieldXL], column: 3, row: 0),
    ]

    public static func node(_ id: TechID) -> TechNode { nodes.first { $0.id == id }! }

    /// Технология, открывающая деталь (каждая деталь — ровно в одной).
    public static func tech(for part: PartID) -> TechID {
        nodes.first { $0.parts.contains(part) }?.id ?? .basics
    }
}

/// Веха полёта: наука начисляется один раз за игру.
public enum Milestone: String, Sendable, Hashable, Codable, CaseIterable {
    case launch, above10km, space, orbit, lunaSOI, lunaOrbit, lunaLanding, returnFromSpace
    case vellaSOI, vellaOrbit, ardaSOI, ardaOrbit, tarosSOI, tarosOrbit

    public var science: Int {
        switch self {
        case .launch: 2
        case .above10km: 4
        case .space: 8
        case .orbit: 12
        case .lunaSOI: 15
        case .lunaOrbit: 20
        case .lunaLanding: 30
        case .returnFromSpace: 10
        case .vellaSOI, .ardaSOI, .tarosSOI: 30
        case .vellaOrbit, .ardaOrbit, .tarosOrbit: 45
        }
    }

    public var title: String {
        switch self {
        case .launch: "Первый старт"
        case .above10km: "Выше 10 км"
        case .space: "Космос у Терры"
        case .orbit: "Орбита Терры"
        case .lunaSOI: "У Луны"
        case .lunaOrbit: "Орбита Луны"
        case .lunaLanding: "Посадка на Луну"
        case .returnFromSpace: "Возвращение из космоса"
        case .vellaSOI: "У Веллы"
        case .vellaOrbit: "Орбита Веллы"
        case .ardaSOI: "У Арды"
        case .ardaOrbit: "Орбита Арды"
        case .tarosSOI: "У Тароса"
        case .tarosOrbit: "Орбита Тароса"
        }
    }

    /// Вехи, достигнутые в полёте.
    public static func reached(in m: MissionRecord) -> [Milestone] {
        var out: [Milestone] = []
        if m.launched { out.append(.launch) }
        if m.maxAltitude >= 10_000 || m.reachedSpace { out.append(.above10km) }
        if m.reachedSpace { out.append(.space) }
        if m.reachedOrbit { out.append(.orbit) }
        if m.enteredLunaSOI { out.append(.lunaSOI) }
        if m.lunaOrbit { out.append(.lunaOrbit) }
        if m.landedLuna { out.append(.lunaLanding) }
        if m.returnedFromSpace { out.append(.returnFromSpace) }
        for (planet, soi, orbit) in [(BodyID.vella, Milestone.vellaSOI, Milestone.vellaOrbit),
                                     (.arda, .ardaSOI, .ardaOrbit), (.taros, .tarosSOI, .tarosOrbit)] {
            if m.visitedPlanets.contains(planet) { out.append(soi) }
            if m.orbitedPlanets.contains(planet) { out.append(orbit) }
        }
        return out
    }
}

/// Прогресс игры (сохраняется приложением в Documents/progress.json).
public struct GameProgress: Sendable, Hashable, Codable {
    public var mode: GameMode
    public var science: Int
    public var researched: Set<TechID>
    public var milestones: Set<Milestone>

    public init(mode: GameMode, science: Int = 0, researched: Set<TechID> = [.basics], milestones: Set<Milestone> = []) {
        self.mode = mode
        self.science = science
        self.researched = researched.union([.basics])
        self.milestones = milestones
    }

    public func isResearched(_ t: TechID) -> Bool { mode == .sandbox || researched.contains(t) }

    public func isUnlocked(_ part: PartID) -> Bool { isResearched(TechTree.tech(for: part)) }

    /// Можно открыть сейчас: не открыта, открыта хотя бы одна предыдущая, хватает науки.
    public func canResearch(_ t: TechID) -> Bool {
        let n = TechTree.node(t)
        return !isResearched(t) && (n.requires.isEmpty || n.requires.contains { isResearched($0) }) && science >= n.cost
    }

    @discardableResult
    public mutating func research(_ t: TechID) -> Bool {
        guard canResearch(t) else { return false }
        science -= TechTree.node(t).cost
        researched.insert(t)
        return true
    }

    /// Наука за повтор уже достигнутой вехи (как убывающая ценность повторных отчётов в KSP): четверть, не меньше 1.
    public static func repeatScience(_ m: Milestone) -> Int { max(1, m.science / 4) }

    /// Начислить науку за полёт: новые вехи — полностью, повторные — `repeatScience`.
    /// Возвращает новые вехи и всю начисленную науку (для экрана итогов).
    @discardableResult
    public mutating func award(_ mission: MissionRecord) -> (fresh: [Milestone], science: Int) {
        award(Milestone.reached(in: mission))
    }

    /// Начислить науку за вехи: новые — полностью, повторные — `repeatScience`.
    @discardableResult
    public mutating func award(_ reached: [Milestone]) -> (fresh: [Milestone], science: Int) {
        var fresh: [Milestone] = []
        var gained = 0
        for m in reached {
            if milestones.insert(m).inserted {
                fresh.append(m)
                gained += m.science
            } else {
                gained += Self.repeatScience(m)
            }
        }
        science += gained
        return (fresh, gained)
    }

    /// Детали проекта, которые ещё закрыты (старт запрещён).
    public func lockedParts(in design: VesselDesign) -> [PartID] {
        var seen = Set<PartID>()
        return design.parts.filter { !isUnlocked($0) && seen.insert($0).inserted }
    }
}

/// Начисление за один полёт: каждая веха — не больше раза за полёт, сколько бы раз ни открывались итоги
/// или ни продолжался полёт; перезапуск — новый полёт (`reset`). Итог — всё начисленное за полёт.
public struct FlightAward: Sendable, Hashable {
    /// Вехи полёта, уже учтённые (начисленные или пропущенные в уроке).
    public private(set) var counted: Set<Milestone> = []
    /// Новые за игру вехи этого полёта и вся начисленная за полёт наука.
    public private(set) var fresh: [Milestone] = []
    public private(set) var science = 0

    public init() {}

    /// Начислить вехи `mission`, ещё не учтённые в этом полёте. Возвращает итог полёта.
    @discardableResult
    public mutating func credit(_ mission: MissionRecord, to progress: inout GameProgress) -> (fresh: [Milestone], science: Int) {
        let pending = Milestone.reached(in: mission).filter { !counted.contains($0) }
        counted.formUnion(pending)
        let r = progress.award(pending)
        fresh += r.fresh
        science += r.science
        return (fresh, science)
    }

    /// Учесть вехи без начисления (пройдены в уроке до выхода из него).
    public mutating func skip(_ mission: MissionRecord) {
        counted.formUnion(Milestone.reached(in: mission))
    }

    public mutating func reset() { self = FlightAward() }
}
