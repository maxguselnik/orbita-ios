import Foundation

// EVA (этап 6, часть 1): космонавт снаружи — отдельное тело в `FlightSim`. docs/CONTRACTS.md «EVA».

/// Космонавт снаружи (внутреннее состояние симуляции).
struct Cosmonaut: Sendable, Hashable {
    var memberID: String
    var name: String
    var body: BodyID
    /// Точка между стопами и скорость, инерциальная система тела.
    var r: Vec3
    var v: Vec3
    /// Куда смотрит лицо (−Z скафандра): горизонтальный единичный вектор, инерциальная система.
    var facing: Vec3
    var onGround: Bool
    var health: CosmonautHealth = .ok
    var jetpackOn: Bool
    /// Команда на сопла в последнем шаге в осях скафандра.
    var firing: Vec3 = .zero
    var fuel: Double = EVABalance.jetpackFuel
    var carried: [ScienceData] = []
    /// 6.2: держится за лестницу/поручни (nil — свободен).
    var grip: EVAGrip?

    /// +Y — местная вертикаль, −Z — `facing`.
    var attitude: Quat {
        let up = r.normalized
        let f = Cosmonaut.horizontal(facing, up: up)
        let z = -f
        return Quat(basisX: up.cross(z), y: up, z: z)
    }

    /// Горизонтальная составляющая `v` (единичная); вырожденная — любая перпендикулярная `up`.
    static func horizontal(_ v: Vec3, up: Vec3) -> Vec3 {
        let h = v - up * v.dot(up)
        if h.lengthSquared > 1e-12 { return h.normalized }
        let alt = abs(up.x) < 0.9 ? Vec3.unitX : Vec3.unitY
        return (alt - up * alt.dot(up)).normalized
    }
}

/// Люк корабля в мире.
struct HatchHit {
    var vessel: Int
    var part: Int
    var distance: Double
    var free: Bool
}

extension Ship {
    /// Полувысота люка, м: верх лестницы — на столько ниже центра люка (кольцо люка в рендере ~0.3 м).
    static let hatchHalfHeight = 0.3
    /// Люк ЛК-2 — на 35 % высоты кабины (6.2), у остальных — на середине.
    static func hatchHeightFraction(_ spec: PartSpec) -> Double { spec.id == .lk2 ? 0.35 : 0.5 }

    /// Расстояние от оси кабины до её поверхности на высоте люка (у капсулы — конус, как в рендере;
    /// ЛК-2 — широкая кабина, цилиндр).
    static func hatchRadius(_ spec: PartSpec) -> Double {
        let r = spec.diameter / 2
        guard spec.kind == .pod, spec.id != .lk2 else { return r }
        let top = 0.3 * min(spec.diameter, 1.25)
        return r - (r - top) * (0.42 / 0.82)
    }

    /// Люки кабин (`spec.crew > 0`): индекс детали, точка в осях корабля, наружная нормаль (сторона +Z кабины).
    var hatches: [(part: Int, point: Vec3, outward: Vec3)] {
        parts.indices.compactMap { k in
            let p = parts[k]
            guard p.spec.crew > 0 else { return nil }
            let pl = p.placement
            let n = pl.orientation.rotate(.unitZ)
            let dy = (Ship.hatchHeightFraction(p.spec) - 0.5) * pl.height
            return (k, pl.center + pl.orientation.rotate(Vec3(0, dy, 0)) + n * Ship.hatchRadius(p.spec), n)
        }
    }

    /// Лестницы (6.2): по одной на люк, если есть опоры. Вертикаль (ось +Y корабля) по центру под люком,
    /// на `max(радиус осевых деталей от люка до низа) + ladderStandoff` от оси кабины; верх — у нижнего края люка,
    /// низ — на высоте 0 (нижняя точка корабля).
    var ladders: [EVALadder] {
        guard hasLegs else { return [] }
        return hatches.enumerated().compactMap { k, h in
            let topY = h.point.y - Ship.hatchHalfHeight
            guard topY > 1e-3 else { return nil }
            var nh = Vec3(h.outward.x, 0, h.outward.z)
            guard nh.lengthSquared > 1e-9 else { return nil }
            nh = nh.normalized
            var radius = 0.0
            for p in parts where p.placement.outward == .zero && p.placement.bottom < topY && p.placement.top > 0 {
                radius = max(radius, p.placement.diameter / 2)
            }
            let c = parts[h.part].placement.center
            let x = Vec3(c.x, 0, c.z) + nh * (radius + EVABalance.ladderStandoff)
            return EVALadder(hatch: k, bottom: x, top: x + Vec3(0, topY, 0))
        }
    }
}

extension FlightSim {
    // MARK: Ввод и команды

    public func setEVAInput(_ input: EVAInput) {
        evaInput = controlledCosmonaut == nil ? .neutral : input
    }

    func sendEVA(_ command: FlightCommand) {
        switch command {
        case .evaExit: evaExit()
        case .evaBoard: evaBoard()
        case .evaSwitch: evaSwitch()
        case .evaGrab: evaGrab()
        case .evaRelease: evaRelease()
        case .evaSelect(let id): evaSelect(id)
        case .evaJump: evaJump()
        case .evaToggleJetpack:
            if let i = controlledIndex { cosmonauts[i].jetpackOn.toggle() }
        case .evaPlantFlag: evaPlantFlag()
        case .evaCollectSample: evaCollect(.surfaceSample)
        case .evaReport: evaCollect(.evaReport)
        default: break
        }
    }

    var controlledIndex: Int? {
        controlledCosmonaut.flatMap { id in cosmonauts.firstIndex { $0.memberID == id } }
    }

    /// Почему сейчас нельзя выйти из активного корабля (nil — можно).
    func evaExitBlocker() -> EVABlocker? {
        let s = active
        if s.situation == .crashed { return .crashed }
        if !s.ship.parts.contains(where: { !$0.crew.isEmpty }) { return .noCrew }
        if s.situation == .splashed { return .splashed }
        if s.ship.isThrusting(throttle: s.throttle) || rcsTranslationCommand(s.ship) != nil { return .thrusting }
        if s.situation == .prelaunch || s.situation == .landed { return nil }
        let b = Bodies.body(s.body)
        if b.atmosphereHeight > 0 && s.r.length - b.radius < b.atmosphereHeight { return .inAtmosphere }
        return nil
    }

    private func evaExit() {
        guard evaExitBlocker() == nil else { return }
        let i = activeIndex
        let s = vessels[i]
        let hatches = s.ship.hatches
        guard let hk = hatches.firstIndex(where: { !s.ship.parts[$0.part].crew.isEmpty }) else { return }
        let h = hatches[hk]
        let member = vessels[i].ship.parts[h.part].crew.removeFirst()
        let name = CrewRoster.member(member)?.name ?? member
        let hatch = s.r + s.q.rotate(h.point)
        let out = s.q.rotate(h.outward)
        var c: Cosmonaut
        let ladder = s.ship.ladders.first { $0.hatch == hk }
        if s.isOnSurface, let l = ladder {
            // 6.2: держится за верх лестницы.
            c = Cosmonaut(memberID: member, name: name, body: s.body, r: hatch, v: s.v, facing: -out,
                          onGround: false, jetpackOn: false)
            c.grip = EVAGrip(vessel: s.id, hatch: hk, along: l.length)
        } else if s.isOnSurface {
            let up = hatch.normalized
            var horiz = out - up * out.dot(up)
            if horiz.lengthSquared < 1e-6 { horiz = Cosmonaut.horizontal(s.q.rotate(.unitX), up: up) }
            horiz = horiz.normalized
            let p = surfacePoint(body: s.body, near: hatch + horiz * EVABalance.exitGroundOffset, time: time)
            // Лицом к кораблю: камера «за спиной» видит и космонавта, и корабль.
            c = Cosmonaut(memberID: member, name: name, body: s.body, r: p,
                          v: World.surfaceVelocity(body: s.body, position: p), facing: -horiz,
                          onGround: true, jetpackOn: false)
        } else {
            let center = hatch + out * EVABalance.exitOffset
            let up = center.normalized
            c = Cosmonaut(memberID: member, name: name, body: s.body, r: center - up * EVABalance.centerHeight,
                          v: s.v + s.w.cross(center - s.r), facing: Cosmonaut.horizontal(-out, up: up),
                          onGround: false, jetpackOn: true)
            // 6.2: держится за поручни люка.
            c.grip = EVAGrip(vessel: s.id, hatch: hk, along: nil)
        }
        cosmonauts.append(c)
        applyGrip(cosmonauts.count - 1)
        controlledCosmonaut = member
        evaInput = .neutral
        warpIndex = 0
        railsBacklog = 0
        warpToManeuverActive = false
        events.append(.evaExited(memberID: member))
    }

    private func evaBoard() {
        guard let ci = controlledIndex, let h = boardTarget(cosmonauts[ci]) else { return }
        let c = cosmonauts.remove(at: ci)
        vessels[h.vessel].ship.parts[h.part].crew.append(c.memberID)
        vessels[h.vessel].ship.parts[h.part].science += c.carried
        controlledCosmonaut = nil
        evaInput = .neutral
        if vessels[h.vessel].id != activeID { makeActive(h.vessel) }
        events.append(.evaBoarded(memberID: c.memberID))
    }

    private func evaSwitch() {
        if let i = controlledIndex {
            controlledCosmonaut = i + 1 < cosmonauts.count ? cosmonauts[i + 1].memberID : nil
        } else {
            controlledCosmonaut = cosmonauts.first?.memberID
        }
        evaInput = .neutral
    }

    private func evaSelect(_ id: String?) {
        if let id {
            guard cosmonauts.contains(where: { $0.memberID == id }) else { return }
        }
        controlledCosmonaut = id
        evaInput = .neutral
    }

    private func evaGrab() {
        guard let i = controlledIndex, let g = nearestGrip(cosmonauts[i]) else { return }
        cosmonauts[i].grip = g
        cosmonauts[i].onGround = false
        applyGrip(i)
    }

    private func evaRelease() {
        guard let i = controlledIndex, cosmonauts[i].grip != nil else { return }
        // Скорость — уже скорость точки корабля (`applyGrip`).
        cosmonauts[i].grip = nil
        cosmonauts[i].onGround = false
    }

    private func evaJump() {
        guard let i = controlledIndex, cosmonauts[i].onGround, cosmonauts[i].health == .ok else { return }
        cosmonauts[i].v += cosmonauts[i].r.normalized * EVABalance.jumpSpeed
        cosmonauts[i].onGround = false
    }

    private func evaPlantFlag() {
        guard let i = controlledIndex else { return }
        let c = cosmonauts[i]
        guard flagBlocker(c) == nil else { return }
        let fixed = flagBase(c)
        let text = "\(c.name) · \(Bodies.body(c.body).name)"
        flags.append(FlagState(id: nextFlagID, body: c.body, fixedPosition: fixed, text: text,
                               memberID: c.memberID, time: time))
        nextFlagID += 1
        events.append(.flagPlanted(body: c.body))
    }

    private func evaCollect(_ e: ExperimentID) {
        guard let i = controlledIndex else { return }
        let c = cosmonauts[i]
        let sit = cosmonautSituation(c)
        guard evaScienceBlocker(e, c, situation: sit) == nil, let s = sit else { return }
        let subject = ScienceSubjectID(experiment: e, body: c.body, situation: s)
        cosmonauts[i].carried.append(ScienceData(subject: subject, collectedAt: time))
        events.append(.evaScienceCollected(subject))
    }

    /// Сделать корабль `k` активным (космонавт вошёл в чужую кабину).
    func makeActive(_ k: Int) {
        let old = activeIndex
        vessels[old].isActive = false
        vessels[old].throttle = 0
        vessels[old].rcsTranslation = .zero
        vessels[old].rcsRotation = .zero
        vessels[k].isActive = true
        vessels[k].sasDirection = nil
        activeID = vessels[k].id
        hold = vessels[k].q
        input = .neutral
        autopilotDirection = nil
        setManeuver(nil)
        stageCache = nil
        lastThrust = 0
        lastSolidThrust = 0
        qPeak = 0
        qPeakReported = false
    }

    // MARK: Шаг

    /// Шаг всех космонавтов снаружи; `time` — начало шага.
    func stepCosmonauts(_ h: Double) {
        guard !cosmonauts.isEmpty else { return }
        let tNext = time + h
        var k = 0
        while k < cosmonauts.count {
            let input = cosmonauts[k].memberID == controlledCosmonaut ? evaInput : .neutral
            if stepCosmonaut(k, h, input: input, tNext: tNext) {
                k += 1
            } else {
                let c = cosmonauts.remove(at: k)
                if controlledCosmonaut == c.memberID {
                    controlledCosmonaut = nil
                    evaInput = .neutral
                }
            }
        }
    }

    /// false — погиб (удаляется вызывающим).
    private func stepCosmonaut(_ k: Int, _ h: Double, input: EVAInput, tNext: Double) -> Bool {
        var c = cosmonauts[k]
        let b = Bodies.body(c.body)
        let spin = World.spin(c.body)
        let up = c.r.normalized
        let g = b.mu / c.r.lengthSquared
        var move = input.move
        if move.length > 1 { move = move.normalized }
        let vert = clamp(input.vertical, -1, 1)
        c.firing = .zero
        var desiredFace: Vec3?

        if let g = c.grip {
            // 6.2: держится — положение и скорость задаёт `applyGrip` после шага кораблей; ранец не работает.
            if let a = g.along, let vi = vesselIndex(g.vessel),
               let l = vessels[vi].ship.ladders.first(where: { $0.hatch == g.hatch }) {
                let shipUp = vessels[vi].q.rotate(.unitY)
                let climb = clamp(vert + move.dot(shipUp), -1, 1)
                let na = a + EVABalance.climbSpeed * h * climb
                if climb < 0 && na <= 0 && vessels[vi].isOnSurface {
                    // Низ лестницы на грунте — встаёт на грунт.
                    c.grip = nil
                    c.r = surfacePoint(body: c.body, near: c.r, time: tNext)
                    c.v = World.surfaceVelocity(body: c.body, position: c.r)
                    c.onGround = true
                } else {
                    c.grip?.along = clamp(na, 0, l.length)
                }
            }
            cosmonauts[k] = c
            return true
        }

        if c.onGround {
            let vSurf = spin.cross(c.r)
            var vRel = c.v - vSurf
            vRel -= up * vRel.dot(up)
            var mh = move - up * move.dot(up)
            let ml = mh.length
            if ml > 1 { mh = mh / ml }
            let speed = c.health == .ok ? EVABalance.walkSpeed : EVABalance.injuredWalkSpeed
            let aMax = min(EVABalance.walkAccelMax, EVABalance.walkTraction * g)
            var dv = mh * speed - vRel
            let dl = dv.length
            if dl > aMax * h { dv = dv * (aMax * h / dl) }
            vRel += dv
            if ml > 1e-3 { desiredFace = mh }
            if c.jetpackOn && c.fuel > 0 && vert * EVABalance.jetpackAccel > g {
                // Ранец отрывает от грунта: дальше — полёт в этом же шаге.
                c.onGround = false
                c.v = vSurf + vRel
            } else {
                let r = surfacePoint(body: c.body, near: c.r + (vSurf + vRel) * h, time: tNext)
                let up2 = r.normalized
                vRel -= up2 * vRel.dot(up2)
                c.r = r
                c.v = spin.cross(r) + vRel
            }
        }

        var firingCmd = Vec3.zero
        if !c.onGround {
            var acc = up * -g
            if c.jetpackOn && c.fuel > 0 {
                var cmd = move + up * vert
                let l = cmd.length
                if l > 1 { cmd = cmd / l }
                let mag = cmd.length
                if mag > 1e-6 {
                    let need = mag * h
                    let frac = need > c.fuel ? c.fuel / need : 1
                    c.fuel -= need * frac
                    if c.fuel <= 1e-12 {
                        c.fuel = 0
                        events.append(.jetpackEmpty(memberID: c.memberID))
                    }
                    firingCmd = cmd * frac
                    acc += firingCmd * EVABalance.jetpackAccel
                    let ch = cmd - up * cmd.dot(up)
                    if ch.length > 1e-3 { desiredFace = ch.normalized }
                }
            }
            c.v += acc * h
            c.r += c.v * h
            // Касание грунта.
            let rm = c.r.length
            let dir = c.r / rm
            let fixed = World.toBodyFixed(dir, body: c.body, time: tNext)
            let surfR = b.radius + Terrain.surfaceHeight(body: c.body, direction: fixed)
            if rm <= surfR {
                let vSurf = spin.cross(c.r)
                let vRel = c.v - vSurf
                let vn = -vRel.dot(dir)
                if !b.hasSolidSurface || vn >= EVABalance.deathSpeed
                    || (vn >= EVABalance.injurySpeed && c.health == .injured) {
                    events.append(.evaDied(memberID: c.memberID, speed: max(0, vn)))
                    deadCrew.append(c.memberID)
                    return false
                }
                if vn >= EVABalance.injurySpeed {
                    c.health = .injured
                    events.append(.evaInjured(memberID: c.memberID, speed: vn))
                } else if vn >= 1 {
                    events.append(.evaLanded(memberID: c.memberID, speed: vn))
                }
                c.r = dir * surfR
                c.v = vSurf + (vRel - dir * vRel.dot(dir))
                c.onGround = true
            }
        }

        // Лицо — плавно к направлению шага/тяги.
        let upN = c.r.normalized
        var f = Cosmonaut.horizontal(c.facing, up: upN)
        if let d0 = desiredFace {
            let d = Cosmonaut.horizontal(d0, up: upN)
            let t = min(1, h * 6)
            let mixed = f * (1 - t) + d * t
            f = mixed.lengthSquared > 1e-6 ? mixed.normalized : Cosmonaut.horizontal(f + upN.cross(f) * t, up: upN)
        }
        c.facing = f
        if firingCmd != .zero { c.firing = c.attitude.conjugate.rotate(firingCmd) }

        // Смена SOI в полёте.
        if !c.onGround, let target = World.soiTarget(body: c.body, position: c.r, time: tNext) {
            let sv = World.convert(StateVector(position: c.r, velocity: c.v), from: c.body, to: target, time: tNext)
            c.r = sv.position
            c.v = sv.velocity
            c.body = target
        }
        cosmonauts[k] = c
        return true
    }

    // MARK: Помощники

    /// Точка на поверхности под/над `p` (по радиусу).
    func surfacePoint(body: BodyID, near p: Vec3, time t: Double) -> Vec3 {
        let dir = p.normalized
        let fixed = World.toBodyFixed(dir, body: body, time: t)
        return dir * (Bodies.body(body).radius + Terrain.surfaceHeight(body: body, direction: fixed))
    }

    /// Ближайший люк на том же теле (3D; на грунте у корабля без лестницы — по горизонтали).
    func nearestHatch(_ c: Cosmonaut) -> HatchHit? {
        let up = c.r.normalized
        let center = c.r + up * EVABalance.centerHeight
        // Ближайший люк со свободным местом; если свободных нет — просто ближайший.
        var best: HatchHit?
        var bestFree: HatchHit?
        for (vi, v) in vessels.enumerated() where v.body == c.body && v.situation != .crashed {
            for h in v.ship.hatches {
                var d = v.r + v.q.rotate(h.point) - center
                if c.onGround && !v.ship.hasLegs { d -= up * d.dot(up) }
                let dist = d.length
                let p = v.ship.parts[h.part]
                let hit = HatchHit(vessel: vi, part: h.part, distance: dist, free: p.crew.count < p.spec.crew)
                if best.map({ dist < $0.distance }) ?? true { best = hit }
                if hit.free, bestFree.map({ dist < $0.distance }) ?? true { bestFree = hit }
            }
        }
        return bestFree ?? best
    }

    /// Научная ситуация космонавта (на грунте — как `landed`/`launchPad`/`splashed`).
    func cosmonautSituation(_ c: Cosmonaut) -> ScienceSituation? {
        let b = Bodies.body(c.body)
        let alt = c.r.length - b.radius
        guard c.onGround else { return ScienceContext.situation(body: c.body, vessel: .flying, altitude: alt) }
        let fixed = World.toBodyFixed(c.r.normalized, body: c.body, time: time)
        if Terrain.isOcean(body: c.body, direction: fixed) {
            return ScienceContext.situation(body: c.body, vessel: .splashed, altitude: alt)
        }
        let onPad = c.body == .terra
            && acos(clamp(fixed.dot(World.padDirection), -1, 1)) * b.radius < Self.evaPadRadius
        return ScienceContext.situation(body: c.body, vessel: onPad ? .prelaunch : .landed, altitude: alt)
    }

    /// Радиус площадки для ситуации `launchPad` у космонавта, м.
    static let evaPadRadius = 200.0
    /// Минимальное расстояние между флагами, м; вынос основания флага перед лицом, м.
    static let flagSpacing = 3.0
    static let flagReach = 0.8

    func evaScienceBlocker(_ e: ExperimentID, _ c: Cosmonaut, situation: ScienceSituation?) -> ScienceBlocker? {
        if e == .surfaceSample && !c.onGround { return .notOnGround }
        guard let s = situation else { return .nowhere }
        guard e.works(s, body: c.body) else { return .notHere }
        let subject = ScienceSubjectID(experiment: e, body: c.body, situation: s)
        let carried = cosmonauts.contains { $0.carried.contains { $0.subject == subject } }
        let aboard = vessels.contains { v in v.ship.parts.contains { $0.science.contains { $0.subject == subject } } }
        return carried || aboard ? .duplicate : nil
    }

    /// Основание флага перед лицом, в системе, связанной с телом.
    func flagBase(_ c: Cosmonaut) -> Vec3 {
        let p = surfacePoint(body: c.body, near: c.r + c.facing * Self.flagReach, time: time)
        return World.toBodyFixed(p, body: c.body, time: time)
    }

    func flagBlocker(_ c: Cosmonaut) -> ScienceBlocker? {
        guard c.onGround else { return .notOnGround }
        let base = flagBase(c)
        if Terrain.isOcean(body: c.body, direction: base.normalized) { return .notHere }
        if flags.contains(where: { $0.body == c.body && ($0.fixedPosition - base).length < Self.flagSpacing }) {
            return .duplicate
        }
        return nil
    }

    func cosmonautState(_ c: Cosmonaut) -> CosmonautState {
        let b = Bodies.body(c.body)
        let rm = c.r.length
        let up = c.r / rm
        let alt = rm - b.radius
        let fixed = World.toBodyFixed(up, body: c.body, time: time)
        let terrain = Terrain.surfaceHeight(body: c.body, direction: fixed)
        let vRel = c.v - World.spin(c.body).cross(c.r)
        let sit = cosmonautSituation(c)
        let hatch = hatchInfo(c)
        let gripVessel = c.grip.flatMap { vesselIndex($0.vessel) }
        let onShipOnGround = gripVessel.map { vessels[$0].isOnSurface } ?? false
        var st = CosmonautState(
            memberID: c.memberID, name: c.name, body: c.body, position: c.r, velocity: c.v,
            attitude: c.attitude, onGround: c.onGround, health: c.health, jetpackOn: c.jetpackOn,
            jetpackFiring: c.firing, fuel: c.fuel, fuelCapacity: EVABalance.jetpackFuel,
            altitude: alt, heightAboveTerrain: c.onGround ? 0 : alt - terrain,
            surfaceSpeed: vRel.length, verticalSpeed: vRel.dot(up),
            orbit: c.onGround || onShipOnGround ? nil : OrbitElements(position: c.r, velocity: c.v, mu: b.mu).summary(body: b),
            situation: sit,
            hatchVessel: hatch.map { vessels[$0.vessel].id }, hatchDistance: hatch?.distance,
            canBoard: boardTarget(c) != nil,
            carried: c.carried, flagBlocker: flagBlocker(c),
            sampleBlocker: evaScienceBlocker(.surfaceSample, c, situation: sit),
            reportBlocker: evaScienceBlocker(.evaReport, c, situation: sit))
        st.grip = c.grip
        st.canGrip = c.grip == nil && nearestGrip(c) != nil
        return st
    }

    // MARK: 6.2: захват, вход, корпус

    func vesselIndex(_ id: VesselID) -> Int? {
        vessels.firstIndex { $0.id == id && $0.situation != .crashed }
    }

    /// Точка захвата: положение стоп (точка лестницы/люка + n·`ladderStandoff`), её скорость, нормаль `n`, тело;
    /// nil — корабля/люка нет.
    func gripAnchor(_ g: EVAGrip) -> (r: Vec3, v: Vec3, n: Vec3, body: BodyID)? {
        guard let vi = vesselIndex(g.vessel) else { return nil }
        let s = vessels[vi]
        let hs = s.ship.hatches
        guard g.hatch < hs.count else { return nil }
        let h = hs[g.hatch]
        let local: Vec3
        let n: Vec3
        if let a = g.along {
            guard let l = s.ship.ladders.first(where: { $0.hatch == g.hatch }) else { return nil }
            let len = l.length
            local = len > 1e-9 ? l.bottom + (l.top - l.bottom) * (clamp(a, 0, len) / len) : l.bottom
            n = Vec3(h.outward.x, 0, h.outward.z).normalized
        } else {
            local = h.point
            n = h.outward
        }
        let p = s.r + s.q.rotate(local + n * EVABalance.ladderStandoff)
        return (p, s.v + s.w.cross(p - s.r), s.q.rotate(n), s.body)
    }

    /// Поставить держащегося космонавта в точку захвата (корабля нет — отпускает).
    func applyGrip(_ k: Int) {
        guard let g = cosmonauts[k].grip else { return }
        guard let a = gripAnchor(g) else {
            cosmonauts[k].grip = nil
            return
        }
        cosmonauts[k].body = a.body
        cosmonauts[k].r = a.r
        cosmonauts[k].v = a.v
        cosmonauts[k].onGround = false
        cosmonauts[k].firing = .zero
        // Лицом к кораблю.
        cosmonauts[k].facing = Cosmonaut.horizontal(-a.n, up: a.r.normalized)
    }

    /// После шага кораблей: держащиеся — в точки захвата, свободные — вон из корпусов.
    func syncGripped() {
        for k in cosmonauts.indices {
            if cosmonauts[k].grip != nil {
                applyGrip(k)
            } else {
                pushOutOfHulls(&cosmonauts[k])
            }
        }
    }

    /// Ближайший захват ближе `gripRadius` от центра: лестницы — всегда, поручни люков — у кораблей не на грунте.
    func nearestGrip(_ c: Cosmonaut) -> EVAGrip? {
        guard c.grip == nil else { return nil }
        let center = c.r + c.r.normalized * EVABalance.centerHeight
        var best: (g: EVAGrip, d: Double)?
        for v in vessels where v.body == c.body && v.situation != .crashed {
            for l in v.ship.ladders {
                let a = v.r + v.q.rotate(l.bottom)
                let b = v.r + v.q.rotate(l.top)
                let ab = b - a
                let len2 = ab.lengthSquared
                let t = len2 > 1e-12 ? clamp((center - a).dot(ab) / len2, 0, 1) : 0
                let d = (a + ab * t - center).length
                guard d < EVABalance.gripRadius, best.map({ d < $0.d }) ?? true else { continue }
                // `along` — проекция стоп на лестницу.
                let along = len2 > 1e-12 ? clamp((c.r - a).dot(ab) / len2, 0, 1) * len2.squareRoot() : 0
                best = (EVAGrip(vessel: v.id, hatch: l.hatch, along: along), d)
            }
            guard !v.isOnSurface else { continue }
            for (k, h) in v.ship.hatches.enumerated() {
                let d = (v.r + v.q.rotate(h.point) - center).length
                guard d < EVABalance.gripRadius, best.map({ d < $0.d }) ?? true else { continue }
                best = (EVAGrip(vessel: v.id, hatch: k, along: nil), d)
            }
        }
        return best?.g
    }

    /// Люк для статуса: у держащегося — его люк (3D), иначе ближайший.
    func hatchInfo(_ c: Cosmonaut) -> HatchHit? {
        guard let g = c.grip else { return nearestHatch(c) }
        guard let vi = vesselIndex(g.vessel) else { return nil }
        let v = vessels[vi]
        let hs = v.ship.hatches
        guard g.hatch < hs.count else { return nil }
        let h = hs[g.hatch]
        let center = c.r + c.r.normalized * EVABalance.centerHeight
        let p = v.ship.parts[h.part]
        return HatchHit(vessel: vi, part: h.part, distance: (v.r + v.q.rotate(h.point) - center).length,
                        free: p.crew.count < p.spec.crew)
    }

    /// Куда можно войти сейчас: держащийся — с поручней или верха лестницы; свободный — ближе `boardRadius`.
    func boardTarget(_ c: Cosmonaut) -> HatchHit? {
        if let g = c.grip {
            if let a = g.along {
                guard let vi = vesselIndex(g.vessel),
                      let l = vessels[vi].ship.ladders.first(where: { $0.hatch == g.hatch }),
                      a >= l.length - EVABalance.ladderTopReach else { return nil }
            }
            guard let h = hatchInfo(c), h.free else { return nil }
            return h
        }
        guard let h = nearestHatch(c), h.distance < EVABalance.boardRadius, h.free else { return nil }
        return h
    }

    /// Радиус, в котором корпуса кораблей выталкивают космонавта, м.
    static let hullRadius = 30.0

    /// Не держащийся космонавт не входит в цилиндры осевых деталей: выталкивание по радиусу детали,
    /// скорость внутрь относительно корабля гасится. Проверяются три точки тела (низ, центр, голова).
    func pushOutOfHulls(_ c: inout Cosmonaut) {
        let br = EVABalance.bodyRadius
        let heights = [br, EVABalance.centerHeight, 2 * EVABalance.centerHeight - br]
        var pushed = false
        for v in vessels where v.body == c.body && (v.r - c.r).length < Self.hullRadius {
            for p in v.ship.parts where p.placement.outward == .zero {
                let pl = p.placement
                let rad = pl.diameter / 2 + br
                for hgt in heights {
                    let pt = c.r + c.r.normalized * hgt
                    let lp = pl.orientation.conjugate.rotate(v.q.conjugate.rotate(pt - v.r) - pl.center)
                    guard abs(lp.y) <= pl.height / 2 else { continue }
                    let radial = Vec3(lp.x, 0, lp.z)
                    let rho = radial.length
                    guard rho < rad else { continue }
                    let vp = v.v + v.w.cross(pt - v.r)
                    var dir: Vec3
                    if rho > 1e-6 {
                        dir = radial / rho
                    } else {
                        let rel = pl.orientation.conjugate.rotate(v.q.conjugate.rotate(vp - c.v))
                        dir = Vec3(rel.x, 0, rel.z)
                        dir = dir.lengthSquared > 1e-12 ? dir.normalized : .unitZ
                    }
                    let dirW = v.q.rotate(pl.orientation.rotate(dir))
                    c.r += dirW * (rad - rho)
                    let vn = (c.v - vp).dot(dirW)
                    if vn < 0 { c.v -= dirW * vn }
                    pushed = true
                }
            }
        }
        if pushed && c.onGround {
            c.r = surfacePoint(body: c.body, near: c.r, time: time)
            let up = c.r.normalized
            let vSurf = World.spin(c.body).cross(c.r)
            var vRel = c.v - vSurf
            vRel -= up * vRel.dot(up)
            c.v = vSurf + vRel
        }
    }


    /// EVA-поля снимка.
    func fillEVASnapshot() {
        snapshot.cosmonauts = cosmonauts.map(cosmonautState)
        snapshot.controlledCosmonaut = controlledCosmonaut
        snapshot.flags = flags
        snapshot.evaExitBlocker = evaExitBlocker()
        snapshot.deadCrew = deadCrew
    }
}
