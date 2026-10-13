import Foundation

// MARK: - Корабль во время полёта (дерево деталей, контракт 5.2)

struct PartInstance: Sendable, Hashable {
    var id: PartID
    var fuel: Double
    var ignited: Bool
    /// id детали в проекте (`DesignPart.id`), родитель (id), узел крепления.
    var uid: Int
    var parent: Int?
    var node: AttachNode
    /// Ступень активации (индекс в `VesselDesign.stageGroups`); nil — не активируется.
    var stage: Int?
    /// Положение в осях корабля; начало — `Vessel.r` (ось корня, нижняя точка).
    var placement: PartPlacement
    /// Температура детали, К.
    var temperature: Double = Ship.ambientTemperature
    var spec: PartSpec { id.spec }
}

/// Тяга и расход за шаг.
struct ThrustResult {
    var thrust: Double = 0
    var liquidThrust: Double = 0
    var solidThrust: Double = 0
    var maxThrust: Double = 0
    /// Момент тяги относительно центра масс в осях корабля, Н·м (у соосного корабля — ноль).
    var torque: Vec3 = .zero
    /// Вектор тяги в осях корабля, Н; nil — вся тяга строго по +Y (`thrust`).
    var force: Vec3?
}

/// Источник топлива двигателя: своё (РДТТ) или группа баков, связанных без разделителей.
enum FuelSource: Hashable {
    case solid(Int)
    case group(Int)
}

struct Ship: Sendable, Hashable {
    /// Детали в порядке обхода дерева (для линейного стека — сверху вниз).
    var parts: [PartInstance]
    /// Детали каждой ступени активации проекта (для `StageInfo.parts`).
    var stageParts: [[PartID]]
    /// Последняя сработавшая ступень; nil — ни одной.
    var lastStage: Int?
    /// Группа топлива каждой детали (−1 — разделитель); пересчитывается при смене состава.
    private(set) var group: [Int] = []
    /// Площадь сопротивления × Cd (по колоннам), м².
    private(set) var dragArea: Double = 0
    private(set) var finCount = 0

    init(design: VesselDesign) {
        let lay = design.layout()
        let groups = design.stageGroups
        var stageOf: [Int: Int] = [:]
        for (k, g) in groups.enumerated() { for id in g { stageOf[id] = k } }
        parts = design.nodes.enumerated().map { i, n in
            PartInstance(id: n.part, fuel: n.part.spec.fuelMass, ignited: false, uid: n.id, parent: n.parent,
                         node: n.node, stage: stageOf[n.id], placement: lay[i])
        }
        stageParts = groups.map { g in g.compactMap { design.node($0)?.part } }
        lastStage = nil
        rebuildCaches()
    }

    private init(parts: [PartInstance], stageParts: [[PartID]], lastStage: Int?) {
        self.parts = parts
        self.stageParts = stageParts
        self.lastStage = lastStage
        rebuildCaches()
    }

    // MARK: Состав

    mutating func rebuildCaches() {
        var index: [Int: Int] = [:]
        for (i, p) in parts.enumerated() { index[p.uid] = i }
        // Группы топлива: компоненты связности без разделителей.
        var g = Array(repeating: -1, count: parts.count)
        var next = 0
        var adj = Array(repeating: [Int](), count: parts.count)
        for (i, p) in parts.enumerated() {
            if let pid = p.parent, let j = index[pid] { adj[i].append(j); adj[j].append(i) }
        }
        for i in parts.indices where g[i] < 0 && parts[i].spec.kind != .decoupler {
            var stack = [i]
            g[i] = next
            while let x = stack.popLast() {
                for y in adj[x] where g[y] < 0 && parts[y].spec.kind != .decoupler {
                    g[y] = next
                    stack.append(y)
                }
            }
            next += 1
        }
        group = g
        // Колонны: детали, связанные осевыми узлами; стабилизаторы и боковые разделители — отдельно.
        var col = Array(repeating: -1, count: parts.count)
        func inColumn(_ i: Int) -> Bool { parts[i].spec.kind != .fin && parts[i].id != .decouplerRadial }
        var nc = 0
        for i in parts.indices where col[i] < 0 && inColumn(i) {
            var stack = [i]
            col[i] = nc
            while let x = stack.popLast() {
                for y in adj[x] where col[y] < 0 && inColumn(y) {
                    let child = parts[y].parent == parts[x].uid ? y : x
                    guard parts[child].node != .radial else { continue }
                    col[y] = nc
                    stack.append(y)
                }
            }
            nc += 1
        }
        var area = 0.0
        for c in 0..<nc {
            var w = 0.0
            var topIndex = -1
            for i in parts.indices where col[i] == c {
                w = max(w, parts[i].spec.diameter)
                if topIndex < 0 || parts[i].placement.top > parts[topIndex].placement.top { topIndex = i }
            }
            var a = Double.pi * w * w / 4 * 0.5
            if topIndex >= 0 && parts[topIndex].spec.kind == .fairing { a *= 0.7 }
            area += a
        }
        finCount = parts.reduce(0) { $0 + ($1.spec.kind == .fin ? 1 : 0) }
        if area <= 0 { area = Double.pi / 4 * 0.5 }
        if finCount > 0 { area += Double(finCount) * 0.05 }
        dragArea = area
    }

    func index(of uid: Int) -> Int? { parts.firstIndex { $0.uid == uid } }

    /// id детали и её потомков (на корабле).
    func subtree(_ uid: Int) -> Set<Int> {
        var out: Set<Int> = []
        var stack = [uid]
        while let x = stack.popLast() {
            guard out.insert(x).inserted else { continue }
            for p in parts where p.parent == x { stack.append(p.uid) }
        }
        return out
    }

    /// Начало координат набора деталей: ось корня у самой нижней точки.
    private static func origin(_ ps: [PartInstance]) -> Vec3 {
        let uids = Set(ps.map(\.uid))
        let root = ps.first { $0.parent.map { !uids.contains($0) } ?? true }
        let minBottom = ps.map(\.placement.lowest).min() ?? 0
        let c = root?.placement.center ?? .zero
        return Vec3(c.x, minBottom, c.z)
    }

    /// Отделить детали `uids` в новый корабль. Возвращает обломок, его начало и сдвиг начала оставшегося
    /// корабля — оба в прежних осях корабля.
    mutating func split(removing uids: Set<Int>) -> (debris: Ship, debrisOrigin: Vec3, shift: Vec3) {
        var gone = parts.filter { uids.contains($0.uid) }
        var keep = parts.filter { !uids.contains($0.uid) }
        for i in gone.indices where gone[i].parent.map({ !uids.contains($0) }) ?? false { gone[i].parent = nil }
        let dOrigin = Self.origin(gone)
        let shift = keep.isEmpty ? Vec3.zero : Self.origin(keep)
        for i in gone.indices { gone[i].placement.center -= dOrigin }
        if shift != .zero { for i in keep.indices { keep[i].placement.center -= shift } }
        parts = keep
        rebuildCaches()
        return (Ship(parts: gone, stageParts: stageParts, lastStage: lastStage), dOrigin, shift)
    }

    /// Сбросить одну деталь (обтекатель): её дети переходят к её родителю (у корня — первый ребёнок
    /// становится корнем).
    mutating func eject(_ uid: Int) -> (debris: Ship, debrisOrigin: Vec3, shift: Vec3)? {
        // Последнюю деталь корабля не сбрасываем.
        guard parts.count > 1, let i = index(of: uid) else { return nil }
        let p = parts[i]
        var newParent = p.parent
        for k in parts.indices where parts[k].parent == uid {
            if newParent == nil {
                parts[k].parent = nil
                newParent = parts[k].uid
            } else {
                parts[k].parent = newParent
                if p.parent != nil { parts[k].node = p.node }
            }
        }
        return split(removing: [uid])
    }

    // MARK: Масса и форма

    var mass: Double { parts.reduce(0) { $0 + $1.spec.dryMass + $1.fuel } }
    var maxDiameter: Double { parts.reduce(0) { max($0, $1.spec.diameter) } }
    var hasChute: Bool { parts.contains { $0.id == .chute } }
    var hasLegs: Bool { parts.contains { $0.id == .legs } }

    /// Центр масс в осях корабля.
    var centerOfMass: Vec3 {
        var m = 0.0
        var c = Vec3.zero
        for p in parts {
            let w = p.spec.dryMass + p.fuel
            m += w
            c += p.placement.center * w
        }
        return m > 0 ? c / m : .zero
    }

    /// Момент инерции относительно поперечной оси через ЦМ (детали — сплошные цилиндры), кг·м².
    func transverseInertia(about cm: Vec3) -> Double {
        var i = 0.0
        for p in parts {
            let m = p.spec.dryMass + p.fuel
            let r = p.placement.diameter / 2
            let h = p.placement.height
            let d = p.placement.center - cm
            i += m * ((3 * r * r + h * h) / 12 + d.y * d.y + (d.x * d.x + d.z * d.z) / 2)
        }
        return max(i, 1)
    }

    /// Момент инерции относительно продольной оси (Y) через ЦМ, кг·м².
    func axialInertia(about cm: Vec3) -> Double {
        var i = 0.0
        for p in parts {
            let m = p.spec.dryMass + p.fuel
            let r = p.placement.diameter / 2
            let d = p.placement.center - cm
            i += m * (r * r / 2 + d.x * d.x + d.z * d.z)
        }
        return max(i, 1)
    }

    /// Стабилизаторы ниже центра масс.
    var finsBelowCenterOfMass: Int {
        guard finCount > 0 else { return 0 }
        let cy = centerOfMass.y
        return parts.reduce(0) { $0 + ($1.spec.kind == .fin && $1.placement.center.y < cy ? 1 : 0) }
    }

    /// Стабильна ли «щитом вперёд» (снизу капсула, парашют или опоры; стабилизаторы ниже ЦМ — нет).
    var retroStable: Bool {
        if finsBelowCenterOfMass > 0 { return false }
        var lowest: PartInstance?
        for p in parts where p.spec.kind != .fin {
            if lowest == nil || p.placement.bottom < lowest!.placement.bottom - 1e-9 { lowest = p }
        }
        guard let last = lowest else { return false }
        switch last.spec.kind {
        case .pod, .probe, .chute, .legs, .heatShield: return true
        default: return false
        }
    }

    /// Допуск посадочной скорости, м/с.
    var crashTolerance: Double { hasLegs ? 12 : (retroStable ? 9 : 6) }

    /// Разделители, которые ещё могут отделить что-то (не корень) — номер в событиях ступеней.
    var decouplerCount: Int { parts.reduce(0) { $0 + ($1.spec.kind == .decoupler && $1.parent != nil ? 1 : 0) } }

    // MARK: Нагрев (5.2)

    /// Окружающая (равновесная) температура, К.
    static let ambientTemperature = 290.0
    /// Удельная теплоёмкость деталей, Дж/(кг·К).
    static let specificHeat = 800.0
    /// Излучательная способность (игровая, малая: нагрев копится за проход) × постоянная Стефана — Больцмана.
    static let emissivitySigma = 0.1 * 5.670374419e-8
    /// Теплопроводность стыка родитель — ребёнок, Вт/К.
    static let conductance = 30.0
    /// Доля потока, которая достаётся заслонённой детали.
    static let shadowedFraction = 0.1
    /// Экран к потоку: доля тепла, уносимая абляцией, и теплота абляции покрытия, Дж/кг.
    static let ablationShare = 0.9
    static let ablationHeat = 6e7
    /// Предел экрана без покрытия, К.
    static let bareShieldLimit = 2000.0

    /// Предел температуры детали `i`, К (экран без покрытия — как обычная деталь).
    func temperatureLimit(_ i: Int) -> Double {
        parts[i].spec.kind == .heatShield && parts[i].fuel <= 1e-9 ? Self.bareShieldLimit : parts[i].spec.maxTemperature
    }

    /// Нагрев деталей 0…1 (температура / предел), индексы — `parts`.
    var partHeat: [Double] { parts.indices.map { parts[$0].temperature / temperatureLimit($0) } }

    /// Абляционное покрытие экранов и его ёмкость, кг.
    var ablator: (mass: Double, capacity: Double) {
        parts.reduce((0, 0)) { $1.spec.kind == .heatShield ? ($0.0 + $1.fuel, $0.1 + $1.spec.fuelMass) : $0 }
    }

    /// Заслонённость деталей потоком `d` (единичный, оси корабля, по воздушной скорости): для каждой —
    /// наибольший диаметр детали впереди по потоку, перекрывающей её ось (0 — открыта). Деталь не меньшего
    /// диаметра заслоняет целиком, меньшая — только середину торца.
    func shadowDiameters(flow d: Vec3) -> [Double] {
        parts.indices.map { i in
            let ci = parts[i].placement.center
            var best = 0.0
            for j in parts.indices where j != i {
                let rel = parts[j].placement.center - ci
                let along = rel.dot(d)
                guard along > 0.01 else { continue }
                let dj = parts[j].placement.diameter
                if dj > best && (rel - d * along).length <= dj / 2 { best = dj }
            }
            return best
        }
    }

    /// Открыта ли деталь потоку целиком (её никто не заслоняет деталью не меньшего диаметра).
    func exposure(flow d: Vec3) -> [Bool] {
        let sh = shadowDiameters(flow: d)
        return parts.indices.map { sh[$0] < parts[$0].placement.diameter - 1e-9 }
    }

    /// Площадь детали, на которую приходит поток, с учётом заслонения, м²: открытая часть торца и бок —
    /// полностью, заслонённая — долей `shadowedFraction`.
    func heatedArea(_ i: Int, flow d: Vec3, shadow: Double) -> Double {
        let pl = parts[i].placement
        let c = min(1, abs(pl.orientation.rotate(.unitY).dot(d)))
        let cap = Double.pi * pl.diameter * pl.diameter / 4 * c
        let side = pl.diameter * pl.height * (1 - c * c).squareRoot()
        if shadow >= pl.diameter - 1e-9 { return (cap + side) * Self.shadowedFraction }
        let covered = shadow > 0 ? min(1, (shadow / pl.diameter) * (shadow / pl.diameter)) : 0
        return cap * (1 - covered) + cap * covered * Self.shadowedFraction + side
    }

    func surfaceArea(_ i: Int) -> Double {
        let pl = parts[i].placement
        return Double.pi * pl.diameter * pl.height + Double.pi * pl.diameter * pl.diameter / 2
    }

    func heatCapacity(_ i: Int) -> Double { max(10, parts[i].spec.dryMass + parts[i].fuel) * Self.specificHeat }

    /// Экран, встречающий поток: открыт и обращён к нему торцом.
    func shieldFacing(_ i: Int, flow d: Vec3, exposed: [Bool]) -> Bool {
        parts[i].spec.kind == .heatShield && exposed[i] && abs(parts[i].placement.orientation.rotate(.unitY).dot(d)) > 0.7
    }

    /// Шаг нагрева: поток `flux` (Вт/м² на открытую площадь) по направлению `d`, излучение, обмен с соседями.
    /// Возвращает id перегретых деталей и встречает ли поток экран.
    mutating func thermalStep(flow d: Vec3, flux: Double, dt: Double) -> (destroyed: [Int], shieldFacing: Bool) {
        var dq = Array(repeating: 0.0, count: parts.count)
        var facing = false
        if flux > 0 && d.lengthSquared > 0.5 {
            let shadow = shadowDiameters(flow: d)
            let exposed = parts.indices.map { shadow[$0] < parts[$0].placement.diameter - 1e-9 }
            for i in parts.indices {
                var q = flux * heatedArea(i, flow: d, shadow: shadow[i])
                if shieldFacing(i, flow: d, exposed: exposed) {
                    facing = true
                    if parts[i].fuel > 0 {
                        // Абляция уносит большую часть тепла, расходуя покрытие.
                        let want = q * Self.ablationShare * dt / Self.ablationHeat
                        let use = min(want, parts[i].fuel)
                        parts[i].fuel -= use
                        q -= use * Self.ablationHeat / dt
                    }
                }
                dq[i] += q
            }
        }
        let ta = Self.ambientTemperature
        let ta4 = ta * ta * ta * ta
        var index: [Int: Int] = [:]
        for (i, p) in parts.enumerated() { index[p.uid] = i }
        for (i, p) in parts.enumerated() {
            let t = p.temperature
            dq[i] -= Self.emissivitySigma * surfaceArea(i) * (t * t * t * t - ta4)
            if let pid = p.parent, let j = index[pid] {
                let flow = Self.conductance * (parts[j].temperature - t)
                dq[i] += flow
                dq[j] -= flow
            }
        }
        var destroyed: [Int] = []
        for i in parts.indices {
            parts[i].temperature = max(ta, parts[i].temperature + dq[i] * dt / heatCapacity(i))
            if parts[i].temperature > temperatureLimit(i) { destroyed.append(parts[i].uid) }
        }
        return (destroyed, facing)
    }

    /// Остывание излучением за `dt` без потока (рельсы, вакуум): точное решение dT/dt = −k·T⁴.
    mutating func cool(dt: Double) {
        guard dt > 0 else { return }
        let ta = Self.ambientTemperature
        for i in parts.indices where parts[i].temperature > ta + 0.01 {
            let k = Self.emissivitySigma * surfaceArea(i) / heatCapacity(i)
            let t = parts[i].temperature
            parts[i].temperature = max(ta, 1 / cbrt(1 / (t * t * t) + 3 * k * dt))
        }
    }

    /// Удалить разрушенную деталь: её поддеревья, кроме оставшегося с корнем (или с командной деталью, если
    /// разрушен корень), уходят обломками. Возвращает отрезанные куски (как `split`) и сдвиг начала.
    mutating func destroy(_ uid: Int) -> (pieces: [(debris: Ship, debrisOrigin: Vec3, shift: Vec3)], shift: Vec3) {
        guard let i = index(of: uid) else { return ([], .zero) }
        let isRoot = parts[i].parent == nil
        let kids = parts.filter { $0.parent == uid }.map(\.uid)
        var keep: Int?
        if isRoot {
            func hasCommand(_ k: Int) -> Bool {
                let sub = subtree(k)
                return parts.contains { sub.contains($0.uid) && ($0.spec.kind == .pod || $0.spec.kind == .probe) }
            }
            keep = kids.first(where: hasCommand) ?? kids.first
        }
        var pieces: [(debris: Ship, debrisOrigin: Vec3, shift: Vec3)] = []
        for k in kids where k != keep {
            let cut = split(removing: subtree(k))
            // Остаёмся в прежних осях: начала всех кусков — в одной системе.
            for j in parts.indices { parts[j].placement.center += cut.shift }
            pieces.append(cut)
        }
        if let k = keep, let j = index(of: k) { parts[j].parent = nil }
        // Сама деталь исчезает; сдвиг начала оставшегося корабля — в прежних осях.
        let gone = split(removing: [uid])
        return (pieces, gone.shift)
    }

    // MARK: РСУ

    /// Блоки РСУ на корабле.
    var rcsBlocks: Int { parts.reduce(0) { $0 + ($1.spec.kind == .rcs ? 1 : 0) } }
    /// Монотопливо всего корабля (общий пул `.rcs` + `.monoTank`) и его ёмкость, кг.
    var monoMass: Double { parts.reduce(0) { $0 + (Self.holdsMono($1.spec.kind) ? $1.fuel : 0) } }
    var monoCapacity: Double { parts.reduce(0) { $0 + (Self.holdsMono($1.spec.kind) ? $1.spec.fuelMass : 0) } }
    static func holdsMono(_ k: PartKind) -> Bool { k == .rcs || k == .monoTank }

    /// Забрать `amount` кг монотоплива из общего пула пропорционально остаткам.
    mutating func drawMono(_ amount: Double) {
        let total = monoMass
        guard amount > 0, total > 0 else { return }
        let k = max(0, 1 - amount / total)
        for i in parts.indices where Self.holdsMono(parts[i].spec.kind) { parts[i].fuel *= k }
    }

    // MARK: Топливо

    func source(_ i: Int) -> FuelSource { parts[i].spec.isSolid ? .solid(i) : .group(group[i]) }

    /// Жидкое топливо группы, кг.
    func liquidFuel(group g: Int) -> Double {
        var f = 0.0
        for i in parts.indices where group[i] == g && parts[i].spec.kind == .tank { f += parts[i].fuel }
        return f
    }

    /// Жидкое топливо в баках с индексами `r`, кг.
    func liquidFuel<S: Sequence>(in r: S) -> Double where S.Element == Int {
        r.reduce(0) { $0 + (parts[$1].spec.kind == .tank ? parts[$1].fuel : 0) }
    }

    func fuel(_ s: FuelSource) -> Double {
        switch s {
        case .solid(let i): parts[i].fuel
        case .group(let g): g < 0 ? 0 : liquidFuel(group: g)
        }
    }

    func capacity(_ s: FuelSource) -> Double {
        switch s {
        case .solid(let i): return parts[i].spec.fuelMass
        case .group(let g):
            guard g >= 0 else { return 0 }
            var c = 0.0
            for i in parts.indices where group[i] == g && parts[i].spec.kind == .tank { c += parts[i].spec.fuelMass }
            return c
        }
    }

    /// Есть ли у двигателя `i` топливо (РДТТ — своё, жидкостный — в группе).
    func engineHasFuel(_ i: Int) -> Bool {
        parts[i].spec.isSolid ? parts[i].fuel > 0 : fuel(source(i)) > 1e-9
    }

    var ignitedEngines: [Int] { parts.indices.filter { parts[$0].spec.kind == .engine && parts[$0].ignited } }

    /// Работают ли двигатели (тяга > 0 при текущем дросселе).
    func isThrusting(throttle: Double) -> Bool { !firingEngines(throttle: throttle).isEmpty }

    /// Индексы деталей-двигателей, которые сейчас дают тягу (для факела).
    func firingEngines(throttle: Double) -> [Int] {
        ignitedEngines.filter { i in parts[i].spec.isSolid ? parts[i].fuel > 0 : (throttle > 0 && engineHasFuel(i)) }
    }

    /// Есть ли у зажжённых двигателей топливо.
    func ignitedEnginesHaveFuel() -> (any: Bool, solid: Bool, liquid: Bool) {
        var s = false, l = false
        for i in ignitedEngines where engineHasFuel(i) {
            if parts[i].spec.isSolid { s = true } else { l = true }
        }
        return (s || l, s, l)
    }

    /// Шаг зажжённых двигателей: расход топлива по группам, тяга и её момент. `pressure` — относительное давление.
    mutating func burn(throttle: Double, pressure p: Double, dt: Double) -> ThrustResult {
        var res = ThrustResult()
        let engines = ignitedEngines
        guard !engines.isEmpty else { return res }
        var engineThrust = Array(repeating: 0.0, count: parts.count)
        // Жидкостные — по группам.
        var liquidBy: [Int: [Int]] = [:]
        for i in engines {
            let spec = parts[i].spec
            if spec.isSolid {
                if parts[i].fuel > 0 {
                    let t = spec.thrust(pressure: p)
                    let use = spec.massFlow * dt
                    let frac = use > parts[i].fuel ? parts[i].fuel / use : 1
                    res.solidThrust += t * frac
                    engineThrust[i] = t * frac
                    res.maxThrust += t
                    parts[i].fuel = max(0, parts[i].fuel - use)
                }
            } else {
                liquidBy[group[i], default: []].append(i)
            }
        }
        for g in liquidBy.keys.sorted() {
            let list = liquidBy[g] ?? []
            let liq = g < 0 ? 0 : liquidFuel(group: g)
            guard liq > 1e-9 else { continue }
            var flow = 0.0
            var gThrust = 0.0
            for i in list {
                let spec = parts[i].spec
                res.maxThrust += spec.thrust(pressure: p)
                if throttle > 0 {
                    gThrust += spec.thrust(pressure: p) * throttle
                    engineThrust[i] = spec.thrust(pressure: p) * throttle
                    flow += spec.massFlow * throttle
                }
            }
            if flow > 0 {
                var use = flow * dt
                if use > liq {
                    let k = liq / use
                    gThrust *= k
                    for i in list { engineThrust[i] *= k }
                    use = liq
                }
                for i in parts.indices where group[i] == g && parts[i].spec.kind == .tank && parts[i].fuel > 0 {
                    parts[i].fuel = max(0, parts[i].fuel - parts[i].fuel / liq * use)
                }
            }
            res.liquidThrust += gThrust
        }
        res.thrust = res.liquidThrust + res.solidThrust
        // Тяга — вдоль оси двигателя из точки сопла; момент Σ (pᵢ − ЦМ) × Fᵢ.
        // У соосного незаповёрнутого корабля плечи нулевые — момент ровно ноль.
        if res.thrust > 0 {
            let cm = centerOfMass
            var torque = Vec3.zero
            var force = Vec3.zero
            var tilted = false
            for i in engines where engineThrust[i] != 0 {
                let pl = parts[i].placement
                let f: Vec3
                let nozzle: Vec3
                if pl.orientation == .identity {
                    f = Vec3(0, engineThrust[i], 0)
                    nozzle = Vec3(pl.center.x, pl.bottom, pl.center.z)
                } else {
                    tilted = true
                    f = pl.orientation.rotate(.unitY) * engineThrust[i]
                    nozzle = pl.center - pl.orientation.rotate(Vec3(0, pl.height / 2, 0))
                }
                force += f
                let d = nozzle - cm
                if d.x != 0 || d.z != 0 || f.x != 0 || f.z != 0 { torque += d.cross(f) }
            }
            if torque.x != 0 || torque.y != 0 || torque.z != 0 { res.torque = torque }
            if tilted { res.force = force }
        }
        return res
    }

    // MARK: Ступени активации

    /// Детали ступени `k`, ещё оставшиеся на корабле.
    func partsOfStage(_ k: Int) -> [Int] { parts.indices.filter { parts[$0].stage == k } }

    /// Отделяет ли деталь что-то при срабатывании.
    func separates(_ i: Int) -> Bool {
        (parts[i].spec.kind == .decoupler && parts[i].parent != nil) || (parts[i].spec.kind == .fairing && parts.count > 1)
    }

    /// Ступени, которые ещё не сработали и где осталась хоть одна деталь.
    var pendingStages: [Int] {
        let from = (lastStage ?? -1) + 1
        guard from < stageParts.count else { return [] }
        return (from..<stageParts.count).filter { k in parts.contains { $0.stage == k } }
    }

    var nextStage: Int? { pendingStages.first }

    /// Ступени для телеметрии: последняя сработавшая (если есть) и оставшиеся.
    var telemetryStages: [Int] { (lastStage.map { [$0] } ?? []) + pendingStages }

    /// Ступень только зажигает двигатели (ничего не отделяет).
    func isPureIgnition(_ k: Int) -> Bool {
        let ps = partsOfStage(k)
        return ps.contains { parts[$0].spec.kind == .engine } && !ps.contains { separates($0) }
    }

    /// Детали, которые уйдут с корабля при срабатывании ступени `k`.
    func droppedUIDs(atStage k: Int) -> Set<Int> {
        var out: Set<Int> = []
        for i in partsOfStage(k) where separates(i) {
            if parts[i].spec.kind == .fairing { out.insert(parts[i].uid) } else { out.formUnion(subtree(parts[i].uid)) }
        }
        return out
    }

    /// Следующая ступень отделяет отработавшие двигатели (или на корабле не осталось тяги) — для автопилота.
    var spentSeparationReady: Bool {
        guard let k = nextStage, partsOfStage(k).contains(where: { separates($0) }) else { return false }
        let dropped = droppedUIDs(atStage: k)
        let ign = ignitedEngines
        let droppedIgn = ign.filter { dropped.contains(parts[$0].uid) }
        if !droppedIgn.isEmpty { return droppedIgn.allSatisfy { !engineHasFuel($0) } }
        return !ign.contains { engineHasFuel($0) }
    }

    /// Активация ступени без обломков (для прогноза Δv): зажечь, отделить, сбросить.
    mutating func simulateActivation(_ k: Int) {
        lastStage = k
        for i in partsOfStage(k) where parts[i].spec.kind == .engine { parts[i].ignited = true }
        let dropped = droppedUIDs(atStage: k)
        if !dropped.isEmpty {
            parts.removeAll { dropped.contains($0.uid) }
            rebuildCaches()
        }
    }

    /// Максимальная тяга и средний Isp при давлении `p`: зажжённые двигатели с топливом и двигатели
    /// следующей ступени, если она только зажигает (для прогноза прожига).
    func currentStagePerformance(pressure p: Double) -> (thrust: Double, isp: Double) {
        var list = ignitedEngines
        if let k = nextStage, isPureIgnition(k) {
            list += partsOfStage(k).filter { parts[$0].spec.kind == .engine && !parts[$0].ignited }
        }
        var t = 0.0, flow = 0.0
        for i in list.sorted() where engineHasFuel(i) {
            let spec = parts[i].spec
            t += spec.thrust(pressure: p)
            flow += spec.massFlow
        }
        return (t, flow > 0 ? t / (flow * standardGravity) : 0)
    }

    /// Сводка по ступеням активации: [0] — последняя сработавшая (до старта — первая, по давлению
    /// `pressure`), остальные — вакуум. Δv — пошаговым сжиганием по группам до отделения следующей ступени.
    func stageInfos(pressure: Double, gravity: Double) -> [StageInfo] {
        var sim = self
        var list: [(k: Int, activate: Bool)] = []
        if let last = lastStage { list.append((last, false)) }
        for k in pendingStages { list.append((k, true)) }
        var out: [StageInfo] = []
        for (j, item) in list.enumerated() {
            if item.activate { sim.simulateActivation(item.k) }
            let dropped = j + 1 < list.count ? sim.droppedUIDs(atStage: list[j + 1].k) : []
            var info = sim.simulateBurn(pressure: j == 0 ? pressure : 0, gravity: gravity, dropped: dropped)
            info.parts = item.k < stageParts.count ? stageParts[item.k] : []
            out.append(info)
        }
        return out
    }

    /// Прожиг зажжённых двигателей на полной тяге до исчерпания топлива, которое уйдёт с `dropped`
    /// (если такого нет — до исчерпания всего доступного). Расходует топливо в копии.
    mutating func simulateBurn(pressure p: Double, gravity: Double, dropped: Set<Int>) -> StageInfo {
        let engines = ignitedEngines
        var sources: [FuelSource] = []
        var stopSources: [FuelSource] = []
        var hasSolid = false, hasLiquidEngine = false
        for i in engines {
            let s = source(i)
            if parts[i].spec.isSolid { hasSolid = true } else { hasLiquidEngine = true }
            if !sources.contains(s) { sources.append(s) }
            let inDropped: Bool
            switch s {
            case .solid(let k): inDropped = dropped.contains(parts[k].uid)
            case .group(let g):
                inDropped = g >= 0 && parts.indices.contains {
                    group[$0] == g && parts[$0].spec.kind == .tank && dropped.contains(parts[$0].uid)
                }
            }
            if inDropped && !stopSources.contains(s) { stopSources.append(s) }
        }
        let shown = stopSources.isEmpty ? sources : stopSources
        let fuelMass = shown.reduce(0) { $0 + fuel($1) }
        let fuelCap = shown.reduce(0) { $0 + capacity($1) }
        let m0 = mass
        var t0 = 0.0, tVac0 = 0.0
        for i in engines where engineHasFuel(i) {
            t0 += parts[i].spec.thrust(pressure: p)
            tVac0 += parts[i].spec.thrustVacuum
        }
        var dv = 0.0, time = 0.0
        var m = m0
        for _ in 0..<64 {
            let burning = engines.filter { engineHasFuel($0) }
            if burning.isEmpty { break }
            if !stopSources.isEmpty && stopSources.allSatisfy({ fuel($0) <= 1e-9 }) { break }
            var thrust = 0.0, flow = 0.0
            var vec = Vec3.zero
            var tilted = false
            var drain: [FuelSource: Double] = [:]
            for i in burning {
                let spec = parts[i].spec
                let q = parts[i].placement.orientation
                thrust += spec.thrust(pressure: p)
                if q != .identity { tilted = true }
                vec += q.rotate(.unitY) * spec.thrust(pressure: p)
                flow += spec.massFlow
                drain[source(i), default: 0] += spec.massFlow
            }
            // Наклонённые двигатели: полезна только суммарная (векторная) тяга.
            if tilted { thrust = vec.length }
            guard flow > 0 else { break }
            var dt = Double.infinity
            var first: FuelSource?
            for (s, d) in drain where d > 0 {
                let t = fuel(s) / d
                if t < dt { dt = t; first = s }
            }
            guard dt.isFinite else { break }
            let m1 = m - flow * dt
            if m1 > 0 && m > m1 { dv += thrust / flow * log(m / m1) }
            time += dt
            for (s, d) in drain {
                let use = d * dt
                switch s {
                case .solid(let i):
                    parts[i].fuel = s == first ? 0 : max(0, parts[i].fuel - use)
                case .group(let g):
                    let f = liquidFuel(group: g)
                    for i in parts.indices where group[i] == g && parts[i].spec.kind == .tank {
                        parts[i].fuel = s == first || f <= 0 ? 0 : max(0, parts[i].fuel - parts[i].fuel / f * use)
                    }
                }
            }
            m = m1
        }
        var info = StageInfo(deltaV: dv,
                             twr: m0 > 0 && gravity > 0 ? t0 / (m0 * gravity) : 0,
                             twrVacuum: m0 > 0 && gravity > 0 ? tVac0 / (m0 * gravity) : 0,
                             fuelFraction: fuelCap > 0 ? fuelMass / fuelCap : 0,
                             burnTime: time,
                             hasSolid: hasSolid, fuelMass: fuelMass, fuelCapacity: fuelCap,
                             hasLiquidEngine: hasLiquidEngine)
        info.parts = []
        return info
    }
}
