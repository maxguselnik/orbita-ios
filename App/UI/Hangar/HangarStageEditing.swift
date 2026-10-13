import OrbitPhysics

/// Строка редактора ступеней: детали ступени активации и сводка. Чистая логика без SwiftUI.
struct StageRow: Identifiable, Equatable {
    /// Значок детали; копии симметрии (одна группа) объединены и переносятся вместе.
    struct Badge: Identifiable, Equatable {
        /// id первой детали группы.
        let id: Int
        let part: PartID
        let count: Int
    }

    /// Индекс ступени с нуля (0 — первая, по кнопке «Ступень» на старте).
    let stage: Int
    let badges: [Badge]
    let info: StageInfo?

    var number: Int { stage + 1 }
    var id: Int { stage }
}

enum StageEditing {
    /// Куда бросили значок детали.
    enum Drop: Equatable {
        case stage(Int)
        /// «+ новая ступень» после последней.
        case newLast
        /// Новая ступень перед первой.
        case newFirst
    }

    private static let prefix = "stagepart:"

    /// Строки по порядку ступеней (снизу вверх: [0] — первая). `infos` — `design.stageInfos(…)` в том же порядке.
    static func rows(design: VesselDesign, infos: [StageInfo]) -> [StageRow] {
        design.stageGroups.enumerated().map { k, ids in
            var badges: [StageRow.Badge] = []
            var seenGroups: [Int: Int] = [:]
            for id in ids {
                guard let node = design.node(id) else { continue }
                if let group = node.symmetryGroup, let index = seenGroups[group] {
                    badges[index] = StageRow.Badge(id: badges[index].id, part: badges[index].part,
                                                   count: badges[index].count + 1)
                } else {
                    if let group = node.symmetryGroup { seenGroups[group] = badges.count }
                    badges.append(StageRow.Badge(id: id, part: node.part, count: 1))
                }
            }
            return StageRow(stage: k, badges: badges, info: infos.indices.contains(k) ? infos[k] : nil)
        }
    }

    /// Строка для перетаскивания значка (`.draggable`).
    static func dragItem(_ id: Int) -> String { prefix + String(id) }

    static func parse(_ item: String) -> Int? {
        guard item.hasPrefix(prefix) else { return nil }
        return Int(item.dropFirst(prefix.count))
    }

    /// Применить сброс значка; false — ничего не изменилось.
    @discardableResult
    static func apply(_ drop: Drop, id: Int, to design: inout VesselDesign) -> Bool {
        let before = design
        switch drop {
        case .stage(let k): _ = VesselEditing.setStage(id, to: k, in: &design)
        case .newLast: _ = VesselEditing.setStage(id, to: design.stageGroups.count, in: &design)
        case .newFirst: _ = VesselEditing.setStage(id, to: -1, in: &design)
        }
        return design != before
    }

    /// Подпись ступени для времени работы: «38 с», «2:10».
    static func burnText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0.5 else { return "—" }
        let s = Int(seconds.rounded())
        return s < 120 ? "\(s) с" : "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }
}
