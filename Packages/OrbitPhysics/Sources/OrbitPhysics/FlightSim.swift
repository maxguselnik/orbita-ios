import Foundation

/// Корабль внутри симуляции.
struct Vessel {
    var id: VesselID
    var body: BodyID
    /// Нижняя точка стека в инерциальной системе тела.
    var r: Vec3
    var v: Vec3
    var q: Quat
    /// Угловая скорость в инерциальной системе, рад/с.
    var w: Vec3 = .zero
    var ship: Ship
    var throttle = 0.0
    var situation: VesselSituation
    /// На грунте: положение и ориентация в системе, связанной с телом.
    var fixedPos: Vec3?
    var fixedAtt: Quat?
    var chute: ChuteState
    var chuteDeploy = 0.0
    var isActive: Bool

    var isOnSurface: Bool { situation == .prelaunch || situation == .landed || situation == .splashed }

    var state: VesselState {
        VesselState(id: id, body: body, position: r, velocity: v, attitude: q, angularVelocity: w,
                    mass: ship.mass, throttle: throttle, situation: situation, isActive: isActive,
                    parts: ship.parts.map(\.id), firingEngines: ship.firingEngines(throttle: throttle),
                    chute: chute, chuteDeploy: chuteDeploy)
    }
}

/// Физика полёта: активный корабль численно (шаг ≤ 0.02 с), остальные — проще или «на рельсах».
///
/// Соглашения:
/// - `VesselState.position` — нижняя точка стека деталей (то, что касается грунта).
/// - `VesselState.angularVelocity` — в инерциальной системе.
/// - Оси корабля (правая тройка): нос = +Y, «верх» (спина) = +Z, правый борт = +X.
///   pitch > 0 — нос к +Z (вверх), yaw > 0 — нос к +X (вправо), roll > 0 — правый борт вниз
///   (по часовой при взгляде сзади).
/// - На площадке: нос в зенит, +X (правый борт) — на восток, +Z (спина) — на юг.
///   Гравитационный разворот на восток — yaw > 0 («джойстик вправо»).
/// - SAS прогрейд/ретрогрейд ниже 36 км над Террой — относительно воздуха, выше — орбитальные.
public final class FlightSim: FlightSimulation {
    public static let maxStep = 0.02
    /// Высота, ниже которой парашют может раскрыться, м; и предельная скорость, м/с.
    public static let chuteMaxAltitude = 34_000.0
    public static let chuteMaxSpeed = 450.0

    public private(set) var snapshot = WorldSnapshot.empty
    public private(set) var time: Double
    public private(set) var warpIndex = 0
    public private(set) var sas: SASMode = .hold
    /// Направление, которое держит автопилот (перекрывает SAS, но не ручной ввод).
    public var autopilotDirection: Vec3?
    /// Узел манёвра для маркера навбола.
    public var maneuverNode: ManeuverNode?

    var vessels: [Vessel] = []
    var activeID: VesselID
    private var nextID: VesselID = 1
    private var input = ControlInput.neutral
    private var hold: Quat = .identity
    private var launchTime: Double?
    private var events: [SimEvent] = []

    // Телеметрия последнего шага.
    private var lastThrust = 0.0
    private var lastSolidThrust = 0.0
    private var lastProperAccel = 0.0
    private var qPeak = 0.0
    private var qPeakReported = false

    // MARK: Создание

    /// Корабль на стартовой площадке Терры.
    public convenience init(design: VesselDesign, time: Double = 0) {
        let up = World.fromBodyFixed(World.padDirection, body: .terra, time: time)
        let r = up * (Bodies.terra.radius + Terrain.padHeight)
        let east = Vec3.unitZ.cross(up).normalized
        // Правая тройка: X — восток, Y — зенит, Z = X × Y — юг.
        let q = Quat(basisX: east, y: up, z: east.cross(up))
        self.init(design: design, body: .terra, position: r,
                  velocity: World.surfaceVelocity(body: .terra, position: r), attitude: q, time: time)
        launchTime = nil
        landVessel(0, situation: .prelaunch)
        rebuildSnapshot()
    }

    /// Корабль в полёте с заданным состоянием (для тестов, загрузки и сценариев).
    /// Без `attitude` нос смотрит по скорости.
    public init(design: VesselDesign, body: BodyID, position: Vec3, velocity: Vec3,
                attitude: Quat? = nil, time: Double = 0) {
        self.time = time
        activeID = 1
        let ship = Ship(design: design)
        let q = attitude ?? Quat.looking(nose: velocity.lengthSquared > 0 ? velocity : position,
                                         zHint: position)
        var v = Vessel(id: nextID, body: body, r: position, v: velocity, q: q, ship: ship,
                       situation: .flying, chute: ship.hasChute ? .stowed : .none, isActive: true)
        nextID += 1
        v.situation = .flying
        vessels = [v]
        hold = q
        vessels[0].situation = classify(vessels[0])
        launchTime = time
        rebuildSnapshot()
    }

    // MARK: Доступ

    var activeIndex: Int { vessels.firstIndex { $0.id == activeID } ?? 0 }
    var active: Vessel { vessels[activeIndex] }

    public var activeBody: BodyID { active.body }
    public var activeStateVector: StateVector { StateVector(position: active.r, velocity: active.v) }
    public var activeMass: Double { active.ship.mass }
    public var activeSituation: VesselSituation { active.situation }
    public var activeElements: OrbitElements {
        OrbitElements(position: active.r, velocity: active.v, mu: Bodies.body(active.body).mu)
    }
    /// Детали активного корабля сверху вниз.
    public var activeParts: [PartID] { active.ship.parts.map(\.id) }
    /// Тяга (Н) и Isp текущей ступени при текущем давлении.
    public var currentStagePerformance: (thrust: Double, isp: Double) {
        active.ship.currentStagePerformance(pressure: pressure(of: active))
    }
    /// Есть ли у зажжённых двигателей нижней ступени топливо.
    public var currentStageHasFuel: Bool { active.ship.ignitedEnginesHaveFuel().any }
    /// Есть ли в нижней ступени незажжённые двигатели.
    public var currentStageHasUnlitEngines: Bool {
        let s = active.ship
        return s.bottomSection.contains { s.parts[$0].spec.kind == .engine && !s.parts[$0].ignited }
    }
    public var stageCount: Int { active.ship.sections.count }

    // MARK: FlightSimulation

    public func setInput(_ input: ControlInput) {
        self.input = input
        let i = activeIndex
        let throttle = clamp(input.throttle, 0, 1)
        vessels[i].throttle = throttle
    }

    public func send(_ command: FlightCommand) {
        switch command {
        case .stage: doStage()
        case .setSAS(let m):
            sas = m
            hold = active.q
        case .setWarp(let idx): setWarp(idx)
        case .deployChute: armChute()
        }
        rebuildSnapshot()
    }

    public func advance(realDelta: Double) -> [SimEvent] {
        // События от команд (`send`) с прошлого кадра тоже уходят в этот вызов.
        defer { events.removeAll() }
        guard realDelta > 0 else { rebuildSnapshot(); return events }
        if warpIndex >= TimeWarp.physicalCount, let reason = railsBlockReason() {
            warpIndex = reason == .thrust ? TimeWarp.physicalCount - 1 : 0
            events.append(.warpReset(reason))
        }
        let w = TimeWarp.levels[warpIndex]
        if warpIndex < TimeWarp.physicalCount {
            let total = realDelta * w
            let n = max(1, Int((total / Self.maxStep).rounded(.up)))
            let h = total / Double(n)
            for _ in 0..<n { step(h) }
        } else {
            railsAdvance(realDelta * w)
        }
        rebuildSnapshot()
        return events
    }

    // MARK: Ускорение времени

    /// Почему сейчас нельзя «на рельсы» (nil — можно).
    public func railsBlockReason() -> WarpResetReason? {
        let v = active
        if v.isOnSurface || v.situation == .crashed { return nil }
        if v.ship.isThrusting(throttle: v.throttle) { return .thrust }
        let alt = v.r.length - Bodies.body(v.body).radius
        if alt < World.railsMinimumAltitude(v.body) { return v.body == .terra ? .atmosphere : .terrain }
        return nil
    }

    private func setWarp(_ index: Int) {
        var i = max(0, min(TimeWarp.levels.count - 1, index))
        if i >= TimeWarp.physicalCount, let reason = railsBlockReason() {
            i = TimeWarp.physicalCount - 1
            events.append(.warpReset(reason))
        }
        warpIndex = i
    }

    private func resetWarp(_ reason: WarpResetReason) {
        if warpIndex > 0 {
            warpIndex = 0
            events.append(.warpReset(reason))
        }
    }

    // MARK: Ступени и парашют

    private func doStage() {
        let i = activeIndex
        guard vessels[i].situation != .crashed else { return }
        var ship = vessels[i].ship
        let secs = ship.sections
        let bottom = ship.bottomSection
        let stageNo = secs.count - 1
        let unlit = bottom.filter { ship.parts[$0].spec.kind == .engine && !ship.parts[$0].ignited }
        if !unlit.isEmpty {
            for k in unlit { ship.parts[k].ignited = true }
            vessels[i].ship = ship
            events.append(.ignition(stage: stageNo, solid: unlit.contains { ship.parts[$0].spec.isSolid }))
            return
        }
        if secs.count > 1 {
            separate(i)
            return
        }
        armChute()
    }

    private func separate(_ i: Int) {
        var v = vessels[i]
        let stageNo = v.ship.sections.count - 1
        let bottom = v.ship.bottomSection
        let removed = Array(v.ship.parts[bottom])
        v.ship.parts.removeSubrange(bottom)
        let nose = v.q.nose
        let height = Ship(parts: removed).length
        // Отделённая ступень.
        var d = Vessel(id: nextID, body: v.body, r: v.r, v: v.v - nose * 2.5, q: v.q,
                       w: v.w + v.q.rotate(Vec3(0.04, 0, 0.03)), ship: Ship(parts: removed),
                       situation: .flying, chute: .none, isActive: false)
        nextID += 1
        if v.isOnSurface {
            // Ступень остаётся на площадке.
            d.v = v.v
            d.situation = v.situation
            d.fixedPos = v.fixedPos
            d.fixedAtt = v.fixedAtt
        } else {
            d.situation = classify(d)
        }
        v.r += nose * height
        v.v += nose * 0.5
        if v.isOnSurface {
            v.situation = .flying
            v.fixedPos = nil
            v.fixedAtt = nil
            if launchTime == nil { launchTime = time }
        }
        var ignitedSolid: Bool?
        for k in v.ship.bottomSection where v.ship.parts[k].spec.kind == .engine {
            v.ship.parts[k].ignited = true
            ignitedSolid = (ignitedSolid ?? false) || v.ship.parts[k].spec.isSolid
        }
        vessels[i] = v
        vessels.append(d)
        events.append(.separation(stage: stageNo))
        if let solid = ignitedSolid { events.append(.ignition(stage: stageNo - 1, solid: solid)) }
    }

    private func armChute() {
        let i = activeIndex
        if vessels[i].chute == .stowed { vessels[i].chute = .armed }
    }

    // MARK: Шаг физики

    private func pressure(of v: Vessel) -> Double {
        let b = Bodies.body(v.body)
        return b.density(altitude: v.r.length - b.radius) / Bodies.terra.seaLevelDensity
    }

    private func step(_ h: Double) {
        let ai = activeIndex
        if vessels[ai].situation != .crashed { stepActive(ai, h) }
        for k in vessels.indices where k != ai && !vessels[k].isOnSurface && vessels[k].situation != .crashed {
            stepDebris(k, h)
        }
        time += h
        for k in vessels.indices where vessels[k].isOnSurface { updateLanded(k) }
        // Удалить разбившиеся отделённые ступени.
        vessels.removeAll { !$0.isActive && $0.situation == .crashed }
        for k in vessels.indices { checkSOI(k) }
    }

    private func updateLanded(_ k: Int) {
        guard let fp = vessels[k].fixedPos, let fa = vessels[k].fixedAtt else { return }
        let b = vessels[k].body
        let r = World.fromBodyFixed(fp, body: b, time: time)
        vessels[k].r = r
        vessels[k].v = World.surfaceVelocity(body: b, position: r)
        vessels[k].q = (World.bodyRotation(b, time: time) * fa).normalized
        vessels[k].w = World.spin(b)
    }

    private func landVessel(_ k: Int, situation: VesselSituation) {
        let b = vessels[k].body
        vessels[k].situation = situation
        vessels[k].fixedPos = World.toBodyFixed(vessels[k].r, body: b, time: time)
        vessels[k].fixedAtt = (World.bodyRotation(b, time: time).conjugate * vessels[k].q).normalized
        updateLanded(k)
    }

    private func stepActive(_ ai: Int, _ h: Double) {
        var s = vessels[ai]
        let b = Bodies.body(s.body)
        let rm = s.r.length
        let up = s.r / rm
        let alt = rm - b.radius
        let rho = b.density(altitude: alt)
        let p = rho / Bodies.terra.seaLevelDensity
        let m = s.ship.mass
        let stageNo = s.ship.sections.count - 1

        let before = s.ship.ignitedEnginesHaveFuel()
        let tr = s.ship.burn(throttle: s.throttle, pressure: p, dt: h)
        let after = s.ship.ignitedEnginesHaveFuel()
        if before.solid && !after.solid { events.append(.flameout(stage: stageNo, solid: true)) }
        if before.liquid && !after.liquid { events.append(.flameout(stage: stageNo, solid: false)) }
        lastThrust = tr.thrust
        lastSolidThrust = tr.solidThrust

        let nose = s.q.nose
        let thrustAcc = nose * (tr.thrust / m)
        let g = b.mu / (rm * rm)

        if s.isOnSurface {
            if thrustAcc.dot(up) > g * 1.001 {
                s.situation = .flying
                s.fixedPos = nil
                s.fixedAtt = nil
                s.r += up * 0.05
                if launchTime == nil { launchTime = time }
            } else {
                lastProperAccel = g
                vessels[ai] = s
                return
            }
        }

        let spin = World.spin(s.body)
        let vAir = s.v - spin.cross(s.r)
        let va = vAir.length
        let qd = 0.5 * rho * va * va

        // Парашют.
        if s.chute == .armed && rho > 0 && alt < Self.chuteMaxAltitude && va < Self.chuteMaxSpeed {
            s.chute = .deploying
            events.append(.chuteDeployed)
        }
        if s.chute == .deploying {
            s.chuteDeploy = min(1, s.chuteDeploy + h * 0.3)
            if s.chuteDeploy >= 1 {
                s.chute = .open
                events.append(.chuteOpened)
            }
        }
        let chuteOut = s.chute == .deploying || s.chute == .open

        // Аэродинамика.
        var dragAcc = Vec3.zero
        var aeroAlpha = Vec3.zero
        if va > 0.05 && rho > 0 {
            let vh = vAir / va
            let cosA = nose.dot(vh)
            let sin2 = max(0, 1 - cosA * cosA)
            let chA = chuteOut ? chuteFullCdA * pow(s.chuteDeploy, 3) : 0
            let cda = s.ship.dragArea * (1 + 2.5 * sin2) + chA
            let dAcc = min(qd * cda / m, va * 0.9 / h)
            dragAcc = vh * -dAcc
            let target = (chuteOut || s.ship.retroStable) ? -vh : vh
            let cr = nose.cross(target)
            let sinE = cr.length
            let ang = atan2(sinE, nose.dot(target))
            let axis = sinE > 1e-9 ? cr / sinE : s.q.rotate(.unitX)
            let mt = m / 1000
            let mag = clamp((qd * 4e-5 + qd * chA * 1e-4) * sin(ang) / (mt / 2 + 0.5).squareRoot(), -3, 3)
            aeroAlpha = axis * mag
            let relW = s.w - spin
            s.w = spin + relW / (1 + h * (qd * 1e-4 + (chuteOut ? 2 : 0)))
        }

        // maxQ.
        if rho > 0 {
            if qd > qPeak { qPeak = qd; qPeakReported = false }
            if !qPeakReported && qPeak > 1_000 && qd < qPeak * 0.95 {
                events.append(.maxQ(pascals: qPeak))
                qPeakReported = true
            }
        } else {
            qPeak = 0
            qPeakReported = false
        }

        let proper = thrustAcc + dragAcc
        lastProperAccel = proper.length
        // Полунеявный Эйлер.
        s.v += (proper - up * g) * h
        s.r += s.v * h

        attitude(&s, h, mass: m, firing: tr.thrust > 0, aero: aeroAlpha)

        // Контакт с поверхностью.
        let tNext = time + h
        let rm2 = s.r.length
        let dir = s.r / rm2
        let fixedDir = World.toBodyFixed(dir, body: s.body, time: tNext)
        let surfR = b.radius + Terrain.surfaceHeight(body: s.body, direction: fixedDir)
        if rm2 <= surfR {
            let vRel = s.v - spin.cross(s.r)
            let speed = vRel.length
            if speed > s.ship.crashTolerance {
                s.situation = .crashed
                s.v = spin.cross(s.r)
                s.w = .zero
                events.append(.crash(speed: speed))
                warpIndex = 0
                vessels[ai] = s
                return
            }
            s.r = dir * surfR
            let ocean = Terrain.isOcean(body: s.body, direction: fixedDir)
            if s.chute == .deploying || s.chute == .open { s.chute = .cut }
            events.append(ocean ? .splashdown(speed: speed) : .touchdown(speed: speed))
            vessels[ai] = s
            // Посадочная поза фиксируется на момент tNext.
            let saved = time
            time = tNext
            landVessel(ai, situation: ocean ? .splashed : .landed)
            time = saved
            lastProperAccel = g
            return
        }
        s.situation = classify(s)
        vessels[ai] = s
    }

    private func attitude(_ s: inout Vessel, _ h: Double, mass m: Double, firing: Bool, aero: Vec3) {
        let mt = m / 1000
        let ctrl = 1.4 / (mt / 2 + 0.5).squareRoot() + (firing ? 0.25 : 0)
        var alpha = Vec3.zero
        let manual = Vec3(input.pitch, input.roll, input.yaw)
        if manual.lengthSquared > 1e-6 {
            alpha = s.q.rotate(Vec3(clamp(manual.x, -1, 1), clamp(manual.y, -1, 1), -clamp(manual.z, -1, 1))) * ctrl
            hold = s.q
        } else if let target = autopilotDirection ?? sasTargetDirection(s) {
            alpha = rateControl(s, desired: rotationTo(s.q.nose, target.normalized), ctrl: ctrl)
        } else if sas == .hold {
            let err = (hold * s.q.conjugate).axisAngle
            alpha = rateControl(s, desired: (err.axis, err.angle), ctrl: ctrl)
        }
        s.w += (alpha + aero) * h
        let wl = s.w.length
        if wl > 1.5 { s.w = s.w * (1.5 / wl) }
        let wl2 = s.w.length
        if wl2 > 1e-12 {
            s.q = (Quat(axis: s.w / wl2, angle: wl2 * h) * s.q).normalized
        }
    }

    private func rotationTo(_ from: Vec3, _ to: Vec3) -> (axis: Vec3, angle: Double) {
        let cr = from.cross(to)
        let sn = cr.length
        let ang = atan2(sn, from.dot(to))
        if sn < 1e-9 {
            if ang < 1e-6 { return (.unitX, 0) }
            let alt = abs(from.x) < 0.9 ? Vec3.unitX : Vec3.unitY
            return (from.cross(alt).normalized, ang)
        }
        return (cr / sn, ang)
    }

    /// Регулятор угловой скорости (как в эталоне): желаемая скорость ∝ √(угол).
    /// Для направления ось перпендикулярна носу, поэтому вращение по крену гасится.
    private func rateControl(_ s: Vessel, desired: (axis: Vec3, angle: Double), ctrl: Double) -> Vec3 {
        let wDes = desired.axis * min(0.9, (2 * ctrl * 0.7 * desired.angle).squareRoot())
        var a = (wDes - s.w) * 6
        let al = a.length
        if al > ctrl { a = a * (ctrl / al) }
        return a
    }

    /// Скорость для навигации: у Терры ниже 36 км — относительно воздуха.
    private func navVelocity(_ s: Vessel) -> Vec3 {
        let alt = s.r.length - Bodies.body(s.body).radius
        if s.body == .terra && alt < 36_000 { return s.v - World.spin(s.body).cross(s.r) }
        return s.v
    }

    private func sasTargetDirection(_ s: Vessel) -> Vec3? {
        let v = navVelocity(s)
        let vo = s.v
        let n = s.r.cross(vo).normalized
        switch sas {
        case .off, .hold: return nil
        case .prograde: return v.length > 0.5 ? v : nil
        case .retrograde: return v.length > 0.5 ? -v : nil
        case .normal: return n.lengthSquared > 0 ? n : nil
        case .antiNormal: return n.lengthSquared > 0 ? -n : nil
        case .radialOut:
            let rd = vo.normalized.cross(n)
            return rd.lengthSquared > 0 ? rd : s.r
        case .radialIn:
            let rd = vo.normalized.cross(n)
            return rd.lengthSquared > 0 ? -rd : -s.r
        }
    }

    /// Отделённые ступени: гравитация + сопротивление в атмосфере, иначе Кеплер.
    private func stepDebris(_ k: Int, _ h: Double) {
        var d = vessels[k]
        let b = Bodies.body(d.body)
        let rm = d.r.length
        let alt = rm - b.radius
        let rho = b.density(altitude: alt)
        if rho > 0 {
            let spin = World.spin(d.body)
            let vAir = d.v - spin.cross(d.r)
            let va = vAir.length
            var a = d.r * (-b.mu / (rm * rm * rm))
            if va > 0.1 {
                let m = d.ship.mass
                let dA = min(0.5 * rho * va * va * d.ship.dragArea * 1.6 / m, va * 0.9 / h)
                a -= vAir / va * dA
            }
            d.v += a * h
            d.r += d.v * h
        } else {
            let sv = Kepler.propagate(position: d.r, velocity: d.v, mu: b.mu, dt: h)
            d.r = sv.position
            d.v = sv.velocity
        }
        let wl = d.w.length
        if wl > 1e-12 { d.q = (Quat(axis: d.w / wl, angle: wl * h) * d.q).normalized }
        if belowSurface(d, time: time + h) { d.situation = .crashed } else { d.situation = classify(d) }
        vessels[k] = d
    }

    private func belowSurface(_ d: Vessel, time t: Double) -> Bool {
        let rm = d.r.length
        let b = Bodies.body(d.body)
        if rm > b.radius + 10_000 { return false }
        let fixedDir = World.toBodyFixed(d.r / rm, body: d.body, time: t)
        return rm <= b.radius + Terrain.surfaceHeight(body: d.body, direction: fixedDir)
    }

    // MARK: SOI

    private func checkSOI(_ k: Int) {
        let v = vessels[k]
        guard !v.isOnSurface, v.situation != .crashed else { return }
        var to: BodyID?
        if v.body == .terra {
            if (v.r - World.lunaPosition(at: time)).length < Bodies.luna.soiRadius { to = .luna }
        } else if v.r.length > Bodies.luna.soiRadius {
            to = .terra
        }
        guard let target = to else { return }
        let sv = World.convert(StateVector(position: v.r, velocity: v.v), from: v.body, to: target, time: time)
        vessels[k].r = sv.position
        vessels[k].v = sv.velocity
        vessels[k].body = target
        vessels[k].situation = classify(vessels[k])
        if v.id == activeID {
            events.append(.soiChanged(from: v.body, to: target))
            resetWarp(.soiChange)
            qPeak = 0
        }
    }

    // MARK: Рельсы

    private func railsAdvance(_ total: Double) {
        lastThrust = 0
        lastSolidThrust = 0
        // Отделённые ступени в атмосфере на рельсах не моделируются — удаляются.
        vessels.removeAll { d in
            guard !d.isActive, !d.isOnSurface else { return false }
            let b = Bodies.body(d.body)
            return b.density(altitude: d.r.length - b.radius) > 0
        }
        if active.isOnSurface || active.situation == .crashed {
            railsOthers(total)
            time += total
            for k in vessels.indices where vessels[k].isOnSurface { updateLanded(k) }
            return
        }
        var rem = total
        var guardN = 0
        let idx = activeIndex
        vessels[idx].w = .zero
        lastProperAccel = 0
        while rem > 1e-9 && guardN < 2_000 {
            guardN += 1
            let s = vessels[idx]
            let b = Bodies.body(s.body)
            let rm = s.r.length
            let vm = s.v.length
            let vr = s.r.dot(s.v) / rm
            let alt = rm - b.radius
            let thr = World.railsMinimumAltitude(s.body)
            var ch = min(rem, 120)
            if vr < 0 { ch = min(ch, max(0.5, (alt - thr) / -vr * 0.5)) }
            if s.body == .terra {
                let d = (s.r - World.lunaPosition(at: time)).length - Bodies.luna.soiRadius
                ch = min(ch, max(0.5, d / (vm + 700) * 0.8))
            } else {
                ch = min(ch, max(0.5, (Bodies.luna.soiRadius - rm) / (vm + 1) * 0.8))
            }
            let sv = Kepler.propagate(position: s.r, velocity: s.v, mu: b.mu, dt: ch)
            vessels[idx].r = sv.position
            vessels[idx].v = sv.velocity
            railsOthers(ch)
            time += ch
            rem -= ch
            for k in vessels.indices where vessels[k].isOnSurface { updateLanded(k) }
            let oldBody = vessels[idx].body
            checkSOI(idx)
            for k in vessels.indices where k != idx { checkSOI(k) }
            if vessels[idx].body != oldBody { break }
            let s2 = vessels[idx]
            let b2 = Bodies.body(s2.body)
            let rm2 = s2.r.length
            let vr2 = s2.r.dot(s2.v) / rm2
            if rm2 - b2.radius < World.railsMinimumAltitude(s2.body) && vr2 < 0 {
                resetWarp(s2.body == .terra ? .atmosphere : .terrain)
                break
            }
        }
        vessels[idx].situation = classify(vessels[idx])
    }

    private func railsOthers(_ dt: Double) {
        for k in vessels.indices where !vessels[k].isActive && !vessels[k].isOnSurface && vessels[k].situation != .crashed {
            let b = Bodies.body(vessels[k].body)
            let sv = Kepler.propagate(position: vessels[k].r, velocity: vessels[k].v, mu: b.mu, dt: dt)
            vessels[k].r = sv.position
            vessels[k].v = sv.velocity
            vessels[k].w = .zero
            if belowSurface(vessels[k], time: time + dt) { vessels[k].situation = .crashed }
        }
        vessels.removeAll { !$0.isActive && $0.situation == .crashed }
    }

    // MARK: Классификация

    func classify(_ v: Vessel) -> VesselSituation {
        if v.isOnSurface || v.situation == .crashed { return v.situation }
        let b = Bodies.body(v.body)
        let alt = v.r.length - b.radius
        if b.atmosphereHeight > 0 && alt < b.atmosphereHeight { return .flying }
        let el = OrbitElements(position: v.r, velocity: v.v, mu: b.mu)
        if !el.isClosed || el.apoapsisRadius > b.soiRadius { return .escaping }
        let safe = b.radius + World.railsMinimumAltitude(v.body)
        return el.periapsisRadius > safe ? .orbiting : .suborbital
    }

    // MARK: Снимок

    private func rebuildSnapshot() {
        let s = active
        let b = Bodies.body(s.body)
        let rm = s.r.length
        let up = s.r / rm
        let alt = rm - b.radius
        let fixedDir = World.toBodyFixed(up, body: s.body, time: time)
        let terrain = Terrain.surfaceHeight(body: s.body, direction: fixedDir)
        let spin = World.spin(s.body)
        let vAir = s.v - spin.cross(s.r)
        let va = vAir.length
        let rho = b.density(altitude: alt)
        let p = rho / Bodies.terra.seaLevelDensity
        let onRails = warpIndex >= TimeWarp.physicalCount
        let qd = 0.5 * rho * va * va
        var t = FlightTelemetry()
        t.altitude = alt
        t.heightAboveTerrain = alt - terrain
        t.speed = s.v.length
        t.surfaceSpeed = va
        t.verticalSpeed = s.v.dot(up)
        t.dynamicPressure = qd
        t.mach = rho > 0 ? va / World.speedOfSound(altitude: alt) : 0
        if !s.isOnSurface && s.situation != .crashed {
            t.orbit = OrbitElements(position: s.r, velocity: s.v, mu: b.mu).summary(body: b)
        }
        t.sas = sas
        t.warpFactor = TimeWarp.levels[warpIndex]
        t.warpIndex = warpIndex
        t.warpBlocked = railsBlockReason()
        t.missionTime = launchTime.map { time - $0 } ?? 0
        t.stages = s.ship.stageInfos(pressure: p, gravity: b.surfaceGravity)
        t.thrust = onRails ? 0 : lastThrust
        var maxT = 0.0
        let r = s.ship.bottomSection
        let liq = s.ship.liquidFuel(in: r)
        for k in r {
            let pi = s.ship.parts[k]
            guard pi.spec.kind == .engine, pi.ignited else { continue }
            if pi.spec.isSolid ? pi.fuel > 0 : liq > 1e-9 { maxT += pi.spec.thrust(pressure: p) }
        }
        t.maxThrust = maxT
        t.solidBurning = !onRails && lastSolidThrust > 0
        t.atmosphereDensity = rho
        t.staticPressure = p
        t.heating = s.isOnSurface ? 0 : clamp(rho * va * va * va / 4e7, 0, 1) * clamp((va - 900) / 900, 0, 1)
        t.gForce = (onRails ? 0 : lastProperAccel) / standardGravity
        t.body = s.body
        t.situation = s.situation
        t.chute = s.chute
        t.chuteSafe = rho > 0 && alt < Self.chuteMaxAltitude && va < Self.chuteMaxSpeed
        // Ориентация относительно горизонта.
        let north0 = Vec3.unitZ - up * up.z
        let north = north0.lengthSquared > 1e-12 ? north0.normalized : Vec3.unitX
        let east = north.cross(up)
        let nose = s.q.nose
        t.pitch = asin(clamp(nose.dot(up), -1, 1))
        t.heading = wrap2Pi(atan2(nose.dot(east), nose.dot(north)))
        let horizUp0 = up - nose * nose.dot(up)
        let horizUp: Vec3
        if horizUp0.length > 1e-3 {
            horizUp = horizUp0.normalized
        } else {
            // Нос вертикален: опора — юг, тогда на площадке крен 0.
            horizUp = -north
        }
        let top = s.q.rotate(.unitZ)
        t.roll = atan2(horizUp.cross(top).dot(nose), horizUp.dot(top))
        // Навбол.
        let inv = s.q.conjugate
        func local(_ v: Vec3) -> Vec3? { v.lengthSquared > 1e-12 ? inv.rotate(v.normalized) : nil }
        let n = s.r.cross(s.v)
        var nb = NavballVectors()
        nb.prograde = s.v.length > 0.1 ? local(s.v) : nil
        nb.normal = local(n)
        if s.v.length > 0.1 && n.lengthSquared > 0 {
            nb.radialOut = local(s.v.normalized.cross(n.normalized))
        } else {
            nb.radialOut = local(up)
        }
        nb.surfacePrograde = va > 0.1 ? local(vAir) : nil
        if let node = maneuverNode {
            nb.maneuver = local(TrajectoryPredictor.deltaVVector(node: node, position: s.r, velocity: s.v))
        }
        t.navball = nb
        snapshot = WorldSnapshot(time: time, activeVessel: activeID, vessels: vessels.map(\.state),
                                 lunaPosition: World.lunaPosition(at: time), lunaVelocity: World.lunaVelocity(at: time),
                                 terraRotation: World.terraRotation(at: time), telemetry: t)
    }

    // MARK: Прогноз

    /// Прогноз траектории активного корабля (патченные коники).
    public func predictTrajectory(maxPatches: Int = 3) -> Trajectory {
        TrajectoryPredictor.predict(body: active.body, state: activeStateVector, time: time, maxPatches: maxPatches)
    }

    /// Прогноз орбиты после узла манёвра и время прожига по текущей тяге и массе.
    public func predictManeuver(_ node: ManeuverNode, maxPatches: Int = 3) -> ManeuverPrediction? {
        let perf = active.ship.currentStagePerformance(pressure: 0)
        return TrajectoryPredictor.predict(node: node, body: active.body, state: activeStateVector, time: time,
                                           mass: active.ship.mass, thrust: perf.thrust, isp: perf.isp,
                                           maxPatches: maxPatches)
    }
}
