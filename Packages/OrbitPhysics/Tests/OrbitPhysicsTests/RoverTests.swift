import Foundation
import Testing
@testable import OrbitPhysics

// Этап 6.3: ровер (docs/CONTRACTS.md «Ровер»).

@Suite("Ровер: сборка, отделение, езда, водитель, заряд")
struct RoverTests {
    /// Посадочная ступень «Луны-Р»: К-1 + Т-800 (с ровером) + опоры + «Штиль».
    static let lander: VesselDesign = {
        var d = VesselDesign(name: "Лунник-Р", parts: [.podK1, .t800, .legs, .shtil])
        d.addRover(on: 1)
        return d
    }()
    /// То же с ЛК-2: двое на борту (выбор корабля/ровера).
    static let lander2: VesselDesign = {
        var d = VesselDesign(name: "Лунник-Р2", parts: [.lk2, .t800, .legs, .shtil])
        d.addRover(on: 1)
        return d
    }()

    /// Направление на Солнце от Луны в момент 0 (день) и от него — ночь.
    static let sunUp = World.position(of: .sol, relativeTo: .luna, at: 0).normalized
    static let day = (sunUp + Vec3(0.02, -0.01, 0.015)).normalized
    static let night = (-sunUp + Vec3(0.02, -0.01, 0.015)).normalized

    /// Посадочный корабль с ровером на грунте Луны (Луна не вращается).
    func landed(_ design: VesselDesign = lander, up: Vec3 = day) -> FlightSim {
        let ground = Bodies.luna.radius + Terrain.surfaceHeight(body: .luna, direction: up)
        let sim = FlightSim(design: design, body: .luna, position: up * (ground + 2), velocity: up * -0.5,
                            attitude: Quat.looking(nose: up, zHint: .unitZ))
        for _ in 0..<600 where sim.activeSituation != .landed { _ = sim.advance(realDelta: 1.0 / 60) }
        return sim
    }

    func roverIndex(_ sim: FlightSim) -> Int? { sim.vessels.firstIndex { $0.rover != nil } }

    func roverState(_ sim: FlightSim) throws -> VesselState {
        let id = try #require(roverIndex(sim).map { sim.vessels[$0].id })
        return try #require(sim.snapshot.vessels.first { $0.id == id })
    }

    /// Отделить ровер и посадить в кресло первого космонавта (выход по лестнице, перенос к креслу).
    func deployAndBoard(_ sim: FlightSim) throws {
        sim.send(.deployRover)
        _ = sim.advance(realDelta: 1.0 / 60)
        sim.send(.evaExit)
        _ = sim.advance(realDelta: 1.0 / 60)
        let ci = try #require(sim.controlledIndex)
        let ri = try #require(roverIndex(sim))
        let rv = sim.vessels[ri]
        let seat = try #require(rv.ship.hatches.first)
        let p = rv.r + rv.q.rotate(seat.point)
        // Встать на грунт в метре от кресла.
        let side = Cosmonaut.horizontal(rv.q.rotate(rv.ship.roverBasis.rotate(.unitX)), up: p.normalized)
        sim.cosmonauts[ci].grip = nil
        sim.cosmonauts[ci].bodyUp = nil
        sim.cosmonauts[ci].r = sim.surfacePoint(body: .luna, near: p + side * 1.0, time: sim.time)
        sim.cosmonauts[ci].v = .zero
        sim.cosmonauts[ci].onGround = true
        _ = sim.advance(realDelta: 1.0 / 60)
        let c = try #require(sim.snapshot.controlled)
        #expect(c.hatchIsSeat && c.canBoard)
        sim.send(.evaBoard)
        _ = sim.advance(realDelta: 1.0 / 60)
    }

    /// Ехать с вводом `input` `seconds` секунд кадрами по 1/60 с.
    @discardableResult
    func drive(_ sim: FlightSim, _ input: RoverInput, seconds: Double,
               each: ((FlightSim) -> Void)? = nil) -> [SimEvent] {
        var ev: [SimEvent] = []
        for _ in 0..<Int(seconds * 60) {
            sim.setRoverInput(input)
            ev += sim.advance(realDelta: 1.0 / 60)
            each?(sim)
        }
        return ev
    }

    func forward(_ sim: FlightSim) throws -> Vec3 {
        let ri = try #require(roverIndex(sim))
        let v = sim.vessels[ri]
        return Cosmonaut.horizontal(v.q.rotate(v.ship.roverBasis.rotate(.unitY)), up: v.r.normalized)
    }

    // MARK: Сборка

    @Test func lunaRoverAssemblesCleanly() {
        let d = VesselDesign.lunaRover
        #expect(VesselDesign.presets.contains(d))
        #expect(!d.issues().contains { $0.isBlocking }, "\(d.issues())")
        #expect(d.issues().isEmpty, "\(d.issues())")
        // Разделитель ровера не в ступенях: ступени — как у «Луны».
        #expect(d.stageGroups.count == VesselDesign.luna.stageGroups.count)
        let dec = d.nodes.first { $0.part == .decouplerRadial }
        #expect(dec?.stage == nil)
        // Колёса по бортам рамы, верх ровера — наружу (−Z корабля).
        let lay = d.layout()
        let frame = d.nodes.firstIndex { $0.part == .roverFrame }!
        let wheels = d.nodes.indices.filter { d.nodes[$0].part == .wheelK1 }
        #expect(wheels.count == 4)
        for w in wheels {
            #expect(abs(abs(lay[w].center.x - lay[frame].center.x) - 0.425) < 1e-6)
            #expect(abs(lay[w].center.z - lay[frame].center.z) < 1e-6)
        }
        let seat = d.nodes.firstIndex { $0.part == .roverSeat }!
        #expect(lay[seat].center.z < lay[frame].center.z)
        // Кресло само не заполняется.
        #expect(d.seating().filter { $0.memberID != nil }.count == 1)
    }

    @Test func roverPartsAttachOnlyToFrame() {
        var d = VesselDesign(name: "т", parts: [.probe, .t400])
        let tank = AttachTarget(parent: 1, node: .radial, angle: 0, height: 0.5, position: .zero)
        #expect(!VesselEditing.canAttach(.wheelK1, to: tank, in: d))
        #expect(!VesselEditing.canAttach(.roverSeat, to: tank, in: d))
        #expect(VesselEditing.canAttach(.roverFrame, to: tank, in: d))
        let ids = VesselEditing.attach(.roverFrame, to: tank, symmetry: 1, in: &d)
        let frame = try! #require(ids.first)
        let side = AttachTarget(parent: frame, node: .radial, angle: 0, height: 0.5, position: .zero)
        #expect(VesselEditing.canAttach(.wheelK1, to: side, in: d))
        #expect(VesselEditing.canAttach(.batteryB1, to: side, in: d))
        #expect(!VesselEditing.canAttach(.wheelK1, to: AttachTarget(parent: frame, node: .bottom, position: .zero), in: d))
        let w = VesselEditing.attach(.wheelK1, to: side, symmetry: 2, in: &d)
        #expect(w.count == 2)
        // Колесо детей не принимает.
        #expect(!VesselEditing.canAttach(.t100, to: AttachTarget(parent: w[0], node: .bottom, position: .zero), in: d))
        // Ручная правка ступеней не даёт разделителю ровера ступень.
        var r = VesselDesign.lunaRover
        VesselEditing.setStage(r.nodes.first { $0.part == .titan }!.id, to: 0, in: &r)
        let leg = AttachTarget(parent: 0, node: .top, position: .zero)
        _ = VesselEditing.attach(.chute, to: leg, symmetry: 1, in: &r)
        #expect(r.nodes.first { $0.part == .decouplerRadial }?.stage == nil)
    }

    @Test func roversTechnology() {
        let t = TechTree.node(.rovers)
        #expect(Set(t.parts) == [.roverFrame, .wheelK1, .wheelK2, .batteryB1, .solarS1, .roverSeat])
        let cells = TechTree.nodes.map { [$0.column, $0.row] }
        #expect(Set(cells).count == cells.count)
    }

    /// Автопилот сцены `lunaLanding` сажает «Луну-Р» на Луну.
    @Test func autopilotLandsLunaRover() {
        let sim = FlightSim(design: .lunaRover)
        let ap = Autopilot(goal: .lunaLanding)
        var crashed = false
        var touchdown: Double?
        while !ap.isFinished && sim.time < 300_000 {
            ap.update(sim)
            let ev = sim.advance(realDelta: ap.frameDelta)
            for e in ev {
                if case .crash = e { crashed = true }
                if case .touchdown(let v) = e, sim.activeBody == .luna { touchdown = v }
            }
        }
        print("Луна-Р: \(ap.phase), касание \(touchdown ?? -1) м/с, t = \(Int(sim.time)) с")
        #expect(ap.phase == .done)
        #expect(!crashed)
        #expect(sim.activeBody == .luna && sim.activeSituation == .landed)
        #expect(sim.snapshot.roverDeployable)
    }

    // MARK: Отделение

    @Test func deployPutsRoverOnFourWheels() throws {
        let sim = landed()
        #expect(sim.activeSituation == .landed)
        #expect(sim.snapshot.roverDeployable)
        #expect(sim.snapshot.rover == nil)
        let landerID = sim.snapshot.activeVessel
        let ev = { sim.send(.deployRover); return sim.advance(realDelta: 1.0 / 60) }()
        #expect(ev.contains { if case .separation = $0 { return true }; return false })
        #expect(sim.snapshot.activeVessel == landerID)
        #expect(!sim.snapshot.roverDeployable)
        #expect(sim.vessels.count == 2)
        let rv = try roverState(sim)
        #expect(rv.wheels.count == 4 && rv.wheels.allSatisfy(\.onGround))
        #expect(rv.situation == .landed)
        #expect(rv.hatches.count == 1)
        // Около 3 м от борта: центр ровера ~4.4 м от оси корабля.
        let lander = try #require(sim.snapshot.vessels.first { $0.id == landerID })
        let rvi = try #require(roverIndex(sim))
        let cm = sim.vessels[rvi].r + sim.vessels[rvi].q.rotate(sim.vessels[rvi].ship.centerOfMass)
        var d = cm - lander.position
        d -= lander.position.normalized * d.dot(lander.position.normalized)
        #expect(d.length > 3.5 && d.length < 5, "\(d.length) \(sim.vessels[rvi].ship.centerOfMass)")
        // Неподвижен.
        let p0 = rv.position
        _ = sim.advance(realDelta: 2)
        #expect((try roverState(sim).position - p0).length < 1e-9)
        // Верх ровера — по местной вертикали.
        let ri = try #require(roverIndex(sim))
        let v = sim.vessels[ri]
        let up = v.q.rotate(v.ship.roverBasis.rotate(.unitZ))
        #expect(up.dot(v.r.normalized) > 0.95)
        // На корабле остались его детали, разделитель — на месте.
        #expect(sim.vessels[sim.activeIndex].ship.parts.map(\.id) == [.podK1, .t800, .decouplerRadial, .legs, .shtil])
    }

    // MARK: Водитель и езда

    @Test func boardSeatMakesRoverActiveAndDrives() throws {
        let sim = landed()
        try deployAndBoard(sim)
        let r = try #require(sim.snapshot.rover)
        #expect(sim.snapshot.controlledCosmonaut == nil && sim.snapshot.cosmonauts.isEmpty)
        #expect(r.driverID == "lera" && r.canDrive && !r.tipped)
        #expect(r.wheelsOnGround == 4 && r.wheelCount == 4)
        #expect(abs(r.charge - RoverBalance.batteryCapacity) < 1)
        #expect(r.distanceToShip.map { $0 > 2 && $0 < 8 } ?? false)
        #expect(sim.snapshot.controllable.contains { $0.isRover && $0.name == "Тропа" })
        #expect(sim.railsBlockReason() == nil)
        let f0 = try forward(sim)
        var maxSpeed = 0.0
        var tipped = false
        drive(sim, RoverInput(drive: 1), seconds: 10) { s in
            maxSpeed = max(maxSpeed, s.snapshot.rover?.speed ?? 0)
            tipped = tipped || (s.snapshot.rover?.tipped ?? true)
        }
        let st = try #require(sim.snapshot.rover)
        print("Луна, газ 10 с: скорость \(st.speed) м/с, заряд \(st.charge)")
        #expect(st.speed > 3 && maxSpeed <= RoverBalance.maxSpeed + 1e-6)
        #expect(!tipped && st.wheelsOnGround >= 3)
        #expect(st.charge < RoverBalance.batteryCapacity - 3)
        #expect(st.motorLoad > 0.5)
        #expect(sim.railsBlockReason() == .thrust)
        // Ехал вперёд.
        #expect(try forward(sim).dot(f0) > 0.99)
    }

    @Test func steerRightTurnsRight() throws {
        let sim = landed()
        try deployAndBoard(sim)
        drive(sim, RoverInput(drive: 1), seconds: 3)
        let ri = try #require(roverIndex(sim))
        let v0 = sim.vessels[ri]
        let right0 = v0.q.rotate(v0.ship.roverBasis.rotate(.unitX))
        drive(sim, RoverInput(drive: 1, steer: 1), seconds: 2)
        let f1 = try forward(sim)
        #expect(f1.dot(right0) > 0.2, "\(f1.dot(right0))")
        let wheels = try roverState(sim).wheels
        #expect(wheels.filter { $0.steer > 0.4 }.count == 2)
        // Влево — в другую сторону.
        drive(sim, RoverInput(drive: 1, steer: -1), seconds: 4)
        #expect(try forward(sim).dot(right0) < f1.dot(right0))
    }

    @Test func handbrakeStopsAndRoverSettles() throws {
        let sim = landed()
        try deployAndBoard(sim)
        drive(sim, RoverInput(drive: 1), seconds: 5)
        #expect((sim.snapshot.rover?.speed ?? 0) > 2)
        sim.send(.setHandbrake(true))
        #expect(sim.snapshot.rover?.handbrake == true)
        drive(sim, .neutral, seconds: 5)
        let ri = try #require(roverIndex(sim))
        #expect(abs(sim.snapshot.rover?.speed ?? 9) < 0.05)
        #expect(sim.vessels[ri].fixedPos != nil)
        #expect(sim.railsBlockReason() == nil)
        // С ручником газ не трогает.
        let p = sim.vessels[ri].r
        drive(sim, RoverInput(drive: 1), seconds: 2)
        #expect((sim.vessels[ri].r - p).length < 1e-9)
        sim.send(.setHandbrake(false))
        drive(sim, RoverInput(drive: 1), seconds: 2)
        #expect((sim.vessels[ri].r - p).length > 0.5)
    }

    @Test func noDriverDoesNotMove() throws {
        let sim = landed()
        sim.send(.deployRover)
        _ = sim.advance(realDelta: 1.0 / 60)
        let ri = try #require(roverIndex(sim))
        // Ровер без водителя и модуля — им нельзя управлять.
        #expect(!sim.snapshot.controllable.contains { $0.isRover })
        sim.send(.selectVessel(sim.vessels[ri].id))
        #expect(sim.snapshot.rover == nil)
        sim.makeActive(ri)
        _ = sim.advance(realDelta: 1.0 / 60)
        let r = try #require(sim.snapshot.rover)
        #expect(r.driverID == nil && !r.canDrive)
        let p = sim.vessels[ri].r
        drive(sim, RoverInput(drive: 1, steer: 1), seconds: 3)
        #expect((sim.vessels[ri].r - p).length < 1e-9)
    }

    @Test func noChargeNoDrive() throws {
        let sim = landed(up: Self.night)
        try deployAndBoard(sim)
        let ri = try #require(roverIndex(sim))
        sim.vessels[ri].rover?.charge = 0
        _ = sim.advance(realDelta: 1.0 / 60)
        let r = try #require(sim.snapshot.rover)
        #expect(!r.canDrive && !r.charging && r.driverID == "lera")
        let p = sim.vessels[ri].r
        drive(sim, RoverInput(drive: 1), seconds: 3)
        #expect((sim.vessels[ri].r - p).length < 1e-9)
        #expect(sim.snapshot.rover?.charge == 0)
    }

    @Test func solarPanelChargesInSunlight() throws {
        let sim = landed()
        try deployAndBoard(sim)
        let ri = try #require(roverIndex(sim))
        sim.vessels[ri].rover?.charge = 50
        _ = sim.advance(realDelta: 10)
        let r = try #require(sim.snapshot.rover)
        #expect(r.charging)
        #expect(abs(r.charge - (50 + 10 * RoverBalance.solarCharge)) < 0.1, "\(r.charge)")
        // Ночью — нет.
        let dark = landed(up: Self.night)
        try deployAndBoard(dark)
        let rj = try #require(roverIndex(dark))
        dark.vessels[rj].rover?.charge = 50
        _ = dark.advance(realDelta: 10)
        #expect(dark.snapshot.rover?.charging == false && dark.snapshot.rover?.charge == 50)
    }

    @Test func sharpTurnAtSpeedStaysFinite() throws {
        let sim = landed()
        try deployAndBoard(sim)
        drive(sim, RoverInput(drive: 1), seconds: 8)
        var tipped = false
        var minUp = 1.0
        drive(sim, RoverInput(drive: 1, steer: 1), seconds: 4) { s in
            tipped = tipped || (s.snapshot.rover?.tipped ?? false)
            if let i = roverIndex(s) {
                let v = s.vessels[i]
                minUp = min(minUp, v.q.rotate(v.ship.roverBasis.rotate(.unitZ)).dot(v.r.normalized))
            }
        }
        let ri = try #require(roverIndex(sim))
        let v = sim.vessels[ri]
        print("Луна, резкий руль на скорости: опрокинут \(tipped), мин. cos верха \(minUp)")
        #expect(v.r.x.isFinite && v.v.x.isFinite && v.q.w.isFinite)
        let ground = Bodies.luna.radius + Terrain.surfaceHeight(body: .luna, direction: v.r.normalized)
        #expect(abs(v.r.length - ground) < 3)
    }

    @Test func upsideDownIsTippedAndStabilizerCannotRight() throws {
        let sim = landed()
        try deployAndBoard(sim)
        let ri = try #require(roverIndex(sim))
        // Перевернуть вокруг продольной оси и приподнять на 1 м.
        let v = sim.vessels[ri]
        let fwd = v.q.rotate(v.ship.roverBasis.rotate(.unitY))
        sim.vessels[ri].fixedPos = nil
        sim.vessels[ri].fixedAtt = nil
        sim.vessels[ri].q = (Quat(axis: fwd, angle: .pi) * v.q).normalized
        sim.vessels[ri].r = v.r + v.r.normalized * 1.0
        sim.send(.setRoverStabilizer(true))
        drive(sim, RoverInput(drive: 1), seconds: 6)
        let r = try #require(sim.snapshot.rover)
        #expect(r.tipped && r.stabilizer)
        #expect(r.wheelsOnGround == 0)
        let w = sim.vessels[ri]
        let ground = Bodies.luna.radius + Terrain.surfaceHeight(body: .luna, direction: w.r.normalized)
        #expect(w.r.length > ground - 1.5, "провалился")
    }

    @Test func standUpPutsCosmonautBesideSeat() throws {
        let sim = landed()
        try deployAndBoard(sim)
        drive(sim, RoverInput(drive: 1), seconds: 2)
        sim.send(.setHandbrake(true))
        drive(sim, .neutral, seconds: 3)
        let roverID = try #require(sim.snapshot.activeVessel)
        #expect(sim.snapshot.evaExitBlocker == nil)
        sim.send(.evaExit)
        _ = sim.advance(realDelta: 1.0 / 60)
        let c = try #require(sim.snapshot.controlled)
        #expect(c.onGround && c.grip == nil)
        #expect(sim.snapshot.activeVessel == roverID)
        #expect(sim.snapshot.rover?.driverID == nil && sim.snapshot.rover?.canDrive == false)
        #expect(c.hatchIsSeat && c.canBoard)
        let d = try #require(c.hatchDistance)
        #expect(d > 1 && d < 2, "\(d)")
        let ground = Bodies.luna.radius + Terrain.surfaceHeight(body: .luna, direction: c.position.normalized)
        #expect(abs(c.position.length - ground) < 1e-6)
    }

    @Test func selectVesselSwitchesShipAndRover() throws {
        let sim = landed(Self.lander2)
        try deployAndBoard(sim)
        let roverID = try #require(sim.snapshot.activeVessel)
        let ri = try #require(roverIndex(sim))
        let landerID = try #require(sim.vessels.first { $0.rover == nil }?.id)
        drive(sim, RoverInput(drive: 1), seconds: 2)
        #expect(sim.vessels[ri].fixedPos == nil)
        #expect(Set(sim.snapshot.controllable.map(\.id)) == [roverID, landerID])
        sim.send(.selectVessel(landerID))
        #expect(sim.snapshot.activeVessel == landerID && sim.snapshot.rover == nil)
        // Ушли с ровера — он закреплён на грунте.
        let rj = try #require(sim.vessels.firstIndex { $0.id == roverID })
        #expect(sim.vessels[rj].fixedPos != nil)
        let p = sim.vessels[rj].r
        _ = sim.advance(realDelta: 2)
        #expect((sim.vessels[rj].r - p).length < 1e-9)
        sim.send(.selectVessel(roverID))
        #expect(sim.snapshot.activeVessel == roverID && sim.snapshot.rover?.canDrive == true)
    }

    @Test func checkpointRestoresRover() throws {
        let sim = landed()
        try deployAndBoard(sim)
        sim.send(.setRoverStabilizer(true))
        drive(sim, RoverInput(drive: 1, steer: 0.3), seconds: 3)
        let cp = sim.checkpoint()
        let before = try roverState(sim)
        let status = try #require(sim.snapshot.rover)
        drive(sim, RoverInput(drive: -1), seconds: 3)
        sim.restore(cp)
        let after = try roverState(sim)
        #expect(after.position == before.position && after.wheels == before.wheels)
        #expect(sim.snapshot.rover == status)
        // Продолжение после отката совпадает.
        drive(sim, RoverInput(drive: 1), seconds: 1)
        let a = try roverState(sim).position
        sim.restore(cp)
        drive(sim, RoverInput(drive: 1), seconds: 1)
        #expect(try roverState(sim).position == a)
    }

    // MARK: Терра

    /// Вращающаяся Терра: ровер стоит неподвижно в системе тела и едет относительно грунта.
    @Test func drivesOnRotatingTerra() throws {
        let sim = FlightSim(design: .lunaRover)
        #expect(sim.snapshot.roverDeployable)
        sim.send(.deployRover)
        _ = sim.advance(realDelta: 1.0 / 60)
        let ri = try #require(roverIndex(sim))
        let fixed0 = World.toBodyFixed(sim.vessels[ri].r, body: .terra, time: sim.time)
        _ = sim.advance(realDelta: 5)
        let fixed1 = World.toBodyFixed(sim.vessels[ri].r, body: .terra, time: sim.time)
        #expect((fixed1 - fixed0).length < 1e-6)
        #expect(try roverState(sim).wheels.allSatisfy(\.onGround))
        // Посадить Леру в кресло напрямую.
        let li = sim.activeIndex
        let pod = try #require(sim.vessels[li].ship.parts.firstIndex { !$0.crew.isEmpty })
        sim.vessels[li].ship.parts[pod].crew = []
        let seat = try #require(sim.vessels[ri].ship.parts.firstIndex { $0.spec.kind == .seat })
        sim.vessels[ri].ship.parts[seat].crew = ["lera"]
        sim.send(.selectVessel(sim.vessels[ri].id))
        #expect(sim.snapshot.rover?.canDrive == true)
        var tipped = false
        drive(sim, RoverInput(drive: 1), seconds: 6) { s in tipped = tipped || (s.snapshot.rover?.tipped ?? true) }
        let r = try #require(sim.snapshot.rover)
        print("Терра, газ 6 с: скорость \(r.speed) м/с, колёс на грунте \(r.wheelsOnGround)")
        #expect(r.speed > 3 && r.speed <= RoverBalance.maxSpeed)
        #expect(!tipped && r.wheelsOnGround >= 3)
        sim.send(.setHandbrake(true))
        drive(sim, .neutral, seconds: 4)
        let rj = try #require(roverIndex(sim))
        #expect(sim.vessels[rj].fixedPos != nil)
        let a = World.toBodyFixed(sim.vessels[rj].r, body: .terra, time: sim.time)
        _ = sim.advance(realDelta: 3)
        let b = World.toBodyFixed(sim.vessels[rj].r, body: .terra, time: sim.time)
        #expect((b - a).length < 1e-6)
    }

    // MARK: Ревью F

    /// Механическая энергия ровера относительно грунта (поступательная, вращательная, потенциальная).
    func roverEnergy(_ sim: FlightSim, _ ri: Int) -> Double {
        let v = sim.vessels[ri]
        let geo = RoverGeometry(v.ship)
        let qr = (v.q * geo.basis).normalized
        let x = v.r + v.q.rotate(geo.cm)
        let spin = World.spin(v.body)
        let vRel = v.v - spin.cross(x)
        let wl = qr.conjugate.rotate(v.w - spin)
        let mu = Bodies.body(v.body).mu
        return geo.mass * (0.5 * vRel.lengthSquared - mu / x.length)
            + 0.5 * (geo.inertia.x * wl.x * wl.x + geo.inertia.y * wl.y * wl.y + geo.inertia.z * wl.z * wl.z)
    }

    /// Перевернуть активный ровер (`axis` в осях ровера, на угол π) и уронить с 1 м: энергия не растёт, через 5 с покой.
    func dropFlipped(_ sim: FlightSim, axis: Vec3, label: String, minHull: Int = 1) throws {
        let ri = try #require(roverIndex(sim))
        let v = sim.vessels[ri]
        let ax = v.q.rotate(v.ship.roverBasis.rotate(axis))
        sim.vessels[ri].fixedPos = nil
        sim.vessels[ri].fixedAtt = nil
        sim.vessels[ri].q = (Quat(axis: ax, angle: .pi) * v.q).normalized
        sim.vessels[ri].r = v.r + v.r.normalized * 1.0
        sim.vessels[ri].v = World.surfaceVelocity(body: v.body, position: sim.vessels[ri].r)
        sim.vessels[ri].w = World.spin(v.body)
        sim.vessels[ri].rover?.restTime = 0
        let e0 = roverEnergy(sim, ri)
        var eMax = e0
        var hull = 0
        drive(sim, .neutral, seconds: 5) { s in
            guard let i = roverIndex(s), s.vessels[i].fixedPos == nil else { return }
            let e = roverEnergy(s, i)
            eMax = max(eMax, e)
            let v = s.vessels[i]
            let geo = RoverGeometry(v.ship)
            let qr = (v.q * geo.basis).normalized
            let x = v.r + v.q.rotate(geo.cm)
            hull = max(hull, geo.hull.filter { p in
                let pt = x + qr.rotate(p)
                return s.surfacePoint(body: v.body, near: pt, time: s.time).length > pt.length
            }.count)
        }
        let rj = try #require(roverIndex(sim))
        let w = sim.vessels[rj]
        let m = RoverGeometry(w.ship).mass
        let speed = (w.v - World.spin(w.body).cross(w.r)).length
        print("\(label): рост энергии \((eMax - e0) / m) Дж/кг, "
              + "точек корпуса в грунте до \(hull), скорость через 5 с \(speed) м/с, закреплён \(w.fixedPos != nil)")
        #expect(hull >= minHull, "точек корпуса в грунте: \(hull)")
        #expect(eMax - e0 < 0.05 * m, "энергия выросла: \((eMax - e0) / m) Дж/кг")
        #expect(w.fixedPos != nil || speed < 0.05)
        let ground = Bodies.body(w.body).radius + Terrain.surfaceHeight(body: w.body, direction: w.r.normalized)
        #expect(w.r.length > ground - 1.5, "провалился")
    }

    /// Ровер с тремя одинаковыми батареями вместо кресла и панели: перевёрнутый ложится на 12 точек корпуса сразу.
    static func flatTop(_ d: VesselDesign) -> VesselDesign {
        var d = d
        for i in d.nodes.indices where d.nodes[i].part == .roverSeat || d.nodes[i].part == .solarS1 {
            d.nodes[i].part = .batteryB1
        }
        return d
    }

    /// Отделить ровер и сделать его активным (без водителя).
    func deployActive(_ sim: FlightSim) throws {
        sim.send(.deployRover)
        _ = sim.advance(realDelta: 1.0 / 60)
        sim.makeActive(try #require(roverIndex(sim)))
        _ = sim.advance(realDelta: 1.0 / 60)
    }

    @Test func flippedRoverDropSettlesOnLuna() throws {
        for (axis, label) in [(Vec3.unitY, "Луна, вверх колёсами"), (Vec3.unitX, "Луна, на нос")] {
            let sim = landed()
            try deployAndBoard(sim)
            try dropFlipped(sim, axis: axis, label: label)
        }
        let sim = landed(Self.flatTop(Self.lander))
        try deployActive(sim)
        try dropFlipped(sim, axis: .unitY, label: "Луна, плашмя на батареи", minHull: 10)
    }

    @Test func flippedRoverDropSettlesOnTerra() throws {
        let sim = FlightSim(design: Self.flatTop(.lunaRover))
        try deployActive(sim)
        try dropFlipped(sim, axis: .unitY, label: "Терра, плашмя на батареи", minHull: 10)
    }

    @Test func standUpAtSpeedSetsHandbrake() throws {
        let sim = landed()
        try deployAndBoard(sim)
        drive(sim, RoverInput(drive: 1), seconds: 5)
        #expect((sim.snapshot.rover?.speed ?? 0) > 2)
        sim.send(.evaExit)
        _ = sim.advance(realDelta: 1.0 / 60)
        #expect(sim.snapshot.controlled != nil)
        let ri = try #require(roverIndex(sim))
        #expect(sim.vessels[ri].rover?.handbrake == true)
        let p = sim.vessels[ri].r
        _ = sim.advance(realDelta: 10)
        let moved = (sim.vessels[ri].r - p).length
        print("Встал на ходу: ровер прокатился \(moved) м")
        #expect(moved < 15)
    }

    @Test func customStagingRoverMountHasNoStage() {
        var d = VesselDesign(name: "т", parts: [.probe, .t400])
        let tank = AttachTarget(parent: 1, node: .radial, angle: 0, height: 0.5, position: .zero)
        let dec = try! #require(VesselEditing.attach(.decouplerRadial, to: tank, symmetry: 1, in: &d).first)
        // Ручная ступень разделителю, пока он обычный.
        VesselEditing.setStage(dec, to: 0, in: &d)
        #expect(d.customStaging && d.node(dec)?.stage != nil)
        let side = AttachTarget(parent: dec, node: .radial, angle: 0, height: 0.5, position: .zero)
        #expect(!VesselEditing.attach(.roverFrame, to: side, symmetry: 1, in: &d).isEmpty)
        #expect(d.node(dec)?.stage == nil)
        // И правка ступеней ему ступень не вернёт.
        VesselEditing.setStage(dec, to: 0, in: &d)
        #expect(d.node(dec)?.stage == nil)
    }

    @Test func throttleOnParkedRoverBlocksRails() throws {
        let sim = landed()
        try deployAndBoard(sim)
        sim.send(.setHandbrake(true))
        drive(sim, .neutral, seconds: 4)
        let ri = try #require(roverIndex(sim))
        #expect(sim.vessels[ri].fixedPos != nil && sim.railsBlockReason() == nil)
        sim.send(.setHandbrake(false))
        sim.setRoverInput(RoverInput(drive: 1))
        #expect(sim.railsBlockReason() == .thrust)
    }
}
