import Foundation
import Observation
import OrbitPhysics

/// Экраны игры и текущий проект корабля: ангар ↔ полёт.
@MainActor
@Observable
final class GameFlow {
    enum Screen: Equatable {
        case hangar, flight
    }

    private(set) var screen: Screen
    /// Проект в ангаре; каждое изменение сохраняется в Documents.
    var design: VesselDesign {
        didSet { DesignStore.save(design) }
    }
    /// Растёт при каждом старте: RootView создаёт новый полёт по этому ключу.
    private(set) var flightID = 0
    /// Сценарий отладки/CI (`-screen`), для обычного старта — nil.
    private(set) var scenario: DemoScenario?

    init() {
        design = DesignStore.load() ?? .orbit
        let scenario = DemoScenario.fromArguments
        if let scenario, scenario != .hangar {
            self.scenario = scenario
            screen = .flight
        } else {
            screen = .hangar
        }
    }

    /// Новый полёт из текущего проекта.
    func launch() {
        scenario = nil
        flightID += 1
        screen = .flight
    }

    func returnToHangar() {
        scenario = nil
        screen = .hangar
    }

    /// Фабрика симуляции для текущего полёта (перезапуск — тот же проект или сценарий).
    func makeSimulation() -> any FlightSimulation {
        if let scenario { return scenario.makeSimulation() }
        return FlightSim(design: design)
    }
}

/// Последний проект ангара — JSON в Documents.
enum DesignStore {
    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("hangar.json")
    }

    static func load() -> VesselDesign? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VesselDesign.self, from: data)
    }

    static func save(_ design: VesselDesign) {
        guard let url, let data = try? JSONEncoder().encode(design) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
