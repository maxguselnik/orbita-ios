import OrbitPhysics

/// Подписи зданий космоцентра и состояние технологий: чистая логика без UI.
enum SpaceCenterLogic {
    struct Status: Equatable {
        /// Строка состояния под названием.
        var subtitle: String
        /// Здание работает (иначе серое, тап — тост «Появится на этапе N»).
        var isActive: Bool
        /// Подсветить (можно открыть технологию).
        var isAccent: Bool
    }

    /// «1 проект», «2 проекта», «5 проектов».
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m100 = n % 100
        let m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return "\(n) \(many)" }
        switch m10 {
        case 1: return "\(n) \(one)"
        case 2, 3, 4: return "\(n) \(few)"
        default: return "\(n) \(many)"
        }
    }

    /// Сколько технологий можно открыть прямо сейчас.
    static func researchableCount(_ progress: GameProgress) -> Int {
        TechTree.nodes.filter { progress.canResearch($0.id) }.count
    }

    static func status(of building: Building, progress: GameProgress?, projectCount: Int) -> Status {
        if let stage = building.comingInStage {
            return Status(subtitle: "этап \(stage)", isActive: false, isAccent: false)
        }
        switch building {
        case .hangar:
            let text = projectCount == 0 ? "новый проект" : plural(projectCount, "проект", "проекта", "проектов")
            return Status(subtitle: text, isActive: true, isAccent: false)
        case .research:
            guard let progress else { return Status(subtitle: "—", isActive: true, isAccent: false) }
            if progress.mode == .sandbox {
                return Status(subtitle: "всё открыто", isActive: true, isAccent: false)
            }
            let k = researchableCount(progress)
            if k > 0 {
                return Status(subtitle: "доступно " + plural(k, "технология", "технологии", "технологий"),
                              isActive: true, isAccent: true)
            }
            let all = TechTree.nodes.allSatisfy { progress.isResearched($0.id) }
            return Status(subtitle: all ? "всё изучено" : "нужна наука", isActive: true, isAccent: false)
        case .launchPad:
            return Status(subtitle: "старт", isActive: true, isAccent: false)
        case .missionControl, .astronauts, .tracking:
            return Status(subtitle: "", isActive: false, isAccent: false)
        }
    }

    /// Тост неактивного здания.
    static func comingText(_ building: Building) -> String {
        "Появится на этапе \(building.comingInStage ?? 0)"
    }

    /// Сообщение, если старт невозможен: закрытые детали или ошибки проекта; nil — можно лететь.
    static func launchBlock(design: VesselDesign, locked: [PartID]) -> String? {
        if !locked.isEmpty {
            let names = locked.prefix(3).map { $0.spec.name }.joined(separator: ", ")
            return "Закрыты детали: \(names). Откройте их в исследованиях"
        }
        if let issue = design.issues().first(where: \.isBlocking) {
            return issue.text + ". Соберите корабль в цехе"
        }
        return nil
    }

    /// Состояние технологии для дерева.
    enum TechState: Equatable {
        case researched, available, needsScience, locked
    }

    static func state(of tech: TechID, progress: GameProgress) -> TechState {
        if progress.isResearched(tech) { return .researched }
        if progress.canResearch(tech) { return .available }
        let node = TechTree.node(tech)
        let prerequisite = node.requires.isEmpty || node.requires.contains { progress.isResearched($0) }
        return prerequisite ? .needsScience : .locked
    }

    /// Причина, почему нельзя открыть; nil — можно или уже открыта.
    static func researchBlock(_ tech: TechID, progress: GameProgress) -> String? {
        switch state(of: tech, progress: progress) {
        case .researched, .available: nil
        case .needsScience: "нужна наука"
        case .locked: "нужна предыдущая технология"
        }
    }
}
