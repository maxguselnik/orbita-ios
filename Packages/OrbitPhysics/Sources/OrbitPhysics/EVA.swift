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
    /// Расстояние от оси кабины до её поверхности на середине высоты (у капсулы — конус, как в рендере).
    static func hatchRadius(_ spec: PartSpec) -> Double {
        let r = spec.diameter / 2
        guard spec.kind == .pod else { return r }
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
            return (k, pl.center + n * Ship.hatchRadius(p.spec), n)
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
        guard let h = s.ship.hatches.first(where: { !s.ship.parts[$0.part].crew.isEmpty }) else { return }
        let member = vessels[i].ship.parts[h.part].crew.removeFirst()
        let name = CrewRoster.member(member)?.name ?? member
        let hatch = s.r + s.q.rotate(h.point)
        let out = s.q.rotate(h.outward)
        let c: Cosmonaut
        if s.isOnSurface {
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
        }
        cosmonauts.append(c)
        controlledCosmonaut = member
        evaInput = .neutral
        warpIndex = 0
        railsBacklog = 0
        warpToManeuverActive = false
        events.append(.evaExited(memberID: member))
    }

    private func evaBoard() {
        guard let ci = controlledIndex, let h = nearestHatch(cosmonauts[ci]),
              h.distance < EVABalance.boardRadius, h.free else { return }
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

    /// Ближайший люк на том же теле (на грунте — расстояние по горизонтали).
    func nearestHatch(_ c: Cosmonaut) -> HatchHit? {
        let up = c.r.normalized
        let center = c.r + up * EVABalance.centerHeight
        // Ближайший люк со свободным местом; если свободных нет — просто ближайший.
        var best: HatchHit?
        var bestFree: HatchHit?
        for (vi, v) in vessels.enumerated() where v.body == c.body && v.situation != .crashed {
            for h in v.ship.hatches {
                var d = v.r + v.q.rotate(h.point) - center
                if c.onGround { d -= up * d.dot(up) }
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
        let hatch = nearestHatch(c)
        return CosmonautState(
            memberID: c.memberID, name: c.name, body: c.body, position: c.r, velocity: c.v,
            attitude: c.attitude, onGround: c.onGround, health: c.health, jetpackOn: c.jetpackOn,
            jetpackFiring: c.firing, fuel: c.fuel, fuelCapacity: EVABalance.jetpackFuel,
            altitude: alt, heightAboveTerrain: c.onGround ? 0 : alt - terrain,
            surfaceSpeed: vRel.length, verticalSpeed: vRel.dot(up),
            orbit: c.onGround ? nil : OrbitElements(position: c.r, velocity: c.v, mu: b.mu).summary(body: b),
            situation: sit,
            hatchVessel: hatch.map { vessels[$0.vessel].id }, hatchDistance: hatch?.distance,
            canBoard: hatch.map { $0.distance < EVABalance.boardRadius && $0.free } ?? false,
            carried: c.carried, flagBlocker: flagBlocker(c),
            sampleBlocker: evaScienceBlocker(.surfaceSample, c, situation: sit),
            reportBlocker: evaScienceBlocker(.evaReport, c, situation: sit))
    }

    /// EVA-поля снимка.
    func fillEVASnapshot() {
        snapshot.cosmonauts = cosmonauts.map(cosmonautState)
        snapshot.controlledCosmonaut = controlledCosmonaut
        snapshot.flags = flags
        snapshot.evaExitBlocker = evaExitBlocker()
    }
}
