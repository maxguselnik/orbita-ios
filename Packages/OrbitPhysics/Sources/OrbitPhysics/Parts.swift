import Foundation

// MARK: - Каталог деталей (docs/SPEC.md, «Детали и ступени»)

public enum PartKind: String, Sendable, Hashable, Codable {
    case pod, probe, chute, decoupler, tank, legs, engine
    /// Блок РСУ (поступательные и поворотные сопла на монотопливе, свой запас) и бак монотоплива.
    case rcs, monoTank
}

public enum PartID: String, Sendable, Hashable, Codable, CaseIterable {
    case chute, podK1, podK3, probe, decoupler, decouplerXL
    case t100, t200, t400, t800, j64
    case legs
    case shtil, vikhr, titan, molot
    case rcsBlock, m100

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
    ]

    private static let byID: [PartID: PartSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func spec(_ id: PartID) -> PartSpec { byID[id]! }
}

/// Площадь купола парашюта × Cd при полном раскрытии, м².
public let chuteFullCdA = 700.0

// MARK: - Проект корабля

/// Корабль как стек деталей сверху вниз. Секции разделены разделителями; нижняя работает первой.
public struct VesselDesign: Sendable, Hashable, Codable {
    public var name: String
    public var parts: [PartID]

    public init(name: String, parts: [PartID]) {
        self.name = name
        self.parts = parts
    }

    public static let jump = VesselDesign(name: "Прыжок", parts: [.chute, .podK1, .decoupler, .molot])
    public static let orbit = VesselDesign(name: "Орбита", parts: [.chute, .podK1, .decoupler, .t400, .shtil,
                                                                  .decoupler, .t800, .t800, .vikhr])
    public static let luna = VesselDesign(name: "Луна", parts: [.chute, .podK1, .t800, .legs, .shtil, .decoupler,
                                                               .t800, .t800, .vikhr, .decouplerXL, .j64, .titan])
    public static let presets: [VesselDesign] = [jump, orbit, luna]

    /// Полная масса, кг.
    public var mass: Double { parts.reduce(0) { $0 + $1.spec.wetMass } }

    /// Ступени для ангара: [0] — первая (по давлению `pressure`, по умолчанию у земли), остальные — вакуум.
    public func stageInfos(pressure: Double = 1, gravity: Double = Bodies.terra.surfaceGravity) -> [StageInfo] {
        Ship(design: self).stageInfos(pressure: pressure, gravity: gravity)
    }
}

// MARK: - Корабль во время полёта

struct PartInstance: Sendable, Hashable {
    var id: PartID
    var fuel: Double
    var ignited: Bool
    var spec: PartSpec { id.spec }
}

/// Тяга и расход нижней секции за шаг.
struct ThrustResult {
    var thrust: Double = 0
    var liquidThrust: Double = 0
    var solidThrust: Double = 0
    var maxThrust: Double = 0
}

struct Ship: Sendable, Hashable {
    var parts: [PartInstance]

    init(design: VesselDesign) {
        parts = design.parts.map { PartInstance(id: $0, fuel: $0.spec.fuelMass, ignited: false) }
    }

    init(parts: [PartInstance]) { self.parts = parts }

    var mass: Double { parts.reduce(0) { $0 + $1.spec.dryMass + $1.fuel } }
    var length: Double { parts.reduce(0) { $0 + $1.spec.height } }
    var maxDiameter: Double { parts.reduce(0) { max($0, $1.spec.diameter) } }
    /// Площадь лобового сопротивления × Cd, м².
    var dragArea: Double { let w = maxDiameter > 0 ? maxDiameter : 1; return Double.pi * w * w / 4 * 0.5 }
    var hasChute: Bool { parts.contains { $0.id == .chute } }
    var hasLegs: Bool { parts.contains { $0.id == .legs } }

    /// Стабильна ли «щитом вперёд» (снизу капсула, парашют или опоры).
    var retroStable: Bool {
        guard let last = parts.last else { return false }
        switch last.spec.kind {
        case .pod, .probe, .chute, .legs: return true
        default: return false
        }
    }

    /// Допуск посадочной скорости, м/с.
    var crashTolerance: Double { hasLegs ? 12 : (retroStable ? 9 : 6) }

    /// Секции сверху вниз: диапазоны индексов; разделитель открывает секцию.
    var sections: [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        for i in parts.indices where i > 0 && parts[i].spec.kind == .decoupler {
            out.append(start..<i)
            start = i
        }
        if !parts.isEmpty { out.append(start..<parts.count) }
        return out
    }

    var bottomSection: Range<Int> { sections.last ?? 0..<0 }

    func liquidFuel(in r: Range<Int>) -> Double {
        r.reduce(0) { $0 + (parts[$1].spec.kind == .tank ? parts[$1].fuel : 0) }
    }

    /// Работают ли двигатели нижней секции (тяга > 0 при текущем дросселе).
    func isThrusting(throttle: Double) -> Bool {
        let r = bottomSection
        let liq = liquidFuel(in: r)
        for i in r {
            let p = parts[i]
            guard p.spec.kind == .engine, p.ignited else { continue }
            if p.spec.isSolid ? p.fuel > 0 : (throttle > 0 && liq > 1e-9) { return true }
        }
        return false
    }

    /// Индексы деталей-двигателей, которые сейчас дают тягу (для факела).
    func firingEngines(throttle: Double) -> [Int] {
        let r = bottomSection
        let liq = liquidFuel(in: r)
        return r.filter { i in
            let p = parts[i]
            guard p.spec.kind == .engine, p.ignited else { return false }
            return p.spec.isSolid ? p.fuel > 0 : (throttle > 0 && liq > 1e-9)
        }
    }

    /// Есть ли у зажжённых двигателей нижней секции топливо.
    func ignitedEnginesHaveFuel() -> (any: Bool, solid: Bool, liquid: Bool) {
        let r = bottomSection
        let liq = liquidFuel(in: r)
        var s = false, l = false
        for i in r {
            let p = parts[i]
            guard p.spec.kind == .engine, p.ignited else { continue }
            if p.spec.isSolid { if p.fuel > 0 { s = true } } else if liq > 1e-9 { l = true }
        }
        return (s || l, s, l)
    }

    /// Шаг двигателей нижней секции: расход топлива и тяга. `pressure` — относительное давление.
    mutating func burn(throttle: Double, pressure p: Double, dt: Double) -> ThrustResult {
        var res = ThrustResult()
        let r = bottomSection
        let liq = liquidFuel(in: r)
        var flow = 0.0
        for i in r {
            let spec = parts[i].spec
            guard spec.kind == .engine, parts[i].ignited else { continue }
            if spec.isSolid {
                if parts[i].fuel > 0 {
                    let t = spec.thrust(pressure: p)
                    let use = spec.massFlow * dt
                    let frac = use > parts[i].fuel ? parts[i].fuel / use : 1
                    res.solidThrust += t * frac
                    res.maxThrust += t
                    parts[i].fuel = max(0, parts[i].fuel - use)
                }
            } else if liq > 1e-9 {
                res.maxThrust += spec.thrust(pressure: p)
                if throttle > 0 {
                    res.liquidThrust += spec.thrust(pressure: p) * throttle
                    flow += spec.massFlow * throttle
                }
            }
        }
        if flow > 0 {
            var use = flow * dt
            if use > liq { res.liquidThrust *= liq / use; use = liq }
            for i in r where parts[i].spec.kind == .tank && parts[i].fuel > 0 {
                parts[i].fuel = max(0, parts[i].fuel - parts[i].fuel / liq * use)
            }
        }
        res.thrust = res.liquidThrust + res.solidThrust
        return res
    }

    /// Максимальная тяга и средний Isp нижней секции при давлении `p` (для прогноза прожига).
    func currentStagePerformance(pressure p: Double) -> (thrust: Double, isp: Double) {
        let r = bottomSection
        let liq = liquidFuel(in: r)
        var t = 0.0, flow = 0.0
        for i in r {
            let p0 = parts[i], spec = p0.spec
            guard spec.kind == .engine else { continue }
            if spec.isSolid ? p0.fuel <= 0 : liq <= 1e-9 { continue }
            t += spec.thrust(pressure: p)
            flow += spec.massFlow
        }
        return (t, flow > 0 ? t / (flow * standardGravity) : 0)
    }

    /// Сводка по ступеням: [0] — текущая (по давлению `pressure`), остальные — вакуум.
    func stageInfos(pressure: Double, gravity: Double) -> [StageInfo] {
        let secs = sections
        var out: [StageInfo] = []
        for (k, r) in secs.enumerated().reversed() {
            let isFirst = k == secs.count - 1
            let p = isFirst ? pressure : 0
            let m0 = parts[0..<r.upperBound].reduce(0) { $0 + $1.spec.dryMass + $1.fuel }
            var liq = 0.0, liqCap = 0.0, sol = 0.0, solCap = 0.0
            var tl = 0.0, ts = 0.0, tlVac = 0.0, tsVac = 0.0, flowL = 0.0, flowS = 0.0
            var hasSolid = false, hasLiquidEngine = false
            for i in r {
                let pi = parts[i], s = pi.spec
                if s.kind == .tank { liq += pi.fuel; liqCap += s.fuelMass }
                if s.kind == .engine {
                    if s.isSolid {
                        hasSolid = true
                        sol += pi.fuel; solCap += s.fuelMass
                        if pi.fuel > 0 { ts += s.thrust(pressure: p); tsVac += s.thrustVacuum; flowS += s.massFlow }
                    } else {
                        hasLiquidEngine = true
                        tl += s.thrust(pressure: p); tlVac += s.thrustVacuum; flowL += s.massFlow
                    }
                }
            }
            if !hasLiquidEngine || liq <= 1e-9 { tl = 0; tlVac = 0; flowL = 0 }
            let fuel = (hasLiquidEngine ? liq : 0) + sol
            let cap = (hasLiquidEngine ? liqCap : 0) + solCap
            let t = tl + ts, tVac = tlVac + tsVac
            let flow = flowL + flowS
            let isp = flow > 0 ? t / (flow * standardGravity) : 0
            let dv = isp > 0 && fuel > 0 && m0 > fuel ? isp * standardGravity * log(m0 / (m0 - fuel)) : 0
            // Время работы: жидкая часть и РДТТ по отдельности, берём большее.
            let tLiq = flowL > 0 ? (hasLiquidEngine ? liq : 0) / flowL : 0
            let tSol = flowS > 0 ? sol / flowS : 0
            out.append(StageInfo(deltaV: dv,
                                 twr: m0 > 0 && gravity > 0 ? t / (m0 * gravity) : 0,
                                 twrVacuum: m0 > 0 && gravity > 0 ? tVac / (m0 * gravity) : 0,
                                 fuelFraction: cap > 0 ? fuel / cap : 0,
                                 burnTime: max(tLiq, tSol),
                                 hasSolid: hasSolid, fuelMass: fuel, fuelCapacity: cap, hasLiquidEngine: hasLiquidEngine))
        }
        return out
    }
}
