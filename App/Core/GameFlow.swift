import Foundation
import Observation
import OrbitPhysics

/// Экраны игры, прогресс и текущий проект корабля: космоцентр ↔ цех/исследования ↔ полёт.
@MainActor
@Observable
final class GameFlow {
    enum Screen: Equatable {
        case spaceCenter, hangar, research, flight
    }

    /// Прогресс игры (режим, наука, технологии, вехи) — Documents/progress.json.
    /// nil — игра не начата: космоцентр предлагает выбрать режим (`startNewGame`).
    private(set) var progress: GameProgress? {
        didSet { if let progress, !isScenarioRun { ProgressStore.save(progress) } }
    }
    /// id проекта в Documents/ships, к которому относится `design` (nil — не сохранён).
    var shipID: String?
    /// Начисленное за текущий полёт: каждая веха — раз за полёт, перезапуск — новый счёт.
    private var flightAward = FlightAward()
    /// Игрок вышел из урока: дальше полёт обычный и даёт науку.
    private var tutorialLeft = false

    private(set) var screen: Screen
    /// Проект в ангаре; каждое изменение сохраняется в Documents.
    var design: VesselDesign {
        didSet { scheduleDesignSave() }
    }
    /// Растёт при каждом старте: RootView создаёт новый полёт по этому ключу.
    private(set) var flightID = 0
    /// Экипаж полёта (5.4): рассадка проекта или корабля урока; nil — по местам кабин корабля сцены.
    var flightCrew: [CrewMember]? {
        if let scenario { return scenario.crew }
        if let tutorial { return tutorial.design.crew() }
        return design.crew()
    }
    /// Сценарий отладки/CI (`-screen`), для обычного старта — nil.
    private(set) var scenario: DemoScenario?
    /// Текущий урок обучения (полёт идёт по уроку), nil — обычный полёт.
    private(set) var tutorial: TutorialID?

    init() {
        let saved = DesignStore.load() ?? VesselAssembly.empty
        ShipStore.migrateIfNeeded(saved)
        design = saved
        progress = ProgressStore.load()
        let scenario = DemoScenario.fromArguments
        switch scenario {
        case .hangar: design = .orbit
        case .hangarEmpty: design = VesselAssembly.empty
        case .hangarBoosters: design = .boosters
        case .hangarFuels:
            design = VesselDesign(name: "Топливо", parts: [.chute, .podK1, .gasJet, .n50, .decoupler, .mk400, .t800,
                                                          .spolokh, .vikhr])
        case .spaceCenter: progress = GameProgress(mode: .science, science: 12, milestones: [.launch, .above10km])
        case .research:
            progress = GameProgress(mode: .science, science: 37, researched: [.basics, .rocketry, .stability],
                                    milestones: [.launch, .above10km, .space, .orbit])
        default: break
        }
        if let scenario, !scenario.opensBase {
            self.scenario = scenario
            tutorial = scenario.tutorial
            screen = .flight
        } else {
            switch scenario {
            case .spaceCenter: screen = .spaceCenter
            case .research: screen = .research
            case .some: screen = .hangar
            case .none: screen = .spaceCenter
            }
        }
        if scenario != nil && progress == nil { progress = GameProgress(mode: .sandbox) }
    }

    /// Запуск с `-screen` (CI, отладка): прогресс игрока на диске не трогаем.
    private var isScenarioRun: Bool { DemoScenario.fromArguments != nil }
    @ObservationIgnored private var designSaveTask: Task<Void, Never>?

    /// Сохранение рабочего проекта с задержкой 0.4 с: плавные правки (гизмо, перетаскивание) не пишут файл каждый кадр.
    private func scheduleDesignSave() {
        designSaveTask?.cancel()
        designSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            DesignStore.save(self.design)
        }
    }

    /// Сохранить рабочий проект немедленно (уход в фон, старт полёта).
    func flushDesignSave() {
        designSaveTask?.cancel()
        designSaveTask = nil
        DesignStore.save(design)
    }

    /// Новая игра в режиме `mode` (наука и технологии с нуля).
    func startNewGame(_ mode: GameMode) {
        progress = GameProgress(mode: mode)
    }

    /// Открыть здание космоцентра / вернуться в космоцентр.
    func open(_ screen: Screen) {
        guard screen != .flight else { return launch() }
        self.screen = screen
    }

    /// Открыть технологию за науку (исследовательский центр).
    @discardableResult
    func research(_ tech: TechID) -> Bool {
        guard var p = progress, p.research(tech) else { return false }
        progress = p
        return true
    }

    /// Закрытые в текущем режиме детали проекта; не пусто — «Старт» запрещён.
    var lockedParts: [PartID] { progress?.lockedParts(in: design) ?? [] }

    /// Деталь доступна в каталоге (песочница, открытая технология, сценарии CI).
    func isUnlocked(_ part: PartID) -> Bool { progress?.isUnlocked(part) ?? true }

    /// Наука за вехи текущего полёта и за данные капсулы, стоящей на Терре: начисляет ещё не учтённое,
    /// возвращает итог полёта (итоги, «Продолжить», выход в ангар, перезапуск). Уроки и сценарии CI — без науки.
    @discardableResult
    func finishFlight(_ t: FlightTelemetry) -> FlightAwardSummary {
        guard scenario == nil, tutorial == nil || tutorialLeft, var p = progress else { return FlightAwardSummary() }
        let recovered = t.science.recoverable ? t.science.data : []
        let result = flightAward.credit(t.mission, recovered: recovered, to: &p)
        progress = p
        return FlightAwardSummary(fresh: result.fresh, science: result.science, data: flightAward.dataScience)
    }

    /// Архив начислений за данные (ценность новых результатов в панели «Наука»).
    var scienceArchive: ScienceArchive { progress?.archive ?? ScienceArchive() }

    /// «Повтор» / «Перезапуск»: начислить достигнутое, следующая попытка — новый счёт.
    func restartFlight(_ t: FlightTelemetry) {
        finishFlight(t)
        flightAward.reset()
    }

    /// «Выйти из урока»: пройденное в уроке не начисляется, дальнейшее — как в обычном полёте.
    func leaveTutorial(_ mission: MissionRecord) {
        guard tutorial != nil, !tutorialLeft else { return }
        tutorialLeft = true
        flightAward.skip(mission)
    }

    /// Сохранить текущий проект в список проектов (новый id, если ещё не сохранён).
    func saveShip() {
        shipID = ShipStore.save(design, id: shipID)
    }

    /// Открыть проект из списка.
    func openShip(_ id: String) {
        guard let d = ShipStore.load(id) else { return }
        design = d
        shipID = id
    }

    /// Новый пустой проект.
    func newShip() {
        design = VesselAssembly.empty
        shipID = nil
    }

    /// Новый полёт из текущего проекта.
    func launch() {
        guard lockedParts.isEmpty else { return }
        flushDesignSave()
        scenario = nil
        tutorial = nil
        tutorialLeft = false
        flightAward.reset()
        flightID += 1
        screen = .flight
    }

    /// Урок обучения: свой корабль урока (проект ангара не меняется), старт с площадки.
    func startTutorial(_ id: TutorialID) {
        scenario = nil
        tutorial = id
        tutorialLeft = false
        flightAward.reset()
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

/// Итог начисления за полёт для панели итогов: новые вехи, вся наука и из неё — за данные.
struct FlightAwardSummary: Equatable {
    var fresh: [Milestone] = []
    var science = 0
    var data = 0
}

/// Прогресс игры — Documents/progress.json.
enum ProgressStore {
    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("progress.json")
    }

    static func load() -> GameProgress? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GameProgress.self, from: data)
    }

    static func save(_ progress: GameProgress) {
        guard let url, let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Сохранённые проекты кораблей — Documents/ships/<id>.json.
enum ShipStore {
    struct Entry: Identifiable, Hashable {
        let id: String
        let name: String
        let partCount: Int
        let modified: Date
    }

    private static var dir: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let d = docs.appendingPathComponent("ships", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Проекты, новые сверху.
    static func list() -> [Entry] {
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let d = try? JSONDecoder().decode(VesselDesign.self, from: data) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Entry(id: url.deletingPathExtension().lastPathComponent, name: d.name, partCount: d.nodes.count, modified: date)
        }.sorted { $0.modified > $1.modified }
    }

    static func load(_ id: String) -> VesselDesign? {
        guard let url = dir?.appendingPathComponent(id + ".json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VesselDesign.self, from: data)
    }

    /// Сохранить (перезаписать `id` или новый); возвращает id.
    @discardableResult
    static func save(_ design: VesselDesign, id: String? = nil) -> String? {
        let id = id ?? UUID().uuidString
        guard let url = dir?.appendingPathComponent(id + ".json"),
              let data = try? JSONEncoder().encode(design) else { return nil }
        try? data.write(to: url, options: .atomic)
        return id
    }

    static func delete(_ id: String) {
        guard let url = dir?.appendingPathComponent(id + ".json") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Первый запуск 5.2: непустой старый проект ангара становится первым сохранённым проектом.
    static func migrateIfNeeded(_ design: VesselDesign) {
        let key = "shipsMigrated52"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !design.nodes.isEmpty && list().isEmpty { save(design) }
    }
}

/// Текущий (рабочий) проект ангара — JSON в Documents (переживает перезапуск, даже если не сохранён в список).
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

    var title: String {
        switch self {
        case .firstFlight: "Первый полёт"
        case .toLuna: "Полёт к Луне"
        }
    }

    /// Корабль урока.
    var design: VesselDesign {
        switch self {
        case .firstFlight: .orbit
        case .toLuna: .luna
        }
    }

    /// Симуляция урока: «Первый полёт» — с площадки; «К Луне» — корабль «Луна» на орбите 80 км
    /// (автопилот выводит за кадром, затем управление у игрока; откат шагов поддерживается).
    func makeSimulation() -> any FlightSimulation {
        switch self {
        case .firstFlight:
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
