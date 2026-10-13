import Foundation
import Testing
@testable import OrbitPhysics

// Этап 5.2: дерево деталей, раскладка, ступени активации, физика по дереву.

/// Боковая точка крепления к детали `parent`.
private func radial(_ parent: Int, _ angle: Double, height: Double = 0.5) -> AttachTarget {
    AttachTarget(parent: parent, node: .radial, angle: angle, height: height, position: .zero)
}

private func axial(_ parent: Int, _ node: AttachNode) -> AttachTarget {
    AttachTarget(parent: parent, node: node, position: .zero)
}

/// Линейный стек `parts` (корень — первая) и id новых деталей.
private func stack(_ parts: [PartID]) -> VesselDesign { VesselDesign(name: "t", parts: parts) }

/// Положение корня в мировых координатах (проверка «корабль не прыгает»).
private func rootWorld(_ v: VesselState) -> Vec3 { v.position + v.attitude.rotate(v.layout[0].center) }

/// Нос корабля в осях начальной ориентации `q0`.
private func noseIn(_ q0: Quat, _ sim: FlightSim) -> Vec3 {
    q0.conjugate.rotate(sim.snapshot.vessels.first { $0.isActive }!.attitude.nose)
}

/// Корабль в вакууме на круговой орбите 200 км, SAS выкл.
private func inOrbit(_ design: VesselDesign) -> (FlightSim, Quat) {
    let s = circularOrbit(altitude: 200_000)
    let sim = FlightSim(design: design, body: .terra, position: s.position, velocity: s.velocity)
    sim.send(.setSAS(.off))
    return (sim, sim.snapshot.vessels[0].attitude)
}

@Suite("Дерево деталей: правки")
struct DesignEditingTests {
    @Test func buildAttachInsertAndOrder() {
        var d = VesselDesign(name: "t", nodes: [])
        let first = VesselEditing.attachTargets(for: .podK1, symmetry: 1, in: d)
        #expect(first.count == 1 && first[0].parent == nil)
        let pod = VesselEditing.attach(.podK1, to: first[0], symmetry: 1, in: &d)
        #expect(pod == [0])
        let tank = VesselEditing.attach(.t400, to: axial(0, .bottom), symmetry: 1, in: &d)[0]
        let eng = VesselEditing.attach(.vikhr, to: axial(tank, .bottom), symmetry: 1, in: &d)[0]
        let chute = VesselEditing.attach(.chute, to: axial(0, .top), symmetry: 1, in: &d)[0]
        // Обход в глубину: верхний узел раньше нижнего.
        #expect(d.parts == [.podK1, .chute, .t400, .vikhr])
        // Вставка между: Т-200 на занятый нижний узел капсулы, Т-400 переходит под него.
        let mid = VesselEditing.attach(.t200, to: axial(0, .bottom), symmetry: 1, in: &d)[0]
        #expect(d.parts == [.podK1, .chute, .t200, .t400, .vikhr])
        #expect(d.node(tank)?.parent == mid && d.node(mid)?.parent == 0)
        // Раскладка: нижняя точка — 0, детали вплотную по оси.
        let lay = d.layout()
        #expect(abs(lay.map(\.bottom).min()! ) < 1e-12)
        let i = d.index(of: eng)!, c = d.index(of: chute)!
        #expect(abs(lay[i].bottom) < 1e-12)
        let total = d.parts.reduce(0) { $0 + $1.spec.height }
        #expect(abs(lay[c].top - total) < 1e-9)
        #expect(lay.allSatisfy { $0.center.x == 0 && $0.center.z == 0 })
        // Нельзя: стабилизатор по оси, двигатель к стабилизатору, к несуществующей детали.
        #expect(!VesselEditing.canAttach(.fin, to: axial(0, .bottom), in: d))
        #expect(VesselEditing.attach(.fin, to: axial(0, .bottom), symmetry: 1, in: &d).isEmpty)
        #expect(!VesselEditing.canAttach(.t100, to: axial(99, .bottom), in: d))
    }

    @Test func radialSymmetryAndLayout() {
        var d = stack([.probe, .t800, .vikhr])
        // ×3 боковые разделители, к каждому — «Молот» (по копиям родителя).
        let decs = VesselEditing.attach(.decouplerRadial, to: radial(1, 0), symmetry: 3, in: &d)
        #expect(decs.count == 3)
        #expect(decs.compactMap { d.node($0)?.angle }.sorted() == [0, 120, 240])
        #expect(Set(decs.compactMap { d.node($0)?.symmetryGroup }).count == 1)
        let boosters = VesselEditing.attach(.molot, to: radial(decs[0], 0), symmetry: 1, in: &d)
        #expect(boosters.count == 3)
        let lay = d.layout()
        let tank = lay[d.index(of: 1)!]
        for id in boosters {
            let p = lay[d.index(of: id)!]
            let r = (p.center.x * p.center.x + p.center.z * p.center.z).squareRoot()
            #expect(abs(r - (0.625 + 0.25 + 0.625)) < 1e-9)
            #expect(abs(p.outward.length - 1) < 1e-12)
            #expect(abs(p.center.y - (tank.bottom + 0.5 * tank.height)) < 1e-9)
        }
        #expect(abs(lay.map { $0.bottom }.min()!) < 1e-12)
        // ×2 и ×4 стабилизаторы; ×4 на 45° — 45, 135, 225, 315.
        let fins = VesselEditing.attach(.fin, to: radial(1, 45, height: 0.1), symmetry: 4, in: &d)
        #expect(fins.compactMap { d.node($0)?.angle }.sorted() == [45, 135, 225, 315])
        var e = stack([.probe, .t400])
        let two = VesselEditing.attach(.t100, to: radial(1, 90), symmetry: 2, in: &e)
        #expect(two.compactMap { e.node($0)?.angle }.sorted() == [90, 270])
        // Точки крепления ×4 рядом с занятыми 0/90/180/270 — только азимуты, где помещаются все копии.
        var f = stack([.probe, .t800])
        VesselEditing.attach(.fin, to: radial(1, 0), symmetry: 4, in: &f)
        let targets = VesselEditing.attachTargets(for: .fin, symmetry: 4, in: f).filter { $0.parent == 1 && $0.node == .radial }
        #expect(Set(targets.map(\.angle)) == [45, 135, 225, 315])
        // Удаление копии убирает всю группу.
        let removed = VesselEditing.remove(boosters[1], in: &d)
        #expect(Set(removed) == Set(boosters))
        #expect(!d.parts.contains(.molot))
    }

    @Test func mirrorAttach() {
        var d = stack([.probe, .t800])
        let pair = VesselEditing.attach(.shtil, to: radial(1, 30), symmetry: 2, mirror: true, in: &d)
        #expect(pair.count == 2)
        #expect(d.node(pair[0])?.angle == 30 && d.node(pair[1])?.angle == 150)
        #expect(d.node(pair[0])?.mirrored == false && d.node(pair[1])?.mirrored == true)
    }

    @Test func removeMoveAndLimit() {
        var d = stack([.chute, .podK1, .t200, .t400, .vikhr])
        // Середина стека: продолжение (Т-400 с двигателем) переходит к капсуле.
        let r = VesselEditing.remove(2, in: &d)
        #expect(r == [2])
        #expect(d.parts == [.chute, .podK1, .t400, .vikhr])
        #expect(d.node(3)?.parent == 1 && d.node(3)?.node == .bottom)
        // Корень с одним осевым ребёнком — тот становится корнем.
        VesselEditing.remove(0, in: &d)
        #expect(d.root?.part == .podK1 && d.parts == [.podK1, .t400, .vikhr])
        // Перенос: «Вихрь» на верх капсулы; к себе/потомку — нельзя.
        #expect(VesselEditing.move(4, to: axial(1, .top), in: &d))
        #expect(d.parts == [.podK1, .vikhr, .t400])
        #expect(!VesselEditing.move(1, to: axial(3, .bottom), in: &d))
        #expect(!VesselEditing.move(3, to: axial(3, .bottom), in: &d))
        // Лимит деталей с учётом копий.
        var big = stack([.probe] + Array(repeating: .t100, count: VesselDesign.maxParts - 2))
        #expect(VesselEditing.attach(.fin, to: radial(1, 0), symmetry: 2, in: &big).isEmpty)
        #expect(VesselEditing.attach(.fin, to: radial(1, 0), symmetry: 1, in: &big).count == 1)
        #expect(VesselEditing.attachTargets(for: .t100, symmetry: 1, in: big).isEmpty)
        #expect(VesselDesign.maxParts == 60)
    }

    @Test func setRootKeepsLayout() {
        var d = VesselDesign.orbit
        let before = Dictionary(uniqueKeysWithValues: zip(d.nodes.map(\.id), d.layout().map(\.center)))
        #expect(VesselEditing.setRoot(1, in: &d))
        #expect(d.root?.part == .podK1)
        #expect(d.node(0)?.parent == 1 && d.node(0)?.node == .top)
        let after = Dictionary(uniqueKeysWithValues: zip(d.nodes.map(\.id), d.layout().map(\.center)))
        for (id, c) in before { #expect((after[id]! - c).length < 1e-9) }
        // Боковое ребро на пути — нельзя.
        var b = VesselDesign.boosters
        #expect(!VesselEditing.setRoot(12, in: &b))
        #expect(b == VesselDesign.boosters)
    }

    @Test func setOffsetIsClamped() {
        var d = VesselDesign.boosters
        // Стабилизатор 12 на Т-800 (h 3.6, D 1.25): по оси ≤ 1.8, вбок ≤ 0.625.
        VesselEditing.setOffset(12, Vec3(5, 10, 0), in: &d)
        let o = d.node(12)!.offset
        #expect(abs(o.y - 1.8) < 1e-12)
        #expect(abs((o.x * o.x + o.z * o.z).squareRoot() - 0.625) < 1e-12)
        // Копия на 135° — сдвиг повёрнут на 90°.
        let o2 = d.node(13)!.offset
        #expect(abs(o2.y - 1.8) < 1e-12 && abs(o2.x) < 1e-12 && abs(o2.z - 0.625) < 1e-12)
        // Сдвиг виден в раскладке.
        let before = VesselDesign.boosters.layout()[VesselDesign.boosters.index(of: 12)!].center
        let after = d.layout()[d.index(of: 12)!].center
        #expect(abs((after - before).y - 1.8) < 1e-9)
    }

    @Test func stagingEditor() {
        var d = VesselDesign.orbit
        #expect(d.stageGroups.count == 4)
        // «Штиль» (id 4) — в новую первую ступень.
        VesselEditing.setStage(4, to: -1, in: &d)
        #expect(d.customStaging && d.stageGroups.count == 5 && d.stageGroups[0] == [4])
        VesselEditing.swapStages(0, 1, in: &d)
        #expect(d.stageGroups[1] == [4])
        // Перенос в существующую ступень схлопывает пустую.
        VesselEditing.setStage(4, to: 3, in: &d)
        #expect(d.stageGroups.count == 4)
        VesselEditing.resetStaging(in: &d)
        #expect(d == VesselDesign.orbit)
        // Новая деталь при ручных ступенях получает ступень по авто-правилу.
        var c = VesselDesign.orbit
        VesselEditing.swapStages(2, 3, in: &c)
        let id = VesselEditing.attach(.shtil, to: radial(7, 0), symmetry: 1, in: &c)[0]
        #expect(c.customStaging && c.node(id)?.stage != nil)
    }
}

@Suite("Дерево деталей: ступени и сохранение")
struct DesignStagingTests {
    func kinds(_ d: VesselDesign) -> [[String]] {
        d.stageGroups.map { g in g.compactMap { d.node($0)?.part.rawValue }.sorted() }
    }

    @Test func linearAutoStagingMatchesOldSequence() {
        #expect(kinds(.jump) == [["molot"], ["decoupler"], ["chute"]])
        #expect(kinds(.orbit) == [["vikhr"], ["decoupler", "shtil"], ["decoupler"], ["chute"]])
        #expect(kinds(.luna) == [["titan"], ["decouplerXL", "vikhr"], ["decoupler", "shtil"], ["chute"]])
        #expect(kinds(.boosters) == [["molot", "molot", "vikhr"], ["decouplerRadial", "decouplerRadial", "fairing", "fairing"],
                                     ["decoupler"], ["chute"]])
        for d in VesselDesign.presets { #expect(d.stageInfos().count == d.stageGroups.count) }
        #expect(VesselDesign.orbit.stageInfos()[1].parts.sorted { $0.rawValue < $1.rawValue } == [.decoupler, .shtil])
    }

    @Test func oldHangarFormatAndRoundTrip() throws {
        let old = #"{"name":"Орбита","parts":["chute","podK1","decoupler","t400","shtil","decoupler","t800","t800","vikhr"]}"#
        let decoded = try JSONDecoder().decode(VesselDesign.self, from: Data(old.utf8))
        #expect(decoded == VesselDesign.orbit)
        var custom = VesselDesign.boosters
        VesselEditing.setRotation(5, Vec3(3, 0, 0), in: &custom)
        VesselEditing.setStage(5, to: 1, in: &custom)
        let data = try JSONEncoder().encode(custom)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 2)
        #expect(try JSONDecoder().decode(VesselDesign.self, from: data) == custom)
        // v2 без полей поворота/сдвига/зеркала читается.
        var plain = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(VesselDesign.boosters)) as? [String: Any])
        plain["nodes"] = (plain["nodes"] as? [[String: Any]])?.map { n in
            n.filter { !["rotation", "offset", "mirrored"].contains($0.key) }
        }
        let stripped = try JSONSerialization.data(withJSONObject: plain)
        #expect(try JSONDecoder().decode(VesselDesign.self, from: stripped) == VesselDesign.boosters)
    }
}

@Suite("Дерево деталей: физика")
struct DesignTreePhysicsTests {
    /// Ядро без двигателя + один «Молот» на боковом разделителе (+X).
    func oneSided() -> VesselDesign {
        var d = stack([.probe, .t800])
        let dec = VesselEditing.attach(.decouplerRadial, to: radial(1, 0), symmetry: 1, in: &d)[0]
        VesselEditing.attach(.molot, to: radial(dec, 0), symmetry: 1, in: &d)
        return d
    }

    @Test func asymmetricThrustTurnsNoseAway() {
        let (sim, q0) = inOrbit(oneSided())
        sim.send(.stage)
        run(sim, limit: 0.5)
        // Двигатель на +X: нос уходит к −X.
        #expect(noseIn(q0, sim).x < -1e-3)
        #expect(oneSided().issues().contains(.asymmetricThrust(stage: 0)))
        #expect(oneSided().markers(stage: 0).thrustOffset > 0.5)
        // Симметричная пара — момента нет.
        var sym = stack([.probe, .t800])
        let decs = VesselEditing.attach(.decouplerRadial, to: radial(1, 0), symmetry: 2, in: &sym)
        VesselEditing.attach(.molot, to: radial(decs[0], 0), symmetry: 1, in: &sym)
        let (s2, _) = inOrbit(sym)
        s2.send(.stage)
        run(s2, limit: 0.5)
        #expect(s2.snapshot.vessels[0].angularVelocity.length < 1e-12)
        #expect(sym.markers(stage: 0).thrustOffset < 1e-9)
        #expect(!sym.issues().contains { if case .asymmetricThrust = $0 { return true }; return false })
        // Соосный стек: момент ровно ноль.
        var ship = Ship(design: .orbit)
        for i in ship.partsOfStage(0) { ship.parts[i].ignited = true }
        #expect(ship.burn(throttle: 1, pressure: 1, dt: 0.02).torque == .zero)
    }

    @Test func tiltedEngineTorqueSign() {
        var d = stack([.probe, .t400, .shtil])
        VesselEditing.setRotation(2, Vec3(10, 0, 0), in: &d)
        #expect(d.layout()[2].orientation != .identity)
        #expect(d.issues().contains(.asymmetricThrust(stage: 0)))
        var ship = Ship(design: d)
        ship.parts[2].ignited = true
        let tr = ship.burn(throttle: 1, pressure: 0, dt: 0.02)
        // Тяга наклонена к +Z из сопла ниже ЦМ: нос уходит к −Z (момент вокруг −X).
        #expect(tr.torque.x < 0)
        #expect((tr.force?.z ?? 0) > 0)
        let (sim, q0) = inOrbit(d)
        sim.send(.stage)
        sim.setInput(ControlInput(throttle: 1))
        run(sim, limit: 0.5)
        #expect(noseIn(q0, sim).z < -1e-3)
        // Симметричная пара повёрнутых (боковая ×2 и зеркальная) — ноль.
        var pair = stack([.probe, .t800])
        let e = VesselEditing.attach(.shtil, to: radial(1, 0), symmetry: 2, in: &pair)
        VesselEditing.setRotation(e[0], Vec3(10, 0, 5), in: &pair)
        #expect(pair.node(e[1])?.rotation == Vec3(10, 0, 5))
        #expect(pair.markers(stage: 0).thrustOffset < 1e-9)
        var mirror = stack([.probe, .t800])
        let m = VesselEditing.attach(.shtil, to: radial(1, 30), symmetry: 2, mirror: true, in: &mirror)
        VesselEditing.setRotation(m[0], Vec3(8, 4, 12), in: &mirror)
        #expect(mirror.node(m[1])?.rotation == Vec3(8, -4, -12))
        // Зеркальная пара (плоскость YZ): боковая сила по X, крен и рыскание взаимно гасятся.
        var ms = Ship(design: mirror)
        for i in ms.partsOfStage(0) { ms.parts[i].ignited = true }
        let mt = ms.burn(throttle: 1, pressure: 0, dt: 0.02)
        let tol = 1e-9 * mt.thrust
        #expect(abs(mt.force?.x ?? 1) < tol && abs(mt.torque.y) < tol && abs(mt.torque.z) < tol)
    }

    @Test func sideBlocksBurnOwnTanksAndSeparateCleanly() {
        var d = stack([.probe, .t800])
        let decs = VesselEditing.attach(.decouplerRadial, to: radial(1, 0), symmetry: 2, in: &d)
        let tanks = VesselEditing.attach(.t400, to: radial(decs[0], 0), symmetry: 1, in: &d)
        VesselEditing.attach(.shtil, to: axial(tanks[0], .bottom), symmetry: 1, in: &d)
        #expect(d.parts.filter { $0 == .shtil }.count == 2)
        let (sim, _) = inOrbit(d)
        sim.send(.stage)
        #expect(sim.snapshot.telemetry.nextStageAction == .separate)
        sim.setInput(ControlInput(throttle: 1))
        run(sim, limit: 5)
        let core = PartID.t800.spec.fuelMass
        // Ядро не тратит: масса = полная минус израсходованное боковыми.
        let ship = sim.vessels[0].ship
        #expect(ship.parts[ship.index(of: 1)!].fuel == core)
        for t in tanks { #expect(ship.parts[ship.index(of: t)!].fuel < PartID.t400.spec.fuelMass) }
        #expect(sim.snapshot.vessels[0].angularVelocity.length < 1e-9)
        let before = rootWorld(sim.snapshot.vessels[0])
        sim.send(.stage)
        let snap = sim.snapshot
        #expect(snap.vessels.count == 3 && snap.vessels.filter { !$0.isActive }.count == 2)
        let active = snap.vessels.first { $0.isActive }!
        #expect((rootWorld(active) - before).length < 1e-6)
        #expect(active.parts == [.probe, .t800] && active.layout.count == 2)
        #expect(abs(active.layout.map(\.bottom).min()!) < 1e-12)
        // Обломки — со своей раскладкой, на месте блоков.
        for v in snap.vessels where !v.isActive {
            #expect(v.parts == [.decouplerRadial, .t400, .shtil] && v.layout.count == 3)
            #expect(abs(v.layout.map(\.bottom).min()!) < 1e-12)
        }
    }

    @Test func boostersPresetAddsDeltaV() {
        let b = VesselDesign.boosters
        #expect(b.issues().isEmpty, "\(b.issues())")
        let core = stack([.chute, .podK1, .decoupler, .t800, .t800, .vikhr])
        let dvB = b.stageInfos().reduce(0) { $0 + $1.deltaV }
        let dvC = core.stageInfos().reduce(0) { $0 + $1.deltaV }
        #expect(dvB > dvC + 300, "\(dvB) vs \(dvC)")
        let s0 = b.stageInfos()[0]
        #expect(s0.twr > 1.2 && s0.hasSolid && s0.hasLiquidEngine)
        // [0] — пока горят «Молоты» (их топливо), затем ядро.
        #expect(abs(s0.fuelCapacity - 2 * PartID.molot.spec.fuelMass) < 1e-9)
        // Полёт: старт, отделение ускорителей и обтекателей — обломки, ракета не крутится.
        let sim = FlightSim(design: b)
        sim.send(.setSAS(.hold))
        sim.setInput(ControlInput(throttle: 1))
        sim.send(.stage)
        run(sim, limit: 20)
        #expect(sim.snapshot.telemetry.verticalSpeed > 50)
        #expect(abs(sim.snapshot.telemetry.pitch - .pi / 2) < 0.05)
        run(sim, limit: 30) { s, _ in !s.currentStageHasFuel || s.snapshot.telemetry.solidBurning == false }
        sim.send(.stage)
        #expect(sim.snapshot.vessels.filter { !$0.isActive }.count == 2)
        #expect(sim.snapshot.telemetry.stages.count == 3)
    }

    @Test func fairingReducesDrag() {
        let plain = Ship(design: stack([.probe, .t400, .vikhr]))
        let faired = Ship(design: stack([.fairing, .probe, .t400, .vikhr]))
        #expect(abs(faired.dragArea - plain.dragArea * 0.7) < 1e-12)
        // Сброс обтекателя ступенью — обломок, сопротивление — как без него.
        let sim = FlightSim(design: stack([.fairing, .probe, .t400, .vikhr]))
        #expect(sim.snapshot.telemetry.stages.count == 2)
        sim.send(.stage)
        #expect(sim.snapshot.telemetry.nextStageAction == .separate)
        sim.send(.stage)
        #expect(sim.vessels.count == 2)
        #expect(abs(sim.active.ship.dragArea - plain.dragArea) < 1e-12)
    }

    @Test func finsKeepNoseForward() {
        var finned = stack([.chute, .podK1])
        VesselEditing.attach(.fin, to: radial(1, 0, height: 0.1), symmetry: 4, in: &finned)
        #expect(Ship(design: stack([.chute, .podK1])).retroStable)
        #expect(!Ship(design: finned).retroStable)
        func fall(_ d: VesselDesign) -> Double {
            // 10 км, 300 м/с горизонтально, нос на 30° от набегающего потока.
            let up = Vec3(1, 0, 0) * (Bodies.terra.radius + 10_000)
            let vel = Vec3(0, 300, 0) + World.spin(.terra).cross(up)
            let nose = Vec3(sin(0.5), cos(0.5), 0)
            let sim = FlightSim(design: d, body: .terra, position: up, velocity: vel,
                                attitude: Quat.looking(nose: nose, zHint: .unitZ))
            sim.send(.setSAS(.off))
            run(sim, limit: 20)
            return sim.snapshot.telemetry.navball.surfacePrograde?.y ?? 0
        }
        #expect(fall(finned) > 0.9)
        #expect(fall(stack([.chute, .podK1])) < 0)
    }
}

@Suite("Дерево деталей: правки после ревью")
struct DesignReviewFixTests {
    @Test func noTargetOnNodeFacingParent() {
        // Т-400 висит на нижнем узле капсулы: его верхний узел занят капсулой.
        let d = stack([.podK1, .t400, .vikhr])
        #expect(!VesselEditing.canAttach(.t100, to: axial(1, .top), in: d))
        #expect(VesselEditing.canAttach(.t100, to: axial(1, .bottom), in: d))
        let targets = VesselEditing.attachTargets(for: .t100, symmetry: 1, in: d)
        #expect(!targets.contains { $0.parent == 1 && $0.node == .top })
        #expect(!targets.contains { $0.parent == 2 && $0.node == .top })
        // У корня свободны оба узла.
        #expect(targets.contains { $0.parent == 0 && $0.node == .top })
        #expect(targets.contains { $0.parent == 0 && $0.node == .bottom })
        // Деталь на верхнем узле — без нижнего.
        var up = stack([.podK1])
        let chute = VesselEditing.attach(.chute, to: axial(0, .top), symmetry: 1, in: &up)[0]
        #expect(!VesselEditing.canAttach(.t100, to: axial(chute, .bottom), in: up))
        #expect(VesselEditing.canAttach(.t100, to: axial(chute, .top), in: up))
        // Вставка между на нижний узел капсулы по-прежнему работает и не перекрывает детали.
        var e = d
        VesselEditing.attach(.t100, to: axial(0, .bottom), symmetry: 1, in: &e)
        let lay = e.layout()
        for k in 1..<lay.count { #expect(lay[k].top <= lay[k - 1].bottom + 1e-9) }
    }

    @Test func setRootRefusesAcrossDecouplers() {
        var d = VesselDesign.orbit
        // «Вихрь» (8) и Т-400 (3): на пути к парашюту — разделители.
        #expect(!VesselEditing.setRoot(8, in: &d))
        #expect(!VesselEditing.setRoot(3, in: &d))
        #expect(d == VesselDesign.orbit)
        // Капсула — можно, ступени те же.
        #expect(VesselEditing.setRoot(1, in: &d))
        #expect(d.stageGroups.map { $0.sorted() } == VesselDesign.orbit.stageGroups.map { $0.sorted() })
    }

    @Test func decouplerDroppingCommandIsFlagged() {
        // Корень сверху — бак: разделитель уносит капсулу.
        let i = stack([.t100, .decoupler, .chute, .podK1, .t200, .vikhr]).issues()
        #expect(i.contains(.decouplerDropsCommand))
        #expect(!DesignIssue.decouplerDropsCommand.isBlocking)
        #expect(DesignIssue.decouplerDropsCommand.text == "Разделитель отделяет капсулу или модуль управления")
        for p in VesselDesign.presets { #expect(!p.issues().contains(.decouplerDropsCommand)) }
    }

    @Test func moveClearsForeignSymmetryInSubtree() {
        var d = VesselDesign.boosters
        // Боковой разделитель 6 (с «Молотом» 8 и обтекателем 10) — на другой бак.
        #expect(VesselEditing.move(6, to: radial(3, 90), in: &d))
        for id in [6, 8, 10] { #expect(d.node(id)?.symmetryGroup == nil) }
        #expect(d.node(11)?.symmetryGroup == nil && d.node(9)?.symmetryGroup == nil)
        let removed = VesselEditing.remove(10, in: &d)
        #expect(removed == [10])
        #expect(d.node(11) != nil)
    }

    @Test func remainingAndMarkersOnEmptyStaging() {
        let d = stack([.probe, .t400])
        #expect(d.stageGroups.isEmpty)
        #expect(d.remainingIDs(afterStage: 0).count == 2)
        #expect(d.markers(stage: 0).centerOfThrust == nil)
    }

    @Test func lowestAccountsForRotation() {
        var d = stack([.probe, .t400, .shtil])
        VesselEditing.setRotation(2, Vec3(90, 0, 0), in: &d)
        let lay = d.layout()
        #expect(abs(lay.map(\.lowest).min()!) < 1e-9)
        // «Штиль» лёг набок: шире, чем высота, — низшая точка ниже `bottom` по оси детали.
        #expect(lay[2].lowest < lay[2].bottom - 0.05)
        #expect(lay[0].lowest == lay[0].bottom)
    }

    @Test func decodeNormalizesOrder() throws {
        // Ребёнок раньше родителя и сирота.
        let json = #"{"name":"x","version":2,"customStaging":false,"nodes":[{"id":1,"part":"vikhr","parent":0,"node":"bottom"},{"id":0,"part":"probe","node":"bottom"},{"id":5,"part":"t100","parent":42,"node":"bottom"}]}"#
        let d = try JSONDecoder().decode(VesselDesign.self, from: Data(json.utf8))
        #expect(d.nodes.map(\.id) == [0, 1])
        #expect(d.layout().count == 2)
    }
}
