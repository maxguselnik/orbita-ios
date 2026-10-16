import Foundation
import OrbitPhysics

/// Условия, для которых цех считает Δv и TWR.
enum HangarEnvironment: CaseIterable, Identifiable {
    case terra, vacuum, luna

    var id: Self { self }

    var title: String {
        switch self {
        case .terra: "Терра · атм"
        case .vacuum: "Вакуум"
        case .luna: "Луна"
        }
    }

    /// Относительное давление для `stageInfos` (1 — уровень моря Терры).
    var pressure: Double { self == .terra ? 1 : 0 }

    /// Ускорение свободного падения для TWR.
    var gravity: Double { self == .luna ? Bodies.luna.surfaceGravity : Bodies.terra.surfaceGravity }
}

/// Форматирование цеха по-русски.
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

    /// Размеры: «Ø 1.25 м · 1.2 м».
    static func size(_ spec: PartSpec) -> String {
        "Ø " + HUDFormat.fixed(spec.diameter, digits: 2) + " м · " + HUDFormat.fixed(spec.height, digits: 1) + " м"
    }

    private static func fuelName(_ spec: PartSpec, fallback: String) -> String {
        spec.fuelType?.shortTitle ?? fallback
    }

    /// Две строки сведений на карточке каталога: масса; тяга и Isp; топливо.
    static func details(_ spec: PartSpec) -> [String] {
        switch spec.kind {
        case .pod, .probe:
            return [spec.crew > 0 ? "\(mass(spec.wetMass)) · экипаж \(spec.crew)" : mass(spec.wetMass)]
        case .tank:
            return ["\(fuelName(spec, fallback: "Топливо")) \(mass(spec.fuelMass))", "Масса \(mass(spec.wetMass))"]
        case .engine:
            let isp = "Isp \(Int(spec.ispSeaLevel.rounded()))–\(Int(spec.ispVacuum.rounded())) с"
            return ["Тяга \(thrust(spec.thrustVacuum)) · \(isp)", spec.isSolid
                    ? "РДТТ · \(mass(spec.wetMass))"
                    : spec.fuelType.map { "\($0.shortTitle) · \(mass(spec.wetMass))" } ?? mass(spec.wetMass)]
        case .rcs:
            return ["\(fuelName(spec, fallback: "Монотопливо")) \(mass(spec.fuelMass)) · сопла \(thrust(spec.thrustVacuum))", mass(spec.wetMass)]
        case .monoTank:
            return ["\(fuelName(spec, fallback: "Монотопливо")) \(mass(spec.fuelMass))", "Масса \(mass(spec.wetMass))"]
        case .heatShield:
            return ["Покрытие \(mass(spec.fuelMass))", "Масса \(mass(spec.wetMass))"]
        case .chute, .decoupler, .legs, .fairing, .fin:
            return [mass(spec.wetMass)]
        case .instrument:
            let e = ExperimentID.allCases.first { $0.instrument == spec.id }
            return [mass(spec.wetMass), e.map { "Работает \($0.whereItWorks)" } ?? ""]
        }
    }

    /// Предел температуры: «до 1200 К».
    static func limit(_ spec: PartSpec) -> String {
        "до \(Int(spec.maxTemperature.rounded())) К"
    }

    /// Короткое пояснение, как деталь крепится.
    static func mountText(_ spec: PartSpec) -> String {
        switch spec.mount {
        case .axial: "по оси"
        case .radial: "только сбоку"
        case .any: "по оси или сбоку"
        }
    }
}

/// Вкладки каталога по типу детали.
enum CatalogTab: CaseIterable, Identifiable {
    case pods, tanks, engines, decouplers, aero, rcs, legs, science

    var id: Self { self }

    var title: String {
        switch self {
        case .pods: "Капсулы"
        case .tanks: "Баки"
        case .engines: "Двигатели"
        case .decouplers: "Разделители"
        case .aero: "Аэро"
        case .rcs: "РСУ"
        case .legs: "Опоры"
        case .science: "Наука"
        }
    }

    var systemImage: String {
        switch self {
        case .pods: "person.fill"
        case .tanks: "cylinder.fill"
        case .engines: "flame.fill"
        case .decouplers: "arrow.up.and.down.square"
        case .aero: "wind"
        case .rcs: "dot.arrowtriangles.up.right.down.left.circle"
        case .legs: "arrow.down.to.line"
        case .science: "flask"
        }
    }

    func contains(_ kind: PartKind) -> Bool {
        switch self {
        case .pods: kind == .pod || kind == .probe || kind == .chute
        case .tanks: kind == .tank || kind == .monoTank
        case .engines: kind == .engine
        case .decouplers: kind == .decoupler
        case .aero: kind == .fairing || kind == .fin || kind == .heatShield
        case .rcs: kind == .rcs
        case .legs: kind == .legs
        case .science: kind == .instrument
        }
    }

    var parts: [PartSpec] { PartCatalog.all.filter { contains($0.kind) } }

    /// Детали для списка: при непустом поиске — по всем вкладкам.
    static func parts(tab: CatalogTab, query: String) -> [PartSpec] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tab.parts }
        return PartCatalog.all.filter { $0.name.lowercased().contains(q) }
    }
}
