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
    /// Текущий урок обучения (полёт идёт по уроку), nil — обычный полёт.
    private(set) var tutorial: TutorialID?

    init() {
        design = DesignStore.load() ?? VesselAssembly.empty
        let scenario = DemoScenario.fromArguments
        if scenario == .hangar { design = .orbit }
        if scenario == .hangarEmpty { design = VesselAssembly.empty }
        if let scenario, scenario != .hangar, scenario != .hangarEmpty {
            self.scenario = scenario
            tutorial = scenario.tutorial
            screen = .flight
        } else {
            screen = .hangar
        }
    }

    /// Новый полёт из текущего проекта.
    func launch() {
        scenario = nil
        tutorial = nil
        flightID += 1
        screen = .flight
    }

    /// Урок обучения: свой корабль урока (проект ангара не меняется), старт с площадки.
    func startTutorial(_ id: TutorialID) {
        scenario = nil
        tutorial = id
        TutorialProgress.markOffered()
        flightID += 1
        screen = .flight
    }

    func returnToHangar() {
        scenario = nil
        tutorial = nil
        screen = .hangar
    }

    /// Фабрика симуляции для текущего полёта (перезапуск — тот же проект или сценарий).
    func makeSimulation() -> any FlightSimulation {
        if let scenario { return scenario.makeSimulation() }
        if let tutorial { return tutorial.makeSimulation() }
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

/// Уроки обучения.
enum TutorialID: String, CaseIterable, Sendable {
    /// «Первый полёт»: от площадки до орбиты 80 км за руку.
    case firstFlight
    /// «Полёт к Луне»: с орбиты 80 км — карта, узел, прожиг, захват, посадка.
    case toLuna
    /// «Все кнопки»: тур по каждому элементу HUD и карты.
    case controls

    var title: String {
        switch self {
        case .firstFlight: "Первый полёт"
        case .toLuna: "Полёт к Луне"
        case .controls: "Все кнопки"
        }
    }

    /// Корабль урока.
    var design: VesselDesign {
        switch self {
        case .firstFlight, .controls: .orbit
        case .toLuna: .luna
        }
    }

    /// Симуляция урока: «Первый полёт» и тур — с площадки; «К Луне» — корабль «Луна» на орбите 80 км
    /// (автопилот выводит за кадром, затем управление у игрока; откат шагов поддерживается).
    func makeSimulation() -> any FlightSimulation {
        switch self {
        case .firstFlight, .controls:
            return FlightSim(design: design)
        case .toLuna:
            return ScenarioFlight(design: design, goal: .orbit, keepAutopilot: false) { _, ap in ap.isFinished }
        }
    }
}

/// Прогресс обучения — UserDefaults (флаги, не сохранение полёта).
enum TutorialProgress {
    static let offeredKey = "tutorialFirstFlightOffered"
    static let doneKey = "tutorialFirstFlightDone"

    /// Предложение «Первый полёт» при первом запуске уже показано (принято или отклонено).
    static var wasOffered: Bool { UserDefaults.standard.bool(forKey: offeredKey) }
    static func markOffered() { UserDefaults.standard.set(true, forKey: offeredKey) }

    static var isFirstFlightDone: Bool { isDone(.firstFlight) }
    static func markFirstFlightDone() { markDone(.firstFlight) }

    /// Урок пройден до итога.
    static func isDone(_ id: TutorialID) -> Bool { UserDefaults.standard.bool(forKey: key(id)) }
    static func markDone(_ id: TutorialID) { UserDefaults.standard.set(true, forKey: key(id)) }

    private static func key(_ id: TutorialID) -> String {
        id == .firstFlight ? doneKey : "tutorialDone." + id.rawValue
    }
}
