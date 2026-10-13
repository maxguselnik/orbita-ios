import Observation
import OrbitPhysics

/// Экипаж в полёте (5.4): настроения по телеметрии и событиям для HUD, сигналы реакций — звуку и вибрации.
/// Наблюдаемое `states` меняется только при смене настроения или силы (шаг 0.1), не каждый кадр.
@MainActor
@Observable
final class CrewModel {
    /// Состояние портрета: кто, настроение, сила 0…1 (шаг 0.1).
    struct State: Equatable, Identifiable {
        var member: CrewMember
        var mood: CrewMood
        var intensity: Double
        var id: String { member.id }
    }

    private(set) var states: [State]
    /// Принудительное настроение всех (сцены CI); nil — по реактору.
    var override: CrewMood? {
        didSet { publish() }
    }
    @ObservationIgnored private var reactor: CrewReactor

    /// `crew` — экипаж корабля; пусто — портретов нет.
    init(crew: [CrewMember], override: CrewMood? = nil) {
        reactor = CrewReactor(crew: crew)
        self.override = override
        states = []
        publish()
    }

    /// Экипаж по местам кабин в деталях корабля (уроки, сцены без явного экипажа): по порядку отряда.
    static func crew(forParts parts: [PartID], roster: [CrewMember] = CrewRoster.standard) -> [CrewMember] {
        let seats = parts.reduce(0) { $0 + $1.spec.crew }
        return Array(roster.prefix(seats))
    }

    var isEmpty: Bool { states.isEmpty }

    /// Перезапуск полёта: тот же экипаж, настроения с нуля.
    func reset() {
        reactor = CrewReactor(crew: reactor.crew)
        publish()
    }

    /// Кадр полёта после `advance` (на паузе не вызывать). Возвращает сигналы для звука и вибрации.
    func update(telemetry: FlightTelemetry, events: [SimEvent], dt: Double) -> [CrewCue] {
        guard !reactor.crew.isEmpty else { return [] }
        let cues = reactor.update(telemetry: telemetry, events: events, dt: dt)
        publish()
        return override == nil ? cues : []
    }

    private func publish() {
        let next = zip(reactor.crew, reactor.reactions).map { member, reaction in
            State(member: member, mood: override ?? reaction.mood,
                  intensity: override.map { _ in 1 } ?? (reaction.intensity * 10).rounded() / 10)
        }
        if next != states { states = next }
    }
}
