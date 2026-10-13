import Foundation

// Поток A: реализация дерева проекта (контракт — DesignTree.swift, docs/CONTRACTS.md «Конструктор 5.2»).

extension PartSpec {
    /// Деталь срабатывает по ступени: двигатель, разделитель, парашют, обтекатель.
    var isActivatable: Bool { kind == .engine || kind == .decoupler || kind == .chute || kind == .fairing }
    /// Принимает ли боковых детей (кроме бокового разделителя — у него одна точка наружу).
    var acceptsRadial: Bool {
        switch kind {
        case .pod, .probe, .tank, .engine, .rcs, .monoTank: true
        default: false
        }
    }
    /// Принимает ли детей на узлы `.top`/`.bottom`.
    var acceptsAxial: Bool { id != .fin && id != .decouplerRadial }
}

/// Единичный вектор азимута в плоскости XZ: 0° — +X, 90° — +Z.
func azimuthVector(_ degrees: Double) -> Vec3 {
    let a = degrees * Double.pi / 180
    return Vec3(cos(a), 0, sin(a))
}

/// Азимут в градусах в диапазоне [0, 360).
func normalizedAngle(_ a: Double) -> Double {
    var r = a.truncatingRemainder(dividingBy: 360)
    if r < 0 { r += 360 }
    if r >= 360 - 1e-9 { r = 0 }
    return r
}

extension VesselDesign {
    /// Дети каждой детали в порядке `nodes`.
    func childrenMap() -> [Int: [DesignPart]] {
        var kids: [Int: [DesignPart]] = [:]
        for n in nodes { if let p = n.parent { kids[p, default: []].append(n) } }
        return kids
    }

    /// id детали и всех её потомков.
    func subtreeIDs(_ id: Int) -> Set<Int> {
        let kids = childrenMap()
        var out: Set<Int> = []
        var stack = [id]
        while let x = stack.popLast() {
            guard out.insert(x).inserted else { continue }
            stack += (kids[x] ?? []).map(\.id)
        }
        return out
    }

    /// Осевой ребёнок на узле `node` детали `id`.
    func axialChild(of id: Int, _ node: AttachNode) -> DesignPart? {
        nodes.first { $0.parent == id && $0.node == node }
    }

    /// Порядок обхода в глубину от корня: сначала верхний узел, затем бок, затем нижний;
    /// внутри узла — прежний порядок. Детали без пути к корню отбрасываются.
    mutating func normalizeOrder() {
        guard let root = nodes.first(where: { $0.parent == nil }) else { nodes = []; return }
        var index: [Int: Int] = [:]
        for (i, n) in nodes.enumerated() { index[n.id] = i }
        let kids = childrenMap()
        func rank(_ n: AttachNode) -> Int { n == .top ? 0 : (n == .radial ? 1 : 2) }
        var out: [DesignPart] = []
        var seen: Set<Int> = []
        func visit(_ n: DesignPart) {
            guard seen.insert(n.id).inserted else { return }
            out.append(n)
            let sorted = (kids[n.id] ?? []).sorted {
                (rank($0.node), index[$0.id] ?? 0) < (rank($1.node), index[$1.id] ?? 0)
            }
            for c in sorted { visit(c) }
        }
        visit(root)
        nodes = out
    }

    /// Ступени без пропусков 0…n−1 (порядок сохраняется); у неактивируемых — nil.
    mutating func compressStages() {
        let used = Array(Set(nodes.compactMap { $0.part.spec.isActivatable ? $0.stage : nil })).sorted()
        var map: [Int: Int] = [:]
        for (i, s) in used.enumerated() { map[s] = i }
        for i in nodes.indices {
            nodes[i].stage = nodes[i].part.spec.isActivatable ? nodes[i].stage.flatMap { map[$0] } : nil
        }
    }

    /// После структурной правки: авто-ступени или (ручные) ступени новым деталям по авто-правилу.
    mutating func restage(newIDs: Set<Int>) {
        normalizeOrder()
        if !customStaging {
            self = autoStaged()
            return
        }
        compressStages()
        let count = stageGroups.count
        let auto = autoStaged()
        for i in nodes.indices where nodes[i].part.spec.isActivatable
            && (newIDs.contains(nodes[i].id) || nodes[i].stage == nil) {
            let s = auto.node(nodes[i].id)?.stage ?? 0
            nodes[i].stage = min(s, count)
        }
        compressStages()
    }

    /// Азимут «системы отсчёта» детали: азимут ближайшего бокового крепления среди неё и её предков.
    func frameAngle(_ id: Int) -> Double {
        var cur = node(id)
        while let c = cur {
            if c.parent != nil && c.node == .radial { return c.angle }
            cur = c.parent.flatMap { node($0) }
        }
        return 0
    }

    /// Копии детали по симметрии (включая её саму первой).
    func symmetryCopies(_ id: Int) -> [DesignPart] {
        guard let n = node(id) else { return [] }
        guard let g = n.symmetryGroup else { return [n] }
        return [n] + nodes.filter { $0.symmetryGroup == g && $0.id != id }
    }

    var nextSymmetryGroup: Int { (nodes.compactMap(\.symmetryGroup).max() ?? -1) + 1 }

    /// Чистит группы симметрии из одной детали.
    mutating func pruneSymmetry() {
        var count: [Int: Int] = [:]
        for n in nodes { if let g = n.symmetryGroup { count[g, default: 0] += 1 } }
        for i in nodes.indices { if let g = nodes[i].symmetryGroup, count[g] ?? 0 < 2 { nodes[i].symmetryGroup = nil } }
    }

    // MARK: Раскладка

    /// Азимут боковой ветви, в которой стоит деталь (ближайшее боковое крепление среди неё и предков);
    /// nil — деталь на оси корня.
    func branchAngles() -> [Int: Double] {
        var out: [Int: Double] = [:]
        for n in nodes {
            if n.parent != nil && n.node == .radial {
                out[n.id] = n.angle
            } else if let p = n.parent, let a = out[p] {
                out[n.id] = a
            }
        }
        return out
    }

    /// Поворот детали относительно родителя: `rotation` в системе узла (на оси корня — оси корабля,
    /// в боковой ветви — X' = (uz, 0, −ux), Y' = Y, Z' = u наружу).
    static func relativeRotation(_ n: DesignPart, branch: Double?) -> Quat {
        guard n.rotation != .zero else { return .identity }
        let d = Double.pi / 180
        let local = (Quat(axis: .unitZ, angle: -n.rotation.z * d) * Quat(axis: .unitX, angle: n.rotation.x * d)
            * Quat(axis: .unitY, angle: n.rotation.y * d)).normalized
        guard let a = branch else { return local }
        let u = azimuthVector(a)
        let f = Quat(basisX: Vec3(u.z, 0, -u.x), y: .unitY, z: u)
        return (f * local * f.conjugate).normalized
    }

    /// Переходные кожухи: осевой разделитель, над которым по оси стоит двигатель без поворота и сдвига
    /// (двигатель — родитель, разделитель на его нижнем узле; или двигатель — ребёнок на верхнем узле
    /// разделителя), закрывает сопло. Верхний диаметр — деталь над двигателем, иначе max(двигатель, разделитель).
    func addShrouds(_ out: inout [PartPlacement]) {
        let kids = childrenMap()
        func plain(_ n: DesignPart) -> Bool { n.rotation == .zero && n.offset == .zero }
        for (i, n) in nodes.enumerated() where n.part.spec.kind == .decoupler && n.part.spec.mount == .axial {
            var engine: DesignPart?
            if n.node == .bottom, let pid = n.parent, let p = node(pid), p.part.spec.kind == .engine, plain(p) {
                engine = p
            } else if let c = kids[n.id]?.first(where: { $0.node == .top }), c.part.spec.kind == .engine, plain(c) {
                engine = c
            }
            guard let e = engine else { continue }
            // Деталь над двигателем: его родитель, если двигатель висит на нижнем узле; иначе ребёнок на верхнем.
            var above: DesignPart?
            if e.node == .bottom, let pid = e.parent, pid != n.id { above = node(pid) }
            if above == nil { above = kids[e.id]?.first { $0.node == .top && $0.id != n.id } }
            let es = e.part.spec, ds = n.part.spec
            out[i].shroud = InterstageShroud(height: es.height, bottomDiameter: ds.diameter,
                                             topDiameter: above?.part.spec.diameter ?? max(es.diameter, ds.diameter))
        }
    }

    func computeLayout() -> [PartPlacement] {
        guard !nodes.isEmpty else { return [] }
        var byID: [Int: PartPlacement] = [:]
        var out: [PartPlacement] = []
        out.reserveCapacity(nodes.count)
        let branch = branchAngles()
        for n in nodes {
            let s = n.part.spec
            var p = PartPlacement(center: .zero, height: s.height, diameter: s.diameter)
            if let pid = n.parent, let par = byID[pid] {
                let qp = par.orientation
                let rel = Self.relativeRotation(n, branch: branch[n.id])
                let q = rel == .identity ? qp : (qp * rel).normalized
                // Точка крепления (в осях родителя от его центра) и центр детали от точки крепления.
                let attach: Vec3
                let toCenter: Vec3
                switch n.node {
                case .bottom:
                    attach = Vec3(0, -par.height / 2, 0)
                    toCenter = Vec3(0, -s.height / 2, 0)
                case .top:
                    attach = Vec3(0, par.height / 2, 0)
                    toCenter = Vec3(0, s.height / 2, 0)
                case .radial:
                    let u = azimuthVector(n.angle)
                    attach = u * (par.diameter / 2) + Vec3(0, n.height * par.height - par.height / 2, 0)
                    toCenter = u * (s.diameter / 2)
                    p.outward = qp.rotate(u)
                }
                var a = par.center + qp.rotate(attach)
                if n.offset != .zero { a += n.offset }
                p.center = a + q.rotate(toCenter)
                p.orientation = q
            }
            byID[n.id] = p
            out.append(p)
        }
        addShrouds(&out)
        let minBottom = out.map(\.lowest).min() ?? 0
        let rootCenter = root.flatMap { byID[$0.id] }?.center ?? .zero
        let origin = Vec3(rootCenter.x, minBottom, rootCenter.z)
        for i in out.indices { out[i].center -= origin }
        return out
    }

    // MARK: Ступени

    func computeStageGroups() -> [[Int]] {
        let used = Array(Set(nodes.compactMap { $0.part.spec.isActivatable ? $0.stage : nil })).sorted()
        return used.map { s in nodes.filter { $0.stage == s && $0.part.spec.isActivatable }.map(\.id) }
    }

    func computeAutoStaged() -> VesselDesign {
        var d = self
        d.customStaging = false
        guard !nodes.isEmpty else { return d }
        let kids = childrenMap()
        var depth: [Int: Int] = [:]
        for n in nodes {
            let base = n.parent.flatMap { depth[$0] } ?? 0
            depth[n.id] = base + (n.part.spec.kind == .decoupler ? 1 : 0)
        }
        let decouplers = nodes.filter { $0.part.spec.kind == .decoupler }
        let maxDepth = decouplers.compactMap { depth[$0.id] }.max() ?? 0
        var stage: [Int: Int] = [:]
        for n in decouplers { stage[n.id] = maxDepth - (depth[n.id] ?? 1) + 1 }
        func bottomChild(_ id: Int) -> DesignPart? { kids[id]?.first { $0.node == .bottom } }
        var maxEngine: Int?
        for n in nodes where n.part.spec.kind == .engine {
            var s = 0
            var c = bottomChild(n.id)
            while let x = c {
                if x.part.spec.kind == .decoupler { s = stage[x.id] ?? 0; break }
                c = bottomChild(x.id)
            }
            stage[n.id] = s
            maxEngine = max(maxEngine ?? s, s)
        }
        let firstDecoupler = decouplers.compactMap { stage[$0.id] }.min()
        for n in nodes where n.part.spec.kind == .fairing {
            stage[n.id] = firstDecoupler ?? ((maxEngine ?? -1) + 1)
        }
        let last = (stage.values.max() ?? -1) + 1
        for n in nodes where n.part.spec.kind == .chute { stage[n.id] = last }
        for i in d.nodes.indices { d.nodes[i].stage = stage[d.nodes[i].id] }
        d.compressStages()
        return d
    }

    /// Детали, оставшиеся на корабле (с корнем) после срабатывания ступеней 0…`stage`.
    func remainingIDs(afterStage stage: Int) -> Set<Int> {
        var present = Set(nodes.map(\.id))
        let groups = stageGroups
        guard stage >= 0, !groups.isEmpty else { return present }
        for k in 0...min(stage, groups.count - 1) where k < groups.count {
            for id in groups[k] {
                guard present.contains(id), let n = node(id) else { continue }
                switch n.part.spec.kind {
                case .decoupler where n.parent != nil:
                    present.subtract(subtreeIDs(id))
                case .fairing:
                    present.remove(id)
                default: break
                }
            }
        }
        return present
    }

    func computeMarkers(stage: Int?) -> DesignMarkers {
        let lay = layout()
        let groups = stageGroups
        var k = stage
        if k == nil {
            k = groups.firstIndex { g in g.contains { node($0)?.part.spec.kind == .engine } }
        }
        let present = k.map { remainingIDs(afterStage: $0) } ?? Set(nodes.map(\.id))
        var m = 0.0
        var cm = Vec3.zero
        for (i, n) in nodes.enumerated() where present.contains(n.id) {
            let w = n.part.spec.wetMass
            m += w
            cm += lay[i].center * w
        }
        if m > 0 { cm = cm / m }
        // Двигатели, зажжённые к ступени k и ещё не отделённые: тяга вдоль оси детали из точки сопла.
        var t = 0.0
        var ct = Vec3.zero
        var force = Vec3.zero
        var torque = Vec3.zero
        if let k {
            for (i, n) in nodes.enumerated() where present.contains(n.id) && n.part.spec.kind == .engine {
                guard let s = n.stage, s <= k else { continue }
                let f = n.part.spec.thrustVacuum
                let pl = lay[i]
                let dir = pl.orientation.rotate(.unitY)
                let nozzle = pl.center - pl.orientation.rotate(Vec3(0, pl.height / 2, 0))
                t += f
                ct += nozzle * f
                force += dir * f
                torque += (nozzle - cm).cross(dir * f)
            }
        }
        var cot: Vec3?
        var offset = 0.0
        if t > 0 {
            cot = ct / t
            let fl = force.length
            // Плечо — по моменту тангажа/рыскания (крен от наклона по касательной не уводит нос).
            offset = fl > 0 ? (torque.x * torque.x + torque.z * torque.z).squareRoot() / fl : 0
        }
        // Центр давления: боковые площади; стабилизаторы — с весом ×5.
        var area = 0.0
        var cp = Vec3.zero
        for (i, n) in nodes.enumerated() where present.contains(n.id) {
            let s = n.part.spec
            let a = s.height * s.diameter * (s.kind == .fin ? 5 : 1)
            area += a
            cp += lay[i].center * a
        }
        return DesignMarkers(centerOfMass: cm, centerOfThrust: cot, thrustOffset: offset,
                             centerOfPressure: area > 0 ? cp / area : nil)
    }
}

// MARK: - Правки

extension VesselEditing {
    static func parentAccepts(_ part: PartID, _ target: AttachTarget, _ parent: DesignPart, _ design: VesselDesign) -> Bool {
        let ps = parent.part.spec
        let mount = part.spec.mount
        switch target.node {
        case .radial:
            guard mount != .axial else { return false }
            if parent.part == .decouplerRadial {
                return !design.nodes.contains { $0.parent == parent.id }
            }
            return ps.acceptsRadial
        case .top, .bottom:
            guard mount != .radial, ps.acceptsAxial else { return false }
            // Узел, которым деталь сама смотрит на родителя, занят родителем (у корня свободны оба).
            if parent.parent != nil {
                if parent.node == .bottom && target.node == .top { return false }
                if parent.node == .top && target.node == .bottom { return false }
            }
            return true
        }
    }

    static func canAttachImpl(_ part: PartID, _ target: AttachTarget, _ design: VesselDesign) -> Bool {
        guard let pid = target.parent else { return design.nodes.isEmpty && part.spec.mount != .radial }
        guard let parent = design.node(pid) else { return false }
        guard design.nodes.count < VesselDesign.maxParts else { return false }
        return parentAccepts(part, target, parent, design)
    }

    /// Радиальная точка на детали `p` (раскладка `pl`) под азимутом `angle` и высотой `height`.
    static func radialPoint(_ pl: PartPlacement, _ part: DesignPart, angle: Double, height: Double) -> Vec3 {
        let u = azimuthVector(angle)
        return pl.center + pl.orientation.rotate(u * (pl.diameter / 2) + Vec3(0, (height - 0.5) * pl.height, 0))
    }

    /// Занята ли боковая точка детали `pid` (есть боковой ребёнок рядом по азимуту и высоте).
    static func radialOccupied(_ pid: Int, angle: Double, height: Double, in design: VesselDesign) -> Bool {
        design.nodes.contains { n in
            guard n.parent == pid, n.node == .radial else { return false }
            var d = abs(normalizedAngle(n.angle) - normalizedAngle(angle))
            d = min(d, 360 - d)
            return d < 22.4 && abs(n.height - height) < 0.3
        }
    }

    static func attachTargetsImpl(_ part: PartID, _ symmetry: Int, _ design: VesselDesign) -> [AttachTarget] {
        if design.nodes.isEmpty {
            return part.spec.mount == .radial ? [] : [AttachTarget(parent: nil, node: .bottom, position: .zero)]
        }
        guard design.nodes.count < VesselDesign.maxParts else { return [] }
        let lay = design.layout()
        let n = max(1, min(4, symmetry))
        var out: [AttachTarget] = []
        for (i, p) in design.nodes.enumerated() {
            let pl = lay[i]
            for node in [AttachNode.top, .bottom] {
                let t = AttachTarget(parent: p.id, node: node,
                                     position: pl.center + pl.orientation.rotate(Vec3(0, (node == .top ? 1 : -1) * pl.height / 2, 0)))
                if canAttachImpl(part, t, design) { out.append(t) }
            }
            guard part.spec.mount != .axial else { continue }
            if p.part == .decouplerRadial {
                let t = AttachTarget(parent: p.id, node: .radial, angle: normalizedAngle(p.angle), height: 0.5,
                                     position: pl.center + pl.outward * (pl.diameter / 2))
                if canAttachImpl(part, t, design) { out.append(t) }
                continue
            }
            for k in 0..<8 {
                let a = Double(k) * 45
                let t = AttachTarget(parent: p.id, node: .radial, angle: a, height: 0.5,
                                     position: radialPoint(pl, p, angle: a, height: 0.5))
                guard canAttachImpl(part, t, design) else { continue }
                let fits = (0..<n).allSatisfy { j in
                    !radialOccupied(p.id, angle: a + Double(j) * 360 / Double(n), height: 0.5, in: design)
                }
                if fits { out.append(t) }
            }
        }
        return out
    }

    static func attachImpl(_ part: PartID, _ target: AttachTarget, _ symmetry: Int, _ mirror: Bool,
                           _ design: inout VesselDesign) -> [Int] {
        guard canAttachImpl(part, target, design) else { return [] }
        guard let pid = target.parent, let parent = design.node(pid) else {
            // Пустой проект: деталь — корень.
            let id = design.nextID
            design.nodes = [DesignPart(id: id, part: part, parent: nil)]
            design.restage(newIDs: [id])
            return [id]
        }
        let copies = design.symmetryCopies(pid)
        let n = target.node == .radial && parent.part != .decouplerRadial ? max(1, min(4, symmetry)) : 1
        let total = copies.count * n
        guard design.nodes.count + total <= VesselDesign.maxParts else { return [] }
        // Каждая копия родителя должна принять деталь.
        for c in copies {
            var t = target
            t.parent = c.id
            if !parentAccepts(part, t, c, design) { return [] }
        }
        let base = design.frameAngle(pid)
        var nextID = design.nextID
        let group: Int? = total > 1 ? design.nextSymmetryGroup : nil
        var ids: [Int] = []
        let mirrorPair = mirror && n == 2
        for c in copies {
            // Копия родителя — отражение (зеркальная пара) или поворот относительно него.
            let reflected = c.mirrored != parent.mirrored
            let delta = design.frameAngle(c.id) - base
            let baseAngle = reflected ? 180 - target.angle : target.angle + delta
            for j in 0..<n {
                let id = nextID
                nextID += 1
                var angle = 0.0
                var isMirror = reflected
                if target.node == .radial {
                    if c.part == .decouplerRadial {
                        angle = normalizedAngle(c.angle)
                    } else if mirrorPair {
                        angle = normalizedAngle(j == 0 ? baseAngle : 180 - baseAngle)
                        isMirror = reflected != (j == 1)
                    } else {
                        angle = normalizedAngle(baseAngle + Double(j) * 360 / Double(n))
                    }
                }
                // Вставка между: прежний осевой ребёнок переходит на тот же узел новой детали.
                if target.node != .radial, let old = design.axialChild(of: c.id, target.node),
                   let k = design.index(of: old.id) {
                    design.nodes[k].parent = id
                }
                var np = DesignPart(id: id, part: part, parent: c.id, node: target.node, angle: angle,
                                    height: target.node == .radial ? clamp(target.height, 0, 1) : 0.5,
                                    symmetryGroup: group)
                np.mirrored = isMirror
                design.nodes.append(np)
                ids.append(id)
            }
        }
        design.restage(newIDs: Set(ids))
        return ids
    }

    static func removeImpl(_ id: Int, _ design: inout VesselDesign) -> [Int] {
        guard design.node(id) != nil else { return [] }
        var removed: Set<Int> = []
        for t in design.symmetryCopies(id) {
            guard !removed.contains(t.id), let cur = design.node(t.id) else { continue }
            let kids = design.nodes.filter { $0.parent == cur.id }
            var keep: DesignPart?
            if let p = cur.parent {
                if cur.node != .radial { keep = kids.first { $0.node == cur.node } }
                if let k = keep, let i = design.index(of: k.id) {
                    design.nodes[i].parent = p
                    design.nodes[i].node = cur.node
                }
            } else {
                let axial = kids.filter { $0.node != .radial }
                if axial.count == 1, let k = axial.first, let i = design.index(of: k.id) {
                    keep = k
                    design.nodes[i].parent = nil
                    design.nodes[i].node = .bottom
                }
            }
            var gone = design.subtreeIDs(cur.id)
            if let k = keep { gone.subtract(design.subtreeIDs(k.id)) }
            removed.formUnion(gone)
            design.nodes.removeAll { gone.contains($0.id) }
        }
        design.pruneSymmetry()
        design.restage(newIDs: [])
        // Рассадка удалённых кабин: id может достаться новой детали.
        design.crewSeats = design.crewSeats.filter { design.node($0.key) != nil }
        return Array(removed).sorted()
    }

    static func moveImpl(_ id: Int, _ target: AttachTarget, _ design: inout VesselDesign) -> Bool {
        guard let n = design.node(id), let pid = target.parent, n.parent != nil else { return false }
        let sub = design.subtreeIDs(id)
        guard !sub.contains(pid) else { return false }
        var rest = design
        rest.nodes.removeAll { sub.contains($0.id) }
        guard let parent = rest.node(pid), parentAccepts(n.part, target, parent, rest) else { return false }
        var d = design
        // Вставка между: прежний ребёнок переходит на тот же узел переносимой детали.
        if target.node != .radial, let old = d.axialChild(of: pid, target.node), old.id != id {
            if d.axialChild(of: id, target.node) != nil { return false }
            if let k = d.index(of: old.id) { d.nodes[k].parent = id }
        }
        guard let i = d.index(of: id) else { return false }
        d.nodes[i].parent = pid
        d.nodes[i].node = target.node
        d.nodes[i].symmetryGroup = nil
        // Группы симметрии потомков, связанные с деталями вне поддерева, снимаются.
        for k in d.nodes.indices where sub.contains(d.nodes[k].id) {
            guard let g = d.nodes[k].symmetryGroup else { continue }
            if d.nodes.contains(where: { $0.symmetryGroup == g && !sub.contains($0.id) }) {
                d.nodes[k].symmetryGroup = nil
            }
        }
        if target.node == .radial {
            d.nodes[i].angle = parent.part == .decouplerRadial ? normalizedAngle(parent.angle) : normalizedAngle(target.angle)
            d.nodes[i].height = clamp(target.height, 0, 1)
        }
        d.pruneSymmetry()
        d.restage(newIDs: [])
        design = d
        return true
    }

    static func setStageImpl(_ id: Int, _ stage: Int, _ design: inout VesselDesign) {
        guard let n = design.node(id), n.part.spec.isActivatable else { return }
        design.compressStages()
        let count = design.stageGroups.count
        var to = stage
        if stage < 0 {
            for i in design.nodes.indices { if let s = design.nodes[i].stage { design.nodes[i].stage = s + 1 } }
            to = 0
        } else if stage > count {
            to = count
        }
        let ids = Set(design.symmetryCopies(id).map(\.id))
        for i in design.nodes.indices where ids.contains(design.nodes[i].id) && design.nodes[i].part.spec.isActivatable {
            design.nodes[i].stage = to
        }
        design.customStaging = true
        design.compressStages()
    }

    static func swapStagesImpl(_ a: Int, _ b: Int, _ design: inout VesselDesign) {
        design.compressStages()
        let count = design.stageGroups.count
        guard a != b, (0..<count).contains(a), (0..<count).contains(b) else { return }
        for i in design.nodes.indices {
            if design.nodes[i].stage == a { design.nodes[i].stage = b } else if design.nodes[i].stage == b { design.nodes[i].stage = a }
        }
        design.customStaging = true
    }
}

// MARK: - Поворот, сдвиг, корень

extension VesselEditing {
    static func setRotationImpl(_ id: Int, _ rotation: Vec3, _ design: inout VesselDesign) {
        guard let target = design.node(id) else { return }
        for c in design.symmetryCopies(id) {
            guard let i = design.index(of: c.id) else { continue }
            // Зеркальная копия: тангаж тот же, крен и рыскание — с обратным знаком.
            design.nodes[i].rotation = c.mirrored != target.mirrored ? Vec3(rotation.x, -rotation.y, -rotation.z) : rotation
        }
    }

    static func setOffsetImpl(_ id: Int, _ offset: Vec3, _ design: inout VesselDesign) {
        guard let target = design.node(id), let pid = target.parent, let parent = design.node(pid) else { return }
        let ps = parent.part.spec
        // Ограничение габаритом родителя.
        var o = offset
        o.y = clamp(o.y, -ps.height / 2, ps.height / 2)
        let lat = (o.x * o.x + o.z * o.z).squareRoot()
        let rmax = ps.diameter / 2
        if lat > rmax && lat > 0 { o.x *= rmax / lat; o.z *= rmax / lat }
        let base = design.frameAngle(id)
        for c in design.symmetryCopies(id) {
            guard let i = design.index(of: c.id) else { continue }
            if c.mirrored != target.mirrored {
                design.nodes[i].offset = Vec3(-o.x, o.y, o.z)
            } else {
                let d = (design.frameAngle(c.id) - base) * Double.pi / 180
                design.nodes[i].offset = Vec3(o.x * cos(d) - o.z * sin(d), o.y, o.x * sin(d) + o.z * cos(d))
            }
        }
    }

    static func setRootImpl(_ id: Int, _ design: inout VesselDesign) -> Bool {
        guard let start = design.node(id) else { return false }
        if start.parent == nil { return true }
        // Путь от новой вершины к прежнему корню.
        var path: [DesignPart] = [start]
        while let p = path.last?.parent, let n = design.node(p) { path.append(n) }
        for c in path.dropLast() where c.node == .radial || c.rotation != .zero || c.offset != .zero { return false }
        // Разделитель на пути поменял бы, что он уносит (отделение — поддерево разделителя).
        if path.dropLast().contains(where: { $0.part.spec.kind == .decoupler }) { return false }
        var d = design
        for k in path.indices {
            guard let i = d.index(of: path[k].id) else { return false }
            if k == 0 {
                d.nodes[i].parent = nil
                d.nodes[i].node = .bottom
            } else {
                // Был родителем path[k−1] через её узел — теперь висит на противоположном узле path[k−1].
                d.nodes[i].parent = path[k - 1].id
                d.nodes[i].node = path[k - 1].node == .bottom ? .top : .bottom
            }
        }
        d.restage(newIDs: [])
        design = d
        return true
    }
}
