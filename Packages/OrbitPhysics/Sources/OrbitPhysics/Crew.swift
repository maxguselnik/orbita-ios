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
        var explicit: [Int: [String?]] = [:]
        var seated = Set<String>()
        let cabins = nodes.filter { $0.part.spec.crew > 0 }
        for cab in cabins {
            guard let rec = crewSeats[cab.id] else { continue }
            let n = cab.part.spec.crew
            var row: [String?] = []
            for i in 0..<n {
                var m: String? = i < rec.count ? rec[i] : nil
                if let id = m, CrewRoster.member(id, in: roster) == nil || seated.contains(id) { m = nil }
                if let id = m { seated.insert(id) }
                row.append(m)
            }
            explicit[cab.id] = row
        }
        var queue = roster.map(\.id).filter { !seated.contains($0) }[...]
        var result: [CrewSeat] = []
        for cab in cabins {
            for i in 0..<cab.part.spec.crew {
                if let row = explicit[cab.id] {
                    result.append(CrewSeat(partID: cab.id, index: i, memberID: row[i]))
                } else {
                    result.append(CrewSeat(partID: cab.id, index: i, memberID: queue.popFirst()))
                }
            }
        }
        return result
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
        guard let part = node(partID), index >= 0, index < part.part.spec.crew else { return }
        let current = seating(roster: roster)
        var seats: [Int: [String?]] = [:]
        for seat in current {
            var row = seats[seat.partID] ?? []
            row.append(seat.memberID)
            seats[seat.partID] = row
        }
        if let id = memberID {
            for (pid, row) in seats {
                seats[pid] = row.map { $0 == id ? nil : $0 }
            }
        }
        seats[partID]?[index] = memberID
        crewSeats = seats
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

    private struct CueKey: Hashable, Sendable {
        var id: String
        var mood: CrewMood
    }
    private var clock = 0.0
    private var lastCue: [CueKey: Double] = [:]
    private var maxPressure = 0.0
    private var wasSpace = false
    private var wasOrbiting = false
    /// Первый кадр: полёт может начаться уже на орбите или в космосе — это не повод для восторга и «ура».
    private var started = false
    private var crashed = false
    private var destroyedTimer = 0.0
    private var maxQTimer = 0.0
    private var joyTimer = 0.0
    private var aweTimer = 0.0

    public init(crew: [CrewMember]) {
        self.crew = crew
        reactions = crew.map { CrewReaction(memberID: $0.id, mood: .calm, intensity: 0, moodTime: 0) }
    }

    /// Шаг: `dt` — реальное время кадра (на паузе не вызывать). Возвращает сигналы входа в настроение
    /// (кроме `.calm`). Правила — docs/CONTRACTS.md, «Живой экипаж».
    public mutating func update(telemetry: FlightTelemetry, events: [SimEvent], dt: Double) -> [CrewCue] {
        clock += dt
        let t = telemetry
        for e in events {
            switch e {
            case .crash: crashed = true
            case .partDestroyed: destroyedTimer = 4
            case .maxQ: maxQTimer = 2
            case .touchdown, .splashdown: if !crashed { joyTimer = max(joyTimer, 6) }
            default: break
            }
        }
        if t.situation == .crashed { crashed = true }
        let grounded = t.situation == .prelaunch || t.situation == .landed || t.situation == .splashed
        if !started {
            started = true
            wasOrbiting = t.situation == .orbiting
            wasSpace = t.atmosphereDensity == 0 && !grounded
        }
        if t.situation == .orbiting, !wasOrbiting {
            wasOrbiting = true
            if !crashed { joyTimer = max(joyTimer, 4) }
        }
        let inSpace = t.atmosphereDensity == 0 && !grounded
        if inSpace, !wasSpace {
            wasSpace = true
            aweTimer = 6
        }
        maxPressure = max(maxPressure, t.dynamicPressure)
        let weightless = inSpace && t.gForce < 0.1 && t.thrust == 0

        var cues: [CrewCue] = []
        for i in reactions.indices {
            let m = crew[i]
            let f = 1 + 0.5 * (1 - m.bravery)
            var r = reactions[i]
            r.moodTime += dt
            var cand: (CrewMood, Double) = (.calm, 0)
            if crashed {
                cand = (.crash, 1)
            } else {
                var panic: Double?
                let hot = t.thermal.hottest
                if hot > 0.7 / f { panic = hot }
                if destroyedTimer > 0 { panic = max(panic ?? 0, 0.6) }
                if t.chute != .open, !grounded, t.verticalSpeed < -22 / f {
                    let tti = t.heightAboveTerrain / -t.verticalSpeed
                    if tti < 8 * f { panic = max(panic ?? 0, 1 - tti / (8 * f)) }
                }
                if let p = panic {
                    cand = (.panic, min(1, max(0.6, p)))
                } else if t.gForce > 2.5 / f || maxQTimer > 0
                            || (maxPressure >= 15_000 && t.dynamicPressure > 0.7 * maxPressure) {
                    cand = (.strain, min(1, max(0, max((t.gForce - 1) / 4, t.dynamicPressure / 40_000))))
                } else if joyTimer > 0 {
                    cand = (.joy, 1)
                } else if aweTimer > 0 {
                    cand = (.awe, 1)
                } else if weightless {
                    cand = (.awe, 0.5)
                }
            }
            if cand.0 == r.mood {
                r.intensity = cand.1
            } else if cand.0.priority > r.mood.priority || r.moodTime >= 1.5 {
                r.mood = cand.0
                r.intensity = cand.1
                r.moodTime = 0
                if r.mood != .calm {
                    let key = CueKey(id: m.id, mood: r.mood)
                    if lastCue[key].map({ clock - $0 >= 3 }) ?? true {
                        lastCue[key] = clock
                        cues.append(CrewCue(memberID: m.id, mood: r.mood))
                    }
                }
            }
            reactions[i] = r
        }
        destroyedTimer = max(0, destroyedTimer - dt)
        maxQTimer = max(0, maxQTimer - dt)
        joyTimer = max(0, joyTimer - dt)
        aweTimer = max(0, aweTimer - dt)
        return cues
    }
}
