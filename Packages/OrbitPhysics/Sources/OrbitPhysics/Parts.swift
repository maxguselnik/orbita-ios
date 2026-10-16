import Foundation

// MARK: - Каталог деталей (docs/SPEC.md, «Детали и ступени»)

public enum PartKind: String, Sendable, Hashable, Codable {
    case pod, probe, chute, decoupler, tank, legs, engine
    /// Блок РСУ (поступательные и поворотные сопла на монотопливе, свой запас) и бак монотоплива.
    case rcs, monoTank
    /// Обтекатель (снижает сопротивление колонны, которую венчает; сбрасывается ступенью) и стабилизатор.
    case fairing, fin
    /// Теплозащитный экран (абляционное покрытие хранится в `fuelMass`).
    case heatShield
    /// Научный прибор (крепится сбоку, детей не принимает; `ExperimentID.instrument`).
    case instrument
}

/// Тип топлива (SPEC «Топливо и ориентация»): двигатель и блок РСУ берут только своё.
public enum FuelType: String, Sendable, Hashable, Codable, CaseIterable {
    case kerolox, solid, methalox, mono, gas

    public var title: String {
        switch self {
        case .kerolox: "Керосин + окислитель"
        case .solid: "Твёрдое"
        case .methalox: "Метан + окислитель"
        case .mono: "Монотопливо"
        case .gas: "Сжатый азот"
        }
    }

    /// Короткое имя для карточек и строк ангара.
    public var shortTitle: String {
        switch self {
        case .kerolox: "Керосин"
        case .solid: "Твёрдое"
        case .methalox: "Метан"
        case .mono: "Монотопливо"
        case .gas: "Азот"
        }
    }

    /// Топливо РСУ (общий запас на корабль, в Δv ступеней не входит).
    public var isRCS: Bool { self == .mono || self == .gas }
}

public enum PartID: String, Sendable, Hashable, Codable, CaseIterable {
    case chute, podK1, podK3, probe, decoupler, decouplerXL
    case t100, t200, t400, t800, j64
    case legs
    case shtil, vikhr, titan, molot
    case rcsBlock, m100
    /// Этап 5.2: боковой разделитель, обтекатели 1.25/2.5 м, стабилизатор.
    case decouplerRadial, fairing, fairingXL, fin
    /// Теплозащитные экраны 1.25 и 2.5 м.
    case heatShield, heatShieldXL
    /// Научные приборы.
    case thermometer, barometer, gravimeter
    /// Газовая РСУ: сопла «Бриз» и баллон азота А-50. Метан: баки МК-200/400, двигатель «Сполох».
    case gasJet, n50, mk200, mk400, spolokh

    public var spec: PartSpec { PartCatalog.spec(self) }
}

/// Характеристики детали. Массы — кг, тяга — Н (в вакууме), размеры — м.
public struct PartSpec: Sendable, Hashable {
    public let id: PartID
    public let name: String
    public let kind: PartKind
    public let dryMass: Double
    /// Топливо: для баков — жидкое, для РДТТ — твёрдое внутри двигателя.
    /// Для `.rcs` и `.monoTank` — монотопливо.
    public let fuelMass: Double
    public let thrustVacuum: Double
    public let ispSeaLevel: Double
    public let ispVacuum: Double
    public let isSolid: Bool
    public let crew: Int
    public let height: Double
    public let diameter: Double

    public var wetMass: Double { dryMass + fuelMass }

    /// Топливо детали: что хранит бак/блок РСУ или что берёт двигатель; nil — без топлива.
    public var fuelType: FuelType? {
        switch kind {
        case .tank: id == .mk200 || id == .mk400 ? .methalox : .kerolox
        case .engine: isSolid ? .solid : (id == .spolokh ? .methalox : .kerolox)
        case .rcs, .monoTank: id == .gasJet || id == .n50 ? .gas : .mono
        default: nil
        }
    }

    /// Как деталь крепится (контракт 5.2): капсулы, модуль, осевые разделители, парашют, опоры, обтекатели —
    /// по оси; боковой разделитель и стабилизатор — только сбоку; баки, двигатели, РСУ, монотопливо — как угодно.
    /// Предел температуры детали, К (5.2): выше — деталь разрушается. Значения — по типу детали (A уточняет).
    public var maxTemperature: Double {
        switch kind {
        case .heatShield: 3300
        case .pod, .engine, .fairing: 2400
        case .tank, .decoupler, .monoTank, .fin: 2000
        case .probe, .chute, .legs, .rcs, .instrument: 1600
        }
    }

    public var mount: PartMount {
        switch id {
        case .decouplerRadial, .fin, .thermometer, .barometer, .gravimeter: .radial
        case .t100, .t200, .t400, .t800, .j64, .shtil, .vikhr, .titan, .molot, .rcsBlock, .m100,
             .gasJet, .n50, .mk200, .mk400, .spolokh: .any
        default: .axial
        }
    }

    /// Массовый расход на полной тяге, кг/с.
    public var massFlow: Double { ispVacuum > 0 ? thrustVacuum / (ispVacuum * standardGravity) : 0 }

    /// Isp при относительном давлении `p` (1 — уровень моря Терры, 0 — вакуум).
    public func isp(pressure p: Double) -> Double { ispVacuum + (ispSeaLevel - ispVacuum) * clamp(p, 0, 1) }

    /// Тяга при давлении `p` на полной тяге (расход постоянный, тяга ∝ Isp).
    public func thrust(pressure p: Double) -> Double { massFlow * isp(pressure: p) * standardGravity }
}

public enum PartCatalog {
    private static func make(_ id: PartID, _ name: String, _ kind: PartKind, dry: Double, fuel: Double = 0,
                             thrust: Double = 0, isp: (Double, Double) = (0, 0), solid: Bool = false,
                             crew: Int = 0, h: Double, w: Double) -> PartSpec {
        PartSpec(id: id, name: name, kind: kind, dryMass: dry * 1000, fuelMass: fuel * 1000,
                 thrustVacuum: thrust * 1000, ispSeaLevel: isp.0, ispVacuum: isp.1, isSolid: solid,
                 crew: crew, height: h, diameter: w)
    }

    public static let all: [PartSpec] = [
        make(.chute, "Парашют П-16", .chute, dry: 0.1, h: 0.35, w: 0.7),
        make(.podK1, "Капсула К-1", .pod, dry: 0.84, crew: 1, h: 1.6, w: 1.25),
        make(.podK3, "Капсула К-3", .pod, dry: 2.7, crew: 3, h: 2.2, w: 2.5),
        make(.probe, "Модуль управления", .probe, dry: 0.1, h: 0.5, w: 1.25),
        make(.decoupler, "Разделитель 1.25 м", .decoupler, dry: 0.05, h: 0.25, w: 1.25),
        make(.decouplerXL, "Разделитель XL 2.5 м", .decoupler, dry: 0.2, h: 0.3, w: 2.5),
        make(.t100, "Бак Т-100", .tank, dry: 0.0625, fuel: 0.5, h: 0.55, w: 1.25),
        make(.t200, "Бак Т-200", .tank, dry: 0.125, fuel: 1, h: 1.0, w: 1.25),
        make(.t400, "Бак Т-400", .tank, dry: 0.25, fuel: 2, h: 1.85, w: 1.25),
        make(.t800, "Бак Т-800", .tank, dry: 0.5, fuel: 4, h: 3.6, w: 1.25),
        make(.j64, "Бак Ю-64", .tank, dry: 4, fuel: 32, h: 7.5, w: 2.5),
        make(.legs, "Посадочные опоры", .legs, dry: 0.15, h: 0.35, w: 1.25),
        make(.shtil, "«Штиль»", .engine, dry: 0.5, thrust: 60, isp: (85, 345), h: 0.85, w: 1.0),
        make(.vikhr, "«Вихрь»", .engine, dry: 1.5, thrust: 215, isp: (250, 320), h: 1.3, w: 1.25),
        make(.titan, "«Титан»", .engine, dry: 6, thrust: 1630, isp: (285, 310), h: 2.4, w: 2.5),
        make(.molot, "РДТТ «Молот»", .engine, dry: 0.75, fuel: 2.81, thrust: 227, isp: (170, 195), solid: true, h: 3.6, w: 1.25),
        // Блок РСУ: тяга — на одно направление (сумма сопел), Isp монотоплива.
        make(.rcsBlock, "Блок РСУ «Рой»", .rcs, dry: 0.08, fuel: 0.06, thrust: 2, isp: (100, 240), h: 0.3, w: 1.25),
        make(.m100, "Бак монотоплива М-100", .monoTank, dry: 0.04, fuel: 0.16, h: 0.45, w: 1.25),
        // Этап 5.2. Боковой разделитель: `w` — толщина плиты (от родителя наружу).
        make(.decouplerRadial, "Боковой разделитель Р-1", .decoupler, dry: 0.025, h: 0.6, w: 0.25),
        make(.fairing, "Обтекатель О-1", .fairing, dry: 0.05, h: 1.2, w: 1.25),
        make(.fairingXL, "Обтекатель О-2", .fairing, dry: 0.15, h: 2.2, w: 2.5),
        // Стабилизатор: `h` — хорда вдоль оси, `w` — размах наружу.
        make(.fin, "Стабилизатор С-1", .fin, dry: 0.04, h: 1.0, w: 0.6),
        // Теплозащитные экраны: `fuel` — абляционное покрытие.
        make(.heatShield, "Теплозащитный экран Э-1", .heatShield, dry: 0.1, fuel: 0.2, h: 0.2, w: 1.25),
        make(.heatShieldXL, "Теплозащитный экран Э-2", .heatShield, dry: 0.3, fuel: 0.8, h: 0.3, w: 2.5),
        // Научные приборы (SPEC «Наука»): `h` — высота вдоль оси, `w` — вынос от борта.
        make(.thermometer, "Термометр Т-1", .instrument, dry: 0.005, h: 0.2, w: 0.12),
        make(.barometer, "Барометр Б-1", .instrument, dry: 0.05, h: 0.3, w: 0.2),
        make(.gravimeter, "Гравиметр Г-1", .instrument, dry: 0.05, h: 0.35, w: 0.2),
        // Газовая РСУ: слабые дешёвые сопла на сжатом азоте (тяга — на одно направление) и баллон.
        make(.gasJet, "Сопла ориентации «Бриз»", .rcs, dry: 0.03, fuel: 0.01, thrust: 0.5, isp: (45, 65), h: 0.25, w: 1.25),
        make(.n50, "Баллон азота А-50", .monoTank, dry: 0.06, fuel: 0.08, h: 0.4, w: 1.25),
        // Метан + окислитель: баки легче (меньше сухая доля), выше из-за меньшей плотности; двигатель с высоким Isp.
        make(.mk200, "Бак МК-200", .tank, dry: 0.09, fuel: 1, h: 1.15, w: 1.25),
        make(.mk400, "Бак МК-400", .tank, dry: 0.18, fuel: 2, h: 2.15, w: 1.25),
        make(.spolokh, "«Сполох»", .engine, dry: 1.3, thrust: 200, isp: (280, 350), h: 1.3, w: 1.25),
    ]

    private static let byID: [PartID: PartSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func spec(_ id: PartID) -> PartSpec { byID[id]! }
}

/// Площадь купола парашюта × Cd при полном раскрытии, м².
public let chuteFullCdA = 700.0

// MARK: - Проект корабля

extension VesselDesign {
    public static let jump = VesselDesign(name: "Прыжок", parts: [.chute, .podK1, .decoupler, .molot])
    public static let orbit = VesselDesign(name: "Орбита", parts: [.chute, .podK1, .decoupler, .t400, .shtil,
                                                                  .decoupler, .t800, .t800, .vikhr])
    /// «Луна»: капсула с теплозащитным экраном Э-1 отделяется от посадочной ступени перед входом (5.2).
    public static let luna = VesselDesign(name: "Луна", parts: [.chute, .podK1, .heatShield, .decoupler, .t800, .legs,
                                                               .shtil, .decoupler, .t800, .t800, .vikhr,
                                                               .decouplerXL, .j64, .titan])
    /// «Ускорители»: ядро как у «Орбиты» без средней ступени, два РДТТ «Молот» на боковых разделителях
    /// с обтекателями сверху, четыре стабилизатора у низа ядра.
    public static let boosters: VesselDesign = {
        var n: [DesignPart] = [
            DesignPart(id: 0, part: .chute, parent: nil),
            DesignPart(id: 1, part: .podK1, parent: 0),
            DesignPart(id: 2, part: .decoupler, parent: 1),
            DesignPart(id: 3, part: .t800, parent: 2),
            DesignPart(id: 4, part: .t800, parent: 3),
            DesignPart(id: 5, part: .vikhr, parent: 4),
        ]
        for (k, a) in [0.0, 180].enumerated() {
            let dec = 6 + k, booster = 8 + k
            n.append(DesignPart(id: dec, part: .decouplerRadial, parent: 4, node: .radial, angle: a, height: 0.5,
                                symmetryGroup: 0))
            n.append(DesignPart(id: booster, part: .molot, parent: dec, node: .radial, angle: a, height: 0.5,
                                symmetryGroup: 1))
            n.append(DesignPart(id: 10 + k, part: .fairing, parent: booster, node: .top, symmetryGroup: 2))
        }
        for (k, a) in [45.0, 135, 225, 315].enumerated() {
            n.append(DesignPart(id: 12 + k, part: .fin, parent: 4, node: .radial, angle: a, height: 0.15,
                                symmetryGroup: 3))
        }
        var d = VesselDesign(name: "Ускорители", nodes: n)
        d.normalizeOrder()
        return d.autoStaged()
    }()
    public static let presets: [VesselDesign] = [jump, orbit, luna, boosters]

    /// Полная масса, кг.
    public var mass: Double { parts.reduce(0) { $0 + $1.spec.wetMass } }

    /// Δv поступательного РСУ по типу топлива (вакуум) на последней конфигурации — после всех ступеней.
    public func rcsDeltaV() -> [FuelType: Double] {
        var ship = Ship(design: self)
        for k in ship.pendingStages { ship.simulateActivation(k) }
        var out: [FuelType: Double] = [:]
        for t in FuelType.allCases where t.isRCS {
            let dv = ship.rcsDeltaV(t)
            if dv > 0 { out[t] = dv }
        }
        return out
    }

    /// Ступени для ангара: [0] — первая (по давлению `pressure`, по умолчанию у земли), остальные — вакуум.
    public func stageInfos(pressure: Double = 1, gravity: Double = Bodies.terra.surfaceGravity) -> [StageInfo] {
        Ship(design: self).stageInfos(pressure: pressure, gravity: gravity)
    }
}

