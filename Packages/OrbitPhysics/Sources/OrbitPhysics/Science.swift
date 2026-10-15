import Foundation

// Научные данные, первая поставка (docs/SCIENCE_TASKS.md, SCI-01/02/03/05/07): отчёт экипажа хранится в кабине,
// наука начисляется при возврате капсулы на Терру, каждый предмет (эксперимент + тело + ситуация) — с пределом.
// Контракт — docs/CONTRACTS.md, «Научные данные».

/// Эксперимент.
public enum ExperimentID: String, Sendable, Hashable, Codable, CaseIterable {
    case crewReport, temperature, pressure, gravity
    /// EVA (этап 6): только космонавт снаружи (`FlightCommand.evaReport` / `.evaCollectSample`).
    case evaReport, surfaceSample

    /// Проводит космонавт снаружи, а не корабль.
    public var isEVA: Bool { self == .evaReport || self == .surfaceSample }

    public var title: String {
        switch self {
        case .crewReport: "Отчёт экипажа"
        case .evaReport: "Отчёт EVA"
        case .surfaceSample: "Образец грунта"
        case .temperature: "Термометр"
        case .pressure: "Барометр"
        case .gravity: "Гравиметр"
        }
    }

    /// Базовая ценность (до множителя места).
    public var baseValue: Double {
        switch self {
        case .crewReport, .temperature: 8
        case .pressure: 12
        case .gravity: 20
        case .evaReport: 10
        case .surfaceSample: 25
        }
    }

    /// Прибор, который проводит эксперимент (nil — отчёт экипажа, нужен экипаж).
    public var instrument: PartID? {
        switch self {
        case .crewReport, .evaReport, .surfaceSample: nil
        case .temperature: .thermometer
        case .pressure: .barometer
        case .gravity: .gravimeter
        }
    }

    /// Можно ли провести эксперимент в этом месте.
    public func works(_ s: ScienceSituation, body: BodyID) -> Bool {
        switch self {
        case .crewReport, .evaReport: true
        case .surfaceSample: s == .landed || s == .launchPad
        case .temperature: s != .highSpace
        case .pressure:
            Bodies.body(body).atmosphereHeight > 0 && s != .nearSpace && s != .highSpace
        case .gravity: s != .lowAtmosphere && s != .highAtmosphere
        }
    }

    /// Где работает (для подсказки, почему недоступен).
    public var whereItWorks: String {
        switch self {
        case .crewReport, .evaReport: "везде"
        case .surfaceSample: "только на грунте"
        case .temperature: "ниже дальнего космоса"
        case .pressure: "только в воздухе"
        case .gravity: "на поверхности и в космосе"
        }
    }
}

/// Научная ситуация: где находится корабль.
public enum ScienceSituation: String, Sendable, Hashable, Codable, CaseIterable {
    case launchPad, landed, splashed, lowAtmosphere, highAtmosphere, nearSpace, highSpace

    public var title: String {
        switch self {
        case .launchPad: "площадка"
        case .landed: "поверхность"
        case .splashed: "океан"
        case .lowAtmosphere: "нижняя атмосфера"
        case .highAtmosphere: "верхняя атмосфера"
        case .nearSpace: "ближний космос"
        case .highSpace: "дальний космос"
        }
    }
}

/// Научный предмет: один и тот же эксперимент в одном месте — один предмет, сколько бы раз его ни проводили.
public struct ScienceSubjectID: Sendable, Hashable, Codable, Comparable {
    public var experiment: ExperimentID
    public var body: BodyID
    public var situation: ScienceSituation

    public init(experiment: ExperimentID, body: BodyID, situation: ScienceSituation) {
        self.experiment = experiment
        self.body = body
        self.situation = situation
    }

    /// Устойчивый ключ архива.
    public var key: String { "\(experiment.rawValue)@\(body.rawValue):\(situation.rawValue)" }

    /// «Терра · ближний космос».
    public var placeTitle: String { "\(Bodies.body(body).name) · \(situation.title)" }

    /// Полная ценность предмета (предел начисления).
    public var cap: Double { (experiment.baseValue * ScienceBalance.multiplier(body, situation) * 10).rounded() / 10 }

    public static func < (a: Self, b: Self) -> Bool { a.key < b.key }
}

/// Место корабля для науки; nil — наука здесь невозможна (авария, недопустимая ситуация).
public enum ScienceContext {
    /// Ситуация по телу, состоянию корабля и высоте над уровнем моря.
    public static func situation(body: BodyID, vessel: VesselSituation, altitude: Double) -> ScienceSituation? {
        let s: ScienceSituation
        switch vessel {
        case .crashed: return nil
        case .prelaunch: s = body == .terra ? .launchPad : .landed
        case .landed: s = .landed
        case .splashed: s = .splashed
        case .flying, .suborbital, .orbiting, .escaping:
            let b = Bodies.body(body)
            let zone = ScienceBalance.zone(body)
            if b.atmosphereHeight > 0, altitude < b.atmosphereHeight {
                s = altitude < zone.lowAtmosphereTop ? .lowAtmosphere : .highAtmosphere
            } else {
                s = altitude < zone.nearSpaceTop ? .nearSpace : .highSpace
            }
        }
        return ScienceBalance.multiplier(body, s) > 0 ? s : nil
    }
}

/// Таблица баланса: границы ситуаций и множители мест (SPEC «Наука»; собственные числа «Орбиты»).
public enum ScienceBalance {
    public struct Zone: Sendable {
        /// Верх нижней атмосферы и верх ближнего космоса над уровнем моря, м.
        public var lowAtmosphereTop: Double
        public var nearSpaceTop: Double
    }

    public static func zone(_ body: BodyID) -> Zone {
        switch body {
        case .terra: Zone(lowAtmosphereTop: 18_000, nearSpaceTop: 250_000)
        case .luna: Zone(lowAtmosphereTop: 0, nearSpaceTop: 60_000)
        case .vella: Zone(lowAtmosphereTop: 30_000, nearSpaceTop: 300_000)
        case .arda: Zone(lowAtmosphereTop: 15_000, nearSpaceTop: 150_000)
        case .taros: Zone(lowAtmosphereTop: 60_000, nearSpaceTop: 1_000_000)
        case .sol: Zone(lowAtmosphereTop: 0, nearSpaceTop: 1_000_000_000)
        }
    }

    /// Множитель места; 0 — ситуация на этом теле невозможна.
    public static func multiplier(_ body: BodyID, _ s: ScienceSituation) -> Double {
        let b = Bodies.body(body)
        let hasAir = b.atmosphereHeight > 0
        switch s {
        case .launchPad: return body == .terra ? 0.3 : 0
        case .landed, .splashed: guard b.hasSolidSurface else { return 0 }
        case .lowAtmosphere, .highAtmosphere: guard hasAir else { return 0 }
        case .nearSpace, .highSpace: break
        }
        switch (body, s) {
        case (.terra, .landed), (.terra, .splashed): return 0.3
        case (.terra, .lowAtmosphere), (.terra, .highAtmosphere): return 0.7
        case (.terra, .nearSpace): return 1
        case (.terra, _): return 1.5
        case (.luna, .nearSpace): return 3.5
        case (.luna, .highSpace): return 3
        case (.luna, _): return 4
        case (.taros, .nearSpace): return 4
        case (.taros, .highSpace): return 3.5
        case (.taros, _): return 5
        case (.sol, .nearSpace): return 2.5
        case (.sol, _): return 1.5
        case (_, .landed), (_, .splashed): return 5
        case (_, .lowAtmosphere), (_, .highAtmosphere): return 4
        case (_, .nearSpace): return 3.5
        case (_, _): return 3
        }
    }
}

/// Результат эксперимента на борту. Ценность — по архиву в момент доставки.
public struct ScienceData: Sendable, Hashable, Codable, Identifiable {
    /// Устойчивый id: повторная доставка того же результата ничего не добавляет.
    public var id: String
    public var subject: ScienceSubjectID
    /// Время симуляции получения, с.
    public var collectedAt: Double

    public init(id: String = UUID().uuidString, subject: ScienceSubjectID, collectedAt: Double) {
        self.id = id
        self.subject = subject
        self.collectedAt = collectedAt
    }
}

/// Архив начислений за данные (сохраняется в `GameProgress`).
public struct ScienceArchive: Sendable, Hashable, Codable {
    /// Начислено по предмету (`ScienceSubjectID.key`), дробно.
    public private(set) var credited: [String: Double] = [:]
    /// id уже доставленных результатов.
    public private(set) var delivered: Set<String> = []

    public init() {}

    /// Всего начислено за данные.
    public var total: Double { credited.values.reduce(0, +) }

    public func remaining(_ s: ScienceSubjectID) -> Double { max(0, s.cap - (credited[s.key] ?? 0)) }

    /// Ценность каждого результата при доставке по порядку (повтор предмета после первого — 0).
    public func preview(_ data: [ScienceData]) -> [Double] {
        var a = self
        return data.map { a.deliver($0) }
    }

    /// Ценность нового результата `subject`, если на борту уже лежат `stored`.
    public func valueOfNew(_ subject: ScienceSubjectID, stored: [ScienceData]) -> Double {
        var a = self
        for d in stored { a.deliver(d) }
        return a.remaining(subject)
    }

    /// Доставить результат; возвращает начисленное (0 — повтор или предел исчерпан).
    @discardableResult
    public mutating func deliver(_ d: ScienceData) -> Double {
        guard delivered.insert(d.id).inserted else { return 0 }
        let gain = remaining(d.subject)
        if gain > 0 { credited[d.subject.key, default: 0] += gain }
        return gain
    }
}

/// Почему эксперимент сейчас провести нельзя.
public enum ScienceBlocker: Sendable, Hashable {
    /// Нет прибора на корабле / нет экипажа в кабинах (для отчёта).
    case noInstrument, noCrew
    /// Здесь наука невозможна (авария) или этот прибор здесь не работает.
    case nowhere, notHere
    /// Беспилотник: прибор уже хранит результат (место — один результат на прибор).
    case instrumentFull
    /// EVA: такой предмет уже при себе или на борту; не на грунте (флаг, образец).
    case duplicate, notOnGround

    public var text: String {
        switch self {
        case .noInstrument: "нет прибора"
        case .noCrew: "нет экипажа"
        case .nowhere: "здесь нельзя"
        case .notHere: "здесь не работает"
        case .instrumentFull: "прибор занят"
        case .duplicate: "уже есть"
        case .notOnGround: "только на грунте"
        }
    }
}

/// Данные на борту активного корабля для HUD и итогов (`FlightTelemetry.science`).
public struct ScienceStatus: Sendable, Hashable {
    public var body: BodyID
    /// Ситуация здесь; nil — наука невозможна.
    public var situation: ScienceSituation?
    /// В кабинах активного корабля есть экипаж.
    public var crewAboard: Bool
    /// Приборы на активном корабле и те, у которых есть место под результат (для беспилотника).
    public var instruments: Set<ExperimentID>
    public var freeInstruments: Set<ExperimentID>
    /// Результаты в деталях активного корабля (по порядку получения) и где лежат.
    public var stored: [StoredScience]
    /// Корабль стоит на Терре: данные на борту можно вернуть.
    public var recoverable: Bool

    public init(body: BodyID = .terra, situation: ScienceSituation? = nil, crewAboard: Bool = false,
                instruments: Set<ExperimentID> = [], freeInstruments: Set<ExperimentID> = [],
                stored: [StoredScience] = [], recoverable: Bool = false) {
        self.body = body
        self.situation = situation
        self.crewAboard = crewAboard
        self.instruments = instruments
        self.freeInstruments = freeInstruments
        self.stored = stored
        self.recoverable = recoverable
    }

    public var data: [ScienceData] { stored.map(\.data) }

    /// Эксперименты, которые можно предложить на этом корабле (отчёт — при экипаже, приборы — установленные).
    public var experiments: [ExperimentID] {
        ExperimentID.allCases.filter { !$0.isEVA && ($0 == .crewReport ? crewAboard : instruments.contains($0)) }
    }

    /// Предмет эксперимента здесь; nil — нельзя (см. `blocker`).
    public func subject(_ e: ExperimentID) -> ScienceSubjectID? {
        guard blocker(e) == nil, let s = situation else { return nil }
        return ScienceSubjectID(experiment: e, body: body, situation: s)
    }

    public func blocker(_ e: ExperimentID) -> ScienceBlocker? {
        if e == .crewReport { if !crewAboard { return .noCrew } } else if !instruments.contains(e) { return .noInstrument }
        guard let s = situation else { return .nowhere }
        guard e.works(s, body: body) else { return .notHere }
        if e != .crewReport, !crewAboard, !freeInstruments.contains(e) { return .instrumentFull }
        return nil
    }
}

public struct StoredScience: Sendable, Hashable {
    public var data: ScienceData
    /// Деталь-хранилище.
    public var part: PartID

    public init(data: ScienceData, part: PartID) {
        self.data = data
        self.part = part
    }
}
