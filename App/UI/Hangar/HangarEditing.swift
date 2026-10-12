import OrbitPhysics

/// Правки стека деталей: чистые функции без UI. Индексы — сверху вниз, как в `VesselDesign.parts`.
enum HangarEditing {
    /// Добавляет деталь под выделенной (или вниз стека); возвращает новый индекс выделения.
    /// nil — достигнут лимит `VesselDesign.maxParts`.
    static func add(_ part: PartID, to parts: inout [PartID], selected: Int?) -> Int? {
        guard parts.count < VesselDesign.maxParts else { return nil }
        let at = selected.map { min(max($0 + 1, 0), parts.count) } ?? parts.count
        return VesselAssembly.insert(part, into: &parts, at: at)
    }

    /// Поднимает деталь на строку выше; nil — некуда.
    static func moveUp(_ parts: inout [PartID], index: Int) -> Int? {
        guard parts.indices.contains(index), index > 0 else { return nil }
        parts.swapAt(index, index - 1)
        return index - 1
    }

    /// Опускает деталь на строку ниже; nil — некуда.
    static func moveDown(_ parts: inout [PartID], index: Int) -> Int? {
        guard parts.indices.contains(index), index < parts.count - 1 else { return nil }
        parts.swapAt(index, index + 1)
        return index + 1
    }

    /// Удаляет деталь; возвращает индекс соседней (та же позиция, у последней — предыдущая), nil — стек пуст.
    @discardableResult
    static func remove(_ parts: inout [PartID], index: Int) -> Int? {
        guard parts.indices.contains(index) else { return nil }
        parts.remove(at: index)
        return parts.isEmpty ? nil : min(index, parts.count - 1)
    }

    /// Секции сверху вниз; разделитель открывает новую секцию (как `Ship.sections`).
    static func sections(of parts: [PartID]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for i in parts.indices where i > 0 && parts[i].spec.kind == .decoupler {
            out.append(start..<i)
            start = i
        }
        if !parts.isEmpty { out.append(start..<parts.count) }
        return out
    }

    /// Действительно пустой проект: первую командную деталь выбирает игрок.
    static var cleared: VesselDesign {
        VesselAssembly.empty
    }
}

/// Форматирование ангара по-русски.
enum HangarFormat {
    /// «840 кг», «2.25 т», «18.2 т».
    static func mass(_ kg: Double) -> String {
        guard kg.isFinite else { return HUDFormat.dash }
        if kg < 1_000 { return "\(Int(kg.rounded())) кг" }
        let tons = kg / 1_000
        return HUDFormat.fixed(tons, digits: tons < 10 ? 2 : 1) + " т"
    }

    /// Тяга в килоньютонах: «215 кН».
    static func thrust(_ newtons: Double) -> String {
        HUDFormat.grouped(newtons / 1_000) + " кН"
    }

    /// Две строки сведений на карточке каталога: масса; тяга и Isp; топливо.
    static func details(_ spec: PartSpec) -> [String] {
        switch spec.kind {
        case .pod, .probe:
            return [spec.crew > 0 ? "\(mass(spec.wetMass)) · экипаж \(spec.crew)" : mass(spec.wetMass)]
        case .tank:
            return ["Топливо \(mass(spec.fuelMass))", "Масса \(mass(spec.wetMass))"]
        case .engine:
            let isp = "Isp \(Int(spec.ispSeaLevel.rounded()))–\(Int(spec.ispVacuum.rounded())) с"
            return ["Тяга \(thrust(spec.thrustVacuum)) · \(isp)", spec.isSolid
                    ? "РДТТ · \(mass(spec.wetMass))" : mass(spec.wetMass)]
        case .chute, .decoupler, .legs:
            return [mass(spec.wetMass)]
        }
    }
}

/// Вкладки каталога по типу детали.
enum CatalogTab: CaseIterable, Identifiable {
    case pods, tanks, engines, misc

    var id: Self { self }

    var title: String {
        switch self {
        case .pods: "Капсулы"
        case .tanks: "Баки"
        case .engines: "Двигатели"
        case .misc: "Прочее"
        }
    }

    var systemImage: String {
        switch self {
        case .pods: "person.fill"
        case .tanks: "cylinder.fill"
        case .engines: "flame.fill"
        case .misc: "square.grid.2x2.fill"
        }
    }

    func contains(_ kind: PartKind) -> Bool {
        switch self {
        case .pods: kind == .pod || kind == .probe
        case .tanks: kind == .tank
        case .engines: kind == .engine
        case .misc: kind == .chute || kind == .decoupler || kind == .legs
        }
    }

    var parts: [PartSpec] { PartCatalog.all.filter { contains($0.kind) } }
}
