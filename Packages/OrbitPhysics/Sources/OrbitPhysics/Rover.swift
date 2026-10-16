import Foundation

// Ровер (этап 6.3): отделение, езда на колёсах, водитель, заряд. docs/CONTRACTS.md «Ровер».
//
// Модель: ровер — твёрдое тело (центр масс, скорость, ориентация, угловая скорость в инерциальной системе тела).
// Оси ровера: правый борт +X, вперёд +Y (ось рамы), верх +Z; `Ship.roverBasis` — из осей ровера в оси корабля.
// Колесо — луч подвески к рельефу: пружина-демпфер по нормали грунта (k = m/n·ω², ζ = 0.6), упор при ходе
// больше `suspensionTravel`; сила вдоль грунта — импульсами (мотор, тормоз, качение, боковое сцепление)
// в пределах μ·нагрузка. Корпус (рама — плоская платформа, остальные детали — коробки) касается грунта
// жёсткими точками с трением. Шаг полунеявный, устойчив при h ≤ 0.02 с.

/// Колесо ровера во время полёта.
struct WheelRuntime: Sendable, Hashable {
    /// Индекс детали в `Ship.parts`.
    var part: Int
    var steer = 0.0
    var spin = 0.0
    var compression = 0.0
    var onGround = false
}

/// Состояние отделённого ровера (часть `Vessel`, попадает в `SimCheckpoint`).
struct RoverRuntime: Sendable, Hashable {
    var charge: Double
    var handbrake = false
    var stabilizer = false
    /// Все колёса в порядке деталей.
    var wheels: [WheelRuntime]
    /// Сколько секунд ровер стоит (для закрепления на грунте).
    var restTime = 0.0
    var charging = false
    var motorLoad = 0.0
}

/// Внутренние числа модели езды (A).
enum RoverPhysics {
    /// Ход подвески, м; собственная частота, рад/с; доля критического демпфирования; жёсткость упора (× k).
    static let suspensionTravel = 0.15
    static let suspensionOmega = 10.0
    static let suspensionDamping = 0.6
    static let bottomOut = 10.0
    /// Сопротивление качению (доля нагрузки).
    static let rollingResistance = 0.04
    /// Задний ход — доля `maxSpeed`.
    static let reverseFraction = 0.5
    /// Скорость поворота руля, рад/с.
    static let steerRate = 2.5
    /// При газе против хода быстрее этого (м/с) колёса тормозят, а не крутят мотором.
    static let brakeSpeed = 0.3
    /// Толщина платформы рамы, м (ширина — `diameter`, длина — `height`).
    static let frameThickness = 0.2
    /// Корпус о грунт: трение, жёсткость и демпфирование на точку (× масса).
    static let hullFriction = 0.5
    static let hullStiffness = 150.0
    static let hullDamping = 10.0
    /// Стабилизатор: частота, рад/с; предельный момент — доля m·g·полуколея (не поднимает лежащего на боку).
    static let stabilizerOmega = 4.0
    static let stabilizerTorque = 0.25
    /// Опрокинут: верх ровера к местной вертикали под углом больше acos(0.3) ≈ 73°.
    static let tippedCos = 0.3
    /// Стоит: скорость и вращение относительно грунта меньше этих, без газа — `restDelay` с; затем закреплён.
    static let restSpeed = 0.05
    static let restSpin = 0.05
    static let restDelay = 0.5
    static let frictionIterations = 4
    static let maxAngularSpeed = 10.0
    /// Шаг выборки рельефа для нормали под колесом, м.
    static let normalSpan = 0.4
}

/// Геометрия и инерция ровера в его осях (относительно центра масс); пересчитывается из `Ship`.
struct RoverGeometry {
    struct Wheel {
        /// Индекс в `RoverRuntime.wheels`.
        var index: Int
        var hub: Vec3
        /// Ось колеса (±X ровера).
        var axle: Vec3
        var radius: Double
        var front: Bool
        var motor: Double
        var brake: Double
    }

    var basis: Quat
    /// Центр масс в осях корабля.
    var cm: Vec3
    var mass: Double
    /// Главные моменты инерции по осям ровера, кг·м².
    var inertia: Vec3
    var wheels: [Wheel]
    var hull: [Vec3]
    var halfTrack: Double

    init(_ ship: Ship) {
        let center = ship.centerOfMass
        let inv = ship.roverBasis.conjugate
        basis = ship.roverBasis
        cm = center
        mass = max(ship.mass, 1)
        func body(_ p: Vec3) -> Vec3 { inv.rotate(p - center) }
        var ix = 0.0, iy = 0.0, iz = 0.0
        var ws: [Wheel] = []
        var hull: [Vec3] = []
        var k = 0
        for p in ship.parts {
            let pl = p.placement
            let m = p.spec.dryMass + p.fuel
            let c = body(pl.center)
            let own = m * (pl.height * pl.height + pl.diameter * pl.diameter) / 12
            ix += m * (c.y * c.y + c.z * c.z) + own
            iy += m * (c.x * c.x + c.z * c.z) + own
            iz += m * (c.x * c.x + c.y * c.y) + own
            let axisY = pl.orientation.rotate(.unitY)
            if p.spec.kind == .wheel {
                defer { k += 1 }
                let a = inv.rotate(pl.outward)
                guard abs(a.x) > 0.7 else { continue }
                ws.append(Wheel(index: k, hub: c, axle: Vec3(a.x > 0 ? 1 : -1, 0, 0), radius: p.spec.wheelRadius,
                                front: false, motor: p.spec.wheelMotorForce, brake: p.spec.wheelBrakeForce))
                continue
            }
            // Коробка детали: рама — плоская платформа, остальные — по габаритам.
            let o: Vec3, t: Vec3, ho: Double, ht: Double
            if p.spec.kind == .roverFrame {
                o = pl.orientation.rotate(.unitZ)
                t = pl.orientation.rotate(.unitX)
                ho = RoverPhysics.frameThickness / 2
                ht = pl.diameter / 2
            } else {
                o = pl.outward == .zero ? pl.orientation.rotate(.unitX) : pl.outward
                t = axisY.cross(o).normalized
                ho = pl.diameter / 2
                ht = pl.diameter / 2
            }
            for a in [-1.0, 1.0] {
                for b in [-1.0, 1.0] {
                    for d in [-1.0, 1.0] {
                        hull.append(body(pl.center + o * (a * ho) + axisY * (b * pl.height / 2) + t * (d * ht)))
                    }
                }
            }
        }
        let meanY = ws.isEmpty ? 0 : ws.reduce(0) { $0 + $1.hub.y } / Double(ws.count)
        for i in ws.indices { ws[i].front = ws[i].hub.y > meanY + 0.01 }
        wheels = ws
        self.hull = hull
        inertia = Vec3(max(ix, 1), max(iy, 1), max(iz, 1))
        halfTrack = ws.map { abs($0.hub.x) }.max() ?? 0.5
    }
}

extension Ship {
    /// Корень — рама ровера (отделённый ровер).
    var isRover: Bool { parts.first { $0.parent == nil }?.spec.kind == .roverFrame }
    /// Из осей ровера (правый борт X, вперёд Y, верх Z) в оси корабля: ориентация рамы-корня.
    var roverBasis: Quat {
        (parts.first { $0.parent == nil && $0.spec.kind == .roverFrame } ?? parts.first { $0.spec.kind == .roverFrame })?
            .placement.orientation ?? .identity
    }
    /// Рама ровера, висящая прямо на боковом разделителе (её можно отделить), uid.
    var roverMountFrame: Int? {
        parts.first { p in
            p.spec.kind == .roverFrame && p.parent.flatMap { pid in parts.first { $0.uid == pid } }?.id == .decouplerRadial
        }?.uid
    }
    var roverChargeCapacity: Double { parts.reduce(0) { $0 + $1.spec.chargeCapacity } }
    var roverSolarRate: Double { parts.reduce(0) { $0 + $1.spec.solarRate } }
    /// Кто ведёт: космонавт в кресле.
    var roverDriver: String? { parts.first { $0.spec.kind == .seat && !$0.crew.isEmpty }?.crew.first }
    var hasProbe: Bool { parts.contains { $0.spec.kind == .probe } }
}

extension FlightSim {
    // MARK: Ввод и команды

    public func setRoverInput(_ input: RoverInput) {
        roverInput = active.rover != nil ? input : .neutral
    }

    func sendRover(_ command: FlightCommand) {
        let ai = activeIndex
        switch command {
        case .setHandbrake(let on): vessels[ai].rover?.handbrake = on
        case .setRoverStabilizer(let on): vessels[ai].rover?.stabilizer = on
        case .deployRover: deployRover()
        case .selectVessel(let id): selectVessel(id)
        default: break
        }
    }

    /// Можно ли ехать: водитель в кресле или модуль управления, и есть заряд.
    func roverCanDrive(_ v: Vessel) -> Bool {
        guard let rv = v.rover else { return false }
        return (v.ship.roverDriver != nil || v.ship.hasProbe) && rv.charge > 1e-9
    }

    func isControllable(_ v: Vessel) -> Bool {
        v.situation != .crashed && (v.ship.hasProbe || v.ship.parts.contains { !$0.crew.isEmpty })
    }

    func roverDeployable(_ v: Vessel) -> Bool {
        (v.situation == .landed || v.situation == .prelaunch) && v.rover == nil && v.ship.roverMountFrame != nil
    }

    private func selectVessel(_ id: VesselID) {
        guard let k = vessels.firstIndex(where: { $0.id == id }),
              k == activeIndex || isControllable(vessels[k]) else { return }
        if k != activeIndex { makeActive(k) }
        controlledCosmonaut = nil
        evaInput = .neutral
    }

    /// Закрепить ровер на грунте в текущей позе (неподвижен в системе тела).
    func settleRover(_ k: Int) {
        vessels[k].rover?.restTime = 0
        vessels[k].rover?.motorLoad = 0
        landVessel(k, situation: .landed)
    }

    /// Неактивные роверы на грунте — закреплены (страховка; закрепляет и `makeActive`).
    func settleLooseRovers() {
        let ai = activeIndex
        for k in vessels.indices where k != ai && vessels[k].rover != nil && vessels[k].isOnSurface
            && vessels[k].fixedPos == nil {
            settleRover(k)
        }
    }

    // MARK: Отделение

    /// Боковой разделитель ровера срабатывает: ровер — отдельный корабль колёсами вниз на грунте в ~3 м от борта
    /// (по направлению крепления), неподвижно; разделитель остаётся на корабле, активным остаётся корабль.
    private func deployRover() {
        let ai = activeIndex
        var s = vessels[ai]
        guard roverDeployable(s), let frameUID = s.ship.roverMountFrame, let fi = s.ship.index(of: frameUID) else { return }
        let framePl = s.ship.parts[fi].placement
        let up0 = s.r.normalized
        var out = s.q.rotate(framePl.center)
        out -= up0 * out.dot(up0)
        if out.lengthSquared < 1e-6 {
            out = Cosmonaut.horizontal(s.q.rotate(framePl.outward == .zero ? .unitX : framePl.outward), up: up0) * 1e-3
        }
        let dir = out.normalized
        let center = s.r + dir * (out.length + RoverBalance.deployDistance)
        let stageNo = s.ship.decouplerCount
        let cut = s.ship.split(removing: s.ship.subtree(frameUID))
        if cut.shift != .zero { s.r += s.q.rotate(cut.shift) }
        vessels[ai] = s
        if cut.shift != .zero && s.fixedPos != nil { landVessel(ai, situation: s.situation) }
        stageCache = nil

        let ship = cut.debris
        let wheels = ship.parts.indices.filter { ship.parts[$0].spec.kind == .wheel }.map { WheelRuntime(part: $0) }
        var r = Vessel(id: nextID, body: s.body, r: center, v: s.v, q: s.q, ship: ship,
                       situation: .landed, chute: .none, isActive: false)
        nextID += 1
        r.name = "Тропа"
        r.rover = RoverRuntime(charge: ship.roverChargeCapacity, wheels: wheels)
        vessels.append(r)
        let k = vessels.count - 1
        placeRover(k, at: center, forward: dir)
        landVessel(k, situation: .landed)
        events.append(.separation(stage: stageNo))
    }

    /// Поставить ровер колёсами на грунт: верх — по нормали рельефа, сжатие подвески — статическое.
    func placeRover(_ k: Int, at point: Vec3, forward: Vec3) {
        var v = vessels[k]
        let geo = RoverGeometry(v.ship)
        let inv = World.bodyRotation(v.body, time: time).conjugate
        let g = groundNormal(point, body: v.body, inverse: inv, span: 1.0)
        let up = g.normal
        var f = forward - up * forward.dot(up)
        if f.lengthSquared < 1e-9 { f = Cosmonaut.horizontal(.unitX, up: up) }
        f = f.normalized
        let qr = Quat(basisX: f.cross(up), y: f, z: up)
        let gl = Bodies.body(v.body).mu / point.lengthSquared
        let target = min(RoverPhysics.suspensionTravel, gl / (RoverPhysics.suspensionOmega * RoverPhysics.suspensionOmega))
        let lowest = (geo.wheels.map { $0.hub.z - $0.radius } + (geo.wheels.isEmpty ? geo.hull.map(\.z) : [])).min() ?? 0
        var x = g.point - up * lowest
        for _ in 0..<4 where !geo.wheels.isEmpty {
            var pen = 0.0
            for w in geo.wheels {
                pen += wheelContact(hub: x + qr.rotate(w.hub), axle: qr.rotate(w.axle), radius: w.radius,
                                    body: v.body, inverse: inv)?.depth ?? -0.05
            }
            x += up * (pen / Double(geo.wheels.count) - target)
        }
        v.q = (qr * geo.basis.conjugate).normalized
        v.r = x - v.q.rotate(geo.cm)
        v.v = World.surfaceVelocity(body: v.body, position: x)
        v.w = World.spin(v.body)
        if var rv = v.rover {
            for w in geo.wheels {
                let d = wheelContact(hub: x + qr.rotate(w.hub), axle: qr.rotate(w.axle), radius: w.radius,
                                     body: v.body, inverse: inv)?.depth ?? -1
                rv.wheels[w.index].onGround = d > 0
                rv.wheels[w.index].compression = clamp(d, 0, RoverPhysics.suspensionTravel)
            }
            v.rover = rv
        }
        vessels[k] = v
    }

    // MARK: Грунт

    /// Точка грунта под/над `p` (по радиусу); `inverse` — из инерциальной системы тела в связанную.
    func groundPoint(_ p: Vec3, body: BodyID, inverse: Quat) -> Vec3 {
        let dir = p.normalized
        return dir * (Bodies.body(body).radius + Terrain.surfaceHeight(body: body, direction: inverse.rotate(dir)))
    }

    /// Точка грунта под `p` и нормаль рельефа (по двум соседним выборкам на `span` м).
    func groundNormal(_ p: Vec3, body: BodyID, inverse: Quat, span: Double) -> (point: Vec3, normal: Vec3) {
        let g0 = groundPoint(p, body: body, inverse: inverse)
        let up = p.normalized
        let e1 = Cosmonaut.horizontal(.unitX, up: up)
        let e2 = up.cross(e1)
        let g1 = groundPoint(p + e1 * span, body: body, inverse: inverse)
        let g2 = groundPoint(p + e2 * span, body: body, inverse: inverse)
        var n = (g1 - g0).cross(g2 - g0)
        if n.lengthSquared < 1e-12 { return (g0, up) }
        n = n.normalized
        return (g0, n.dot(up) < 0 ? -n : n)
    }

    /// Касание колеса: нижняя точка обода к грунту, нормаль и глубина (> 0 — колесо вдавлено). nil — колесо лежит.
    func wheelContact(hub: Vec3, axle: Vec3, radius: Double, body: BodyID,
                      inverse: Quat) -> (point: Vec3, normal: Vec3, depth: Double)? {
        let g = groundNormal(hub, body: body, inverse: inverse, span: RoverPhysics.normalSpan)
        let n = g.normal
        var down = -(n - axle * axle.dot(n))
        guard down.lengthSquared > 1e-6 else { return nil }
        down = down.normalized
        let c = hub + down * radius
        return (c, n, -(c - g.point).dot(n))
    }

    // MARK: Шаг

    private struct Contact {
        var r: Vec3
        var point: Vec3
        var fw: Vec3
        var lw: Vec3
        /// Предел трения μ·N·h; предел продольного (тормоз/качение), импульс мотора; накопленные импульсы.
        var cap: Double
        var longMax: Double
        var drive: Double
        var jl = 0.0
        var js = 0.0
        var ml: Double
        var ms: Double
    }

    /// Шаг активного ровера на грунте; `time` — начало шага.
    func stepRover(_ ai: Int, _ h: Double) {
        var s = vessels[ai]
        guard var rv = s.rover else { return }
        let geo = RoverGeometry(s.ship)
        let body = Bodies.body(s.body)
        var qr = (s.q * geo.basis).normalized
        var x = s.r + s.q.rotate(geo.cm)
        let upR = x.normalized
        let tipped = qr.rotate(.unitZ).dot(upR) < RoverPhysics.tippedCos
        let able = roverCanDrive(s) && !tipped
        let input = able ? roverInput : .neutral
        let drive = clamp(input.drive, -1, 1)
        let steerTarget = clamp(input.steer, -1, 1) * RoverBalance.maxSteer
        for w in geo.wheels {
            let cur = rv.wheels[w.index].steer
            let target = w.front ? steerTarget : 0
            let step = RoverPhysics.steerRate * h
            rv.wheels[w.index].steer = cur + clamp(target - cur, -step, step)
        }
        // Заряд от солнца.
        let cap = s.ship.roverChargeCapacity
        let solar = s.ship.roverSolarRate
        let sun = World.position(of: .sol, relativeTo: s.body, at: time) - x
        rv.charging = solar > 0 && rv.charge < cap && sun.dot(upR) > 0
        if rv.charging { rv.charge = min(cap, rv.charge + solar * h) }
        s.ship.cool(dt: h, environment: World.thermalEnvironment(body: s.body, position: s.r, time: time))

        if s.fixedPos != nil {
            // Стоит закреплённым: трогается газом (без ручника).
            guard abs(drive) > 0.01 && !rv.handbrake else {
                rv.motorLoad = 0
                s.rover = rv
                vessels[ai] = s
                return
            }
            s.fixedPos = nil
            s.fixedAtt = nil
            rv.restTime = 0
        }

        let m = geo.mass
        let inertia = geo.inertia
        let spin = World.spin(s.body)
        let inv = World.bodyRotation(s.body, time: time).conjugate
        let gl = body.mu / x.lengthSquared
        var vel = s.v
        var w = s.w
        func invI(_ t: Vec3) -> Vec3 {
            let l = qr.conjugate.rotate(t)
            return qr.rotate(Vec3(l.x / inertia.x, l.y / inertia.y, l.z / inertia.z))
        }
        func effMass(_ r: Vec3, _ d: Vec3) -> Double {
            let a = qr.conjugate.rotate(r.cross(d))
            return 1 / (1 / m + a.x * a.x / inertia.x + a.y * a.y / inertia.y + a.z * a.z / inertia.z)
        }
        var dv = upR * (-gl * h)
        var dw = Vec3.zero
        var contacts: [Contact] = []
        let mw = m / Double(max(1, geo.wheels.count))
        let om = RoverPhysics.suspensionOmega
        let k = mw * om * om
        let c = 2 * RoverPhysics.suspensionDamping * mw * om
        let mu = RoverBalance.tireFriction
        var motorUse = 0.0

        for wh in geo.wheels {
            var st = rv.wheels[wh.index]
            let hub = x + qr.rotate(wh.hub)
            guard let ct = wheelContact(hub: hub, axle: qr.rotate(wh.axle), radius: wh.radius, body: s.body, inverse: inv),
                  ct.depth > 0 else {
                st.onGround = false
                st.compression = 0
                rv.wheels[wh.index] = st
                continue
            }
            let n = ct.normal
            let r = ct.point - x
            let vc = vel + w.cross(r) - spin.cross(ct.point)
            let vn = vc.dot(n)
            var fn = k * ct.depth - c * vn
            if ct.depth > RoverPhysics.suspensionTravel {
                fn += RoverPhysics.bottomOut * k * (ct.depth - RoverPhysics.suspensionTravel)
            }
            fn = max(0, fn)
            st.onGround = true
            st.compression = min(ct.depth, RoverPhysics.suspensionTravel)
            var fw = qr.rotate(Vec3(sin(st.steer), cos(st.steer), 0))
            fw -= n * fw.dot(n)
            guard fw.lengthSquared > 1e-9 else {
                rv.wheels[wh.index] = st
                continue
            }
            fw = fw.normalized
            let lw = n.cross(fw)
            let vl = vc.dot(fw)
            let capJ = mu * fn * h
            var driveJ = 0.0
            var brake = 0.0
            if rv.handbrake {
                brake = wh.brake
            } else if abs(drive) > 0.01 {
                if drive * vl < 0 && abs(vl) > RoverPhysics.brakeSpeed {
                    brake = abs(drive) * wh.brake
                } else {
                    let top = RoverBalance.maxSpeed * (drive > 0 ? 1 : RoverPhysics.reverseFraction)
                    let taper = clamp(1 - vl * (drive > 0 ? 1 : -1) / top, 0, 1)
                    driveJ = clamp(drive * wh.motor * taper * h, -capJ, capJ)
                    motorUse += abs(drive)
                }
            }
            let j = n * (fn * h) + fw * driveJ
            dv += j / m
            dw += invI(r.cross(j))
            contacts.append(Contact(r: r, point: ct.point, fw: fw, lw: lw, cap: capJ,
                                    longMax: max(brake, RoverPhysics.rollingResistance * fn) * h, drive: driveJ,
                                    ml: effMass(r, fw), ms: effMass(r, lw)))
            st.spin += vl / wh.radius * h
            rv.wheels[wh.index] = st
        }

        // Корпус о грунт.
        for p in geo.hull {
            let pt = x + qr.rotate(p)
            let pen = groundPoint(pt, body: s.body, inverse: inv).length - pt.length
            guard pen > 0 else { continue }
            let n = pt / pt.length
            let r = pt - x
            let vc = vel + w.cross(r) - spin.cross(pt)
            let vn = vc.dot(n)
            let fn = max(0, m * (RoverPhysics.hullStiffness * pen - RoverPhysics.hullDamping * vn))
            let j = n * (fn * h)
            dv += j / m
            dw += invI(r.cross(j))
            let vt = vc - n * vn
            let fw = vt.lengthSquared > 1e-12 ? vt.normalized : Cosmonaut.horizontal(qr.rotate(.unitY), up: n)
            let lw = n.cross(fw)
            let capJ = RoverPhysics.hullFriction * fn * h
            contacts.append(Contact(r: r, point: pt, fw: fw, lw: lw, cap: capJ, longMax: capJ, drive: 0,
                                    ml: effMass(r, fw), ms: effMass(r, lw)))
        }

        // Стабилизатор: момент к местной вертикали (крен и тангаж), слабый.
        if rv.stabilizer && rv.charge > 1e-9 {
            let u = qr.rotate(.unitZ)
            if u.dot(upR) > 0 {
                let ws = RoverPhysics.stabilizerOmega
                var wRel = w - spin
                wRel -= u * wRel.dot(u)
                let alpha = u.cross(upR) * (ws * ws) - wRel * (2 * ws)
                let l = qr.conjugate.rotate(alpha)
                var tb = Vec3(l.x * inertia.x, l.y * inertia.y, 0)
                let tmax = RoverPhysics.stabilizerTorque * m * gl * geo.halfTrack
                let tl = tb.length
                if tl > tmax { tb = tb * (tmax / tl) }
                dw += invI(qr.rotate(tb)) * h
            }
        }
        vel += dv
        w += dw

        // Трение: последовательные импульсы в пределах μ·N (продольное — тормоз/качение, боковое — сцепление).
        for _ in 0..<RoverPhysics.frictionIterations {
            for i in contacts.indices {
                var ct = contacts[i]
                let vc = vel + w.cross(ct.r) - spin.cross(ct.point)
                var jl = clamp(ct.jl - vc.dot(ct.fw) * ct.ml, -ct.longMax, ct.longMax)
                jl = clamp(jl, -ct.cap - ct.drive, ct.cap - ct.drive)
                let long = ct.drive + jl
                let allow = max(0, ct.cap * ct.cap - long * long).squareRoot()
                let js = clamp(ct.js - vc.dot(ct.lw) * ct.ms, -allow, allow)
                let j = ct.fw * (jl - ct.jl) + ct.lw * (js - ct.js)
                vel += j / m
                w += invI(ct.r.cross(j))
                ct.jl = jl
                ct.js = js
                contacts[i] = ct
            }
        }

        let wl = w.length
        if wl > RoverPhysics.maxAngularSpeed { w = w * (RoverPhysics.maxAngularSpeed / wl) }
        x += vel * h
        let wl2 = w.length
        if wl2 > 1e-12 { qr = (Quat(axis: w / wl2, angle: wl2 * h) * qr).normalized }
        s.q = (qr * geo.basis.conjugate).normalized
        s.r = x - s.q.rotate(geo.cm)
        s.v = vel
        s.w = w

        // Расход заряда мотором.
        rv.charge = max(0, rv.charge - RoverBalance.motorDrain * motorUse * h)
        rv.motorLoad = geo.wheels.isEmpty ? 0 : motorUse / Double(geo.wheels.count)
        let vRel = vel - spin.cross(x)
        if vRel.length < RoverPhysics.restSpeed && (w - spin).length < RoverPhysics.restSpin && abs(drive) < 0.01 {
            rv.restTime += h
        } else {
            rv.restTime = 0
        }
        s.rover = rv
        vessels[ai] = s
        if rv.restTime >= RoverPhysics.restDelay {
            // Поза — на конец шага.
            let saved = time
            time = saved + h
            settleRover(ai)
            time = saved
        }
    }

    // MARK: Снимок

    func roverStatus(_ v: Vessel) -> RoverStatus? {
        guard let rv = v.rover else { return nil }
        let geo = RoverGeometry(v.ship)
        let qr = (v.q * geo.basis).normalized
        let x = v.r + v.q.rotate(geo.cm)
        let up = x.normalized
        let fwd = Cosmonaut.horizontal(qr.rotate(.unitY), up: up)
        let speed = v.fixedPos != nil ? 0 : (v.v - World.spin(v.body).cross(x)).dot(fwd)
        var dist: Double?
        for o in vessels where o.id != v.id && o.body == v.body && o.situation != .crashed
            && o.rover == nil && !o.ship.hatches.isEmpty {
            let d = (o.r - v.r).length
            if dist.map({ d < $0 }) ?? true { dist = d }
        }
        return RoverStatus(speed: speed, charge: rv.charge, chargeCapacity: v.ship.roverChargeCapacity,
                           charging: rv.charging, handbrake: rv.handbrake, stabilizer: rv.stabilizer,
                           wheelsOnGround: rv.wheels.filter(\.onGround).count, wheelCount: rv.wheels.count,
                           tipped: qr.rotate(.unitZ).dot(up) < RoverPhysics.tippedCos,
                           driverID: v.ship.roverDriver, canDrive: roverCanDrive(v), distanceToShip: dist,
                           motorLoad: rv.motorLoad)
    }

    /// Поля снимка ровера: статус активного, можно ли отделить, кем можно управлять.
    func fillRoverSnapshot() {
        let a = active
        snapshot.rover = roverStatus(a)
        snapshot.roverDeployable = roverDeployable(a)
        snapshot.controllable = vessels.filter { $0.isActive && $0.situation != .crashed || isControllable($0) }
            .map { ControllableVessel(id: $0.id, isRover: $0.rover != nil, name: $0.name) }
    }
}
