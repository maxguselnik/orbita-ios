// Экипаж (5.4). Типы и сигнатуры — ведущий (см. docs/CONTRACTS.md, «Живой экипаж»); тела — поток A.

// MARK: - Состав

/// Роль члена экипажа (подпись в UI).
public enum CrewRole: String, Sendable, Hashable, Codable {
    case pilot, engineer, scientist, trainee

    public var title: String {
        switch self {
        case .pilot: "пилот"
        case .engineer: "инженер"
        case .scientist: "учёный"
        case .trainee: "стажёр"
        }
    }
}

/// Член экипажа. Внешность рисует UI по `id`; физика знает только характер.
public struct CrewMember: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var role: CrewRole
    /// Храбрость 0…1: храбрый позже паникует, меньше трясётся.
    public var bravery: Double
    /// Глупость 0…1: UI рисует улыбку не к месту, косоглазие; на пороги не влияет.
    public var silliness: Double

    public init(id: String, name: String, role: CrewRole, bravery: Double, silliness: Double) {
        self.id = id
        self.name = name
        self.role = role
        self.bravery = bravery
        self.silliness = silliness
    }
}

/// Отряд космонавтов (постоянный, без сохранения).
public enum CrewRoster {
    public static let standard: [CrewMember] = [
        CrewMember(id: "lera", name: "Лера", role: .pilot, bravery: 0.9, silliness: 0.2),
        CrewMember(id: "anton", name: "Антон", role: .engineer, bravery: 0.5, silliness: 0.65),
        CrewMember(id: "mira", name: "Мира", role: .scientist, bravery: 0.15, silliness: 0.1),
        CrewMember(id: "gosha", name: "Гоша", role: .trainee, bravery: 1.0, silliness: 0.95),
    ]

    public static func member(_ id: String, in roster: [CrewMember] = standard) -> CrewMember? {
        roster.first { $0.id == id }
    }
}

// MARK: - Места в кабинах проекта

/// Место в кабине проекта: деталь (`DesignPart.id`), номер места 0..<`PartSpec.crew`, кто сидит (nil — пусто).
public struct CrewSeat: Sendable, Hashable {
    public var partID: Int
    public var index: Int
    public var memberID: String?

    public init(partID: Int, index: Int, memberID: String?) {
        self.partID = partID
        self.index = index
        self.memberID = memberID
    }
}

extension VesselDesign {
    /// Все места кабин в порядке `nodes`, затем по номеру места. Явные назначения (`crewSeats`) — как есть
    /// (неизвестные отряду id → пусто, повтор одного id — только первое место); места кабин без явного назначения
    /// заполняются по порядку отряда теми, кто ещё не сидит. Лишние значения в `crewSeats` (удалённые детали,
    /// номера ≥ мест) игнорируются.
    public func seating(roster: [CrewMember] = CrewRoster.standard) -> [CrewSeat] {
        []  // A
    }

    /// Члены экипажа на местах в порядке `seating`.
    public func crew(roster: [CrewMember] = CrewRoster.standard) -> [CrewMember] {
        seating(roster: roster).compactMap { seat in seat.memberID.flatMap { CrewRoster.member($0, in: roster) } }
    }

    /// Посадить `memberID` (nil — освободить место). Сначала текущая рассадка всех кабин становится явной
    /// (`crewSeats`), затем член экипажа снимается с прежнего места и садится на новое.
    /// Неверная деталь/номер места — без изменений.
    public mutating func setSeat(partID: Int, index: Int, memberID: String?,
                                 roster: [CrewMember] = CrewRoster.standard) {
        // A
    }
}

// MARK: - Реакции в полёте

/// Настроение члена экипажа. Порядок — приоритет (выше — важнее).
public enum CrewMood: String, Sendable, Hashable, CaseIterable, Codable {
    case calm, awe, joy, strain, panic, crash

    var priority: Int {
        switch self {
        case .calm: 0
        case .awe: 1
        case .joy: 2
        case .strain: 3
        case .panic: 4
        case .crash: 5
        }
    }
}

/// Реакция члена экипажа в кадре.
public struct CrewReaction: Sendable, Hashable {
    public var memberID: String
    public var mood: CrewMood
    /// Сила 0…1: у перегрузки — по g и напору, у паники — по угрозе; UI берёт её для тряски.
    public var intensity: Double
    /// Секунд реального времени с входа в настроение (для анимации входа).
    public var moodTime: Double

    public init(memberID: String, mood: CrewMood, intensity: Double, moodTime: Double) {
        self.memberID = memberID
        self.mood = mood
        self.intensity = intensity
        self.moodTime = moodTime
    }
}

/// Одноразовый сигнал звуку и вибрации (D): член экипажа вошёл в настроение.
public struct CrewCue: Sendable, Hashable {
    public var memberID: String
    public var mood: CrewMood

    public init(memberID: String, mood: CrewMood) {
        self.memberID = memberID
        self.mood = mood
    }
}

/// Выбор настроений по телеметрии и событиям. Чистая логика, время — реальное (сек).
public struct CrewReactor: Sendable {
    public private(set) var crew: [CrewMember]
    public private(set) var reactions: [CrewReaction]

    public init(crew: [CrewMember]) {
        self.crew = crew
        reactions = crew.map { CrewReaction(memberID: $0.id, mood: .calm, intensity: 0, moodTime: 0) }
    }

    /// Шаг: `dt` — реальное время кадра (на паузе не вызывать). Возвращает сигналы входа в настроение
    /// (кроме `.calm`). Правила — docs/CONTRACTS.md, «Живой экипаж».
    public mutating func update(telemetry: FlightTelemetry, events: [SimEvent], dt: Double) -> [CrewCue] {
        []  // A
    }
}
