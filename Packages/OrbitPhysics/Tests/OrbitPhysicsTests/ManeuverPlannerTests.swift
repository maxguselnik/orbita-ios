import Foundation
import Testing
@testable import OrbitPhysics

/// Состояние в перицентре эллипса/гиперболы с Пе `rp` и Ап `ra` (или скоростью на бесконечности `vinf`),
/// сдвинутое по орбите на `dt` секунд (отрицательное — до перицентра).
func conicState(body: CelestialBody, periapsisRadius rp: Double, apoapsisRadius ra: Double? = nil,
                vinf: Double = 0, phase: Double = 0, retrograde: Bool = false, dt: Double = 0) -> StateVector {
    let vp: Double
    if let ra { vp = (body.mu * (2 / rp - 2 / (rp + ra))).squareRoot() } else { vp = (vinf * vinf + 2 * body.mu / rp).squareRoot() }
    let c: Double = cos(phase), s: Double = sin(phase)
    let sign: Double = retrograde ? -1 : 1
    let r = Vec3(c, s, 0) * rp
    let v = Vec3(-s, c, 0) * (vp * sign)
    return Kepler.propagate(position: r, velocity: v, mu: body.mu, dt: dt)
}

@Suite("Манёвр по цели (простая карта)")
struct ManeuverPlannerTests {
    static let terra = Bodies.terra
    static let luna = Bodies.luna

    /// Орбита Терры 80×74 км, корабль в Пе (как сцена «Орбита» DemoScenario).
    static let terraOrbit = conicState(body: terra, periapsisRadius: terra.radius + 74_000, apoapsisRadius: terra.radius + 80_000)
    /// Суборбита: Ап 80 км, Пе под землёй, за 200 с до Ап.
    static let suborbit: StateVector = {
        let ra = terra.radius + 80_000, rp = terra.radius - 300_000
        let va = (terra.mu * (2 / ra - 2 / (rp + ra))).squareRoot()
        return Kepler.propagate(position: Vec3(ra, 0, 0), velocity: Vec3(0, va, 0), mu: terra.mu, dt: -200)
    }()
    /// Подлёт к Луне по гиперболе: v∞ 300 м/с, Пе 30 км, за час до Пе.
    static let lunaFlyby = conicState(body: luna, periapsisRadius: luna.radius + 30_000, vinf: 300, dt: -3_600)

    /// Прогноз после узла, как у карты.
    static func after(_ node: ManeuverNode, body: BodyID, state: StateVector, time: Double) throws -> Trajectory {
        let p = try #require(TrajectoryPredictor.predict(node: node, body: body, state: state, time: time,
                                                         mass: 1, thrust: 0, isp: 1,
                                                         maxPatches: TrajectoryPredictor.defaultMapPatches))
        return p.trajectory
    }

    // MARK: Доступные цели

    @Test func goalsOnTerraOrbit() {
        #expect(ManeuverPlanner.availableGoals(body: .terra, state: Self.terraOrbit, time: 0) == [.toLuna, .changeOrbit] + ManeuverGoal.planetGoals)
        // Эллипс: появляется «круговая».
        let ell = conicState(body: Self.terra, periapsisRadius: Self.terra.radius + 80_000, apoapsisRadius: Self.terra.radius + 400_000)
        #expect(ManeuverPlanner.availableGoals(body: .terra, state: ell, time: 0) == [.toLuna, .circularize, .changeOrbit] + ManeuverGoal.planetGoals)
        // Ап дальше половины пути до Луны — без «К Луне».
        let high = conicState(body: Self.terra, periapsisRadius: Self.terra.radius + 80_000, apoapsisRadius: 7_000_000)
        #expect(ManeuverPlanner.availableGoals(body: .terra, state: high, time: 0) == [.circularize, .changeOrbit] + ManeuverGoal.planetGoals)
    }

    @Test func goalsOnSuborbitAndGround() {
        #expect(ManeuverPlanner.availableGoals(body: .terra, state: Self.suborbit, time: 0) == [.circularize])
        // Ап уже позади — пусто.
        let falling = StateVector(position: Self.suborbit.position, velocity: Self.suborbit.velocity * -1)
        #expect(ManeuverPlanner.availableGoals(body: .terra, state: falling, time: 0).isEmpty)
        // Ап в атмосфере — пусто.
        let low = StateVector(position: Vec3(Self.terra.radius + 30_000, 0, 0), velocity: Vec3(300, 1_500, 0))
        #expect(ManeuverPlanner.availableGoals(body: .terra, state: low, time: 0).isEmpty)
        // На площадке (скорость поверхности) — пусто.
        let pad = Vec3(Self.terra.radius + Terrain.padHeight, 0, 0)
        let ground = StateVector(position: pad, velocity: World.surfaceVelocity(body: .terra, position: pad))
        #expect(ManeuverPlanner.availableGoals(body: .terra, state: ground, time: 0).isEmpty)
        // Грунт Луны.
        let lpad = Vec3(Self.luna.radius + 2_000, 0, 0)
        #expect(ManeuverPlanner.availableGoals(body: .luna, state: StateVector(position: lpad, velocity: .zero), time: 0).isEmpty)
    }

    @Test func goalsAtLuna() {
        #expect(ManeuverPlanner.availableGoals(body: .luna, state: Self.lunaFlyby, time: 0) == [.circularize])
        // После Пе пролёта — пусто.
        let leaving = conicState(body: Self.luna, periapsisRadius: Self.luna.radius + 30_000, vinf: 300, dt: 600)
        #expect(ManeuverPlanner.availableGoals(body: .luna, state: leaving, time: 0).isEmpty)
        // Пролёт в грунт — пусто.
        let crash = conicState(body: Self.luna, periapsisRadius: Self.luna.radius + 2_000, vinf: 300, dt: -3_600)
        #expect(ManeuverPlanner.availableGoals(body: .luna, state: crash, time: 0).isEmpty)
        let circ = circularOrbit(altitude: 30_000, body: Self.luna)
        #expect(ManeuverPlanner.availableGoals(body: .luna, state: circ, time: 0) == [.returnHome, .changeOrbit])
        let ell = conicState(body: Self.luna, periapsisRadius: Self.luna.radius + 30_000, apoapsisRadius: Self.luna.radius + 300_000)
        #expect(ManeuverPlanner.availableGoals(body: .luna, state: ell, time: 0) == [.returnHome, .circularize, .changeOrbit])
    }

    @Test func fineSteps() {
        #expect(ManeuverPlanner.fineStep(.toLuna) == 0.1)
        #expect(ManeuverPlanner.fineStep(.returnHome) == 0.1)
        #expect(ManeuverPlanner.fineStep(.circularize) == 1)
        #expect(ManeuverPlanner.fineStep(.changeOrbit) == 1)
        #expect(ManeuverPlanner.fineStep(nil) == 1)
    }

    // MARK: Круговая

    @Test func circularizeTerraOrbitAtApoapsis() throws {
        let time = 1_000.0
        let node = try #require(ManeuverPlanner.plan(.circularize, body: .terra, state: Self.terraOrbit, time: time))
        let el = OrbitElements(position: Self.terraOrbit.position, velocity: Self.terraOrbit.velocity, mu: Self.terra.mu)
        // Корабль в Пе — ближайший апсис через 30+ с: Ап, прогрейд.
        #expect(abs(node.time - (time + el.period / 2)) < 1)
        #expect(node.prograde > 0 && node.radial == 0 && node.normal == 0)
        let traj = try Self.after(node, body: .terra, state: Self.terraOrbit, time: time)
        #expect(traj.patches[0].elements.eccentricity < 0.02)
        let out = ManeuverPlanner.outcome(.circularize, trajectory: traj)
        #expect(out.isGood)
        guard case .orbit(let body, let ap, let pe) = out.kind else { Issue.record("вид \(out.kind)"); return }
        #expect(body == .terra && abs(ap - 80_000) < 500 && abs(pe - 80_000) < 500)
    }

    @Test func circularizeSuborbit() throws {
        let node = try #require(ManeuverPlanner.plan(.circularize, body: .terra, state: Self.suborbit, time: 0))
        #expect(abs(node.time - 200) < 1)
        #expect(node.prograde > 300)
        let traj = try Self.after(node, body: .terra, state: Self.suborbit, time: 0)
        #expect(traj.patches[0].elements.eccentricity < 0.02)
        #expect(traj.impact == nil)
        #expect(ManeuverPlanner.outcome(.circularize, trajectory: traj).isGood)
        // Без узла — падение.
        let ballistic = TrajectoryPredictor.predict(body: .terra, state: Self.suborbit, time: 0)
        let out = ManeuverPlanner.outcome(.circularize, trajectory: ballistic)
        #expect(out == ManeuverOutcome(kind: .impact(.terra), isGood: false))
    }

    /// Ап ближе 30 с: узел через 30 с, точный вектор (с радиальной частью) — всё равно круговая.
    @Test func circularizeSuborbitNearApoapsis() throws {
        let s = Kepler.propagate(position: Self.suborbit.position, velocity: Self.suborbit.velocity, mu: Self.terra.mu, dt: 190)
        let node = try #require(ManeuverPlanner.plan(.circularize, body: .terra, state: s, time: 50))
        #expect(abs(node.time - 80) < 1e-9)
        #expect(node.radial != 0)
        let traj = try Self.after(node, body: .terra, state: s, time: 50)
        #expect(traj.patches[0].elements.eccentricity < 0.02)
    }

    @Test func circularizeLunaCapture() throws {
        let node = try #require(ManeuverPlanner.plan(.circularize, body: .luna, state: Self.lunaFlyby, time: 500))
        #expect(abs(node.time - 4_100) < 1)
        #expect(node.prograde < -100)
        let traj = try Self.after(node, body: .luna, state: Self.lunaFlyby, time: 500)
        let el = traj.patches[0].elements
        #expect(traj.patches[0].body == .luna && el.eccentricity < 0.02)
        let out = ManeuverPlanner.outcome(.circularize, trajectory: traj)
        #expect(out.isGood)
        guard case .orbit(.luna, let ap, let pe) = out.kind else { Issue.record("вид \(out.kind)"); return }
        #expect(abs(ap - 30_000) < 500 && abs(pe - 30_000) < 500)
        // Без узла: пролёт — Ап ∞, не круговая.
        let flyby = ManeuverPlanner.outcome(.circularize,
                                            trajectory: TrajectoryPredictor.predict(body: .luna, state: Self.lunaFlyby, time: 500))
        guard case .orbit(.luna, let fap, _) = flyby.kind else { Issue.record("вид \(flyby.kind)"); return }
        #expect(fap == .infinity && !flyby.isGood)
    }

    @Test func circularizeImpossible() {
        let falling = StateVector(position: Self.suborbit.position, velocity: Self.suborbit.velocity * -1)
        #expect(ManeuverPlanner.plan(.circularize, body: .terra, state: falling, time: 0) == nil)
        let leaving = conicState(body: Self.luna, periapsisRadius: Self.luna.radius + 30_000, vinf: 300, dt: 600)
        #expect(ManeuverPlanner.plan(.circularize, body: .luna, state: leaving, time: 0) == nil)
    }

    // MARK: Сменить орбиту

    @Test func changeOrbitAtPeriapsis() throws {
        let ell = conicState(body: Self.terra, periapsisRadius: Self.terra.radius + 80_000,
                             apoapsisRadius: Self.terra.radius + 400_000, dt: 600)
        let el = OrbitElements(position: ell.position, velocity: ell.velocity, mu: Self.terra.mu)
        let node = try #require(ManeuverPlanner.plan(.changeOrbit, body: .terra, state: ell, time: 100))
        #expect(abs(node.time - (100 + el.period - 600)) < 1)
        #expect(node.prograde == 20 && node.radial == 0 && node.normal == 0)
        let traj = try Self.after(node, body: .terra, state: ell, time: 100)
        let out = ManeuverPlanner.outcome(.changeOrbit, trajectory: traj)
        #expect(out.isGood)
        guard case .orbit(.terra, let ap, let pe) = out.kind else { Issue.record("вид \(out.kind)"); return }
        #expect(ap > 400_000 + 10_000 && abs(pe - 80_000) < 500)
        // В самом Пе — следующий оборот (не раньше чем через 30 с).
        let atPe = try #require(ManeuverPlanner.plan(.changeOrbit, body: .terra, state: Self.terraOrbit, time: 0))
        let pe0 = OrbitElements(position: Self.terraOrbit.position, velocity: Self.terraOrbit.velocity, mu: Self.terra.mu)
        #expect(atPe.time >= 30 && abs(atPe.time - pe0.period) < 1)
        // Незамкнутая — nil.
        #expect(ManeuverPlanner.plan(.changeOrbit, body: .luna, state: Self.lunaFlyby, time: 0) == nil)
    }

    @Test func changeOrbitOutcomeLowPeriapsis() throws {
        // Ретроград −200 м/с в Пе 80 км: Пе в атмосфере — не годно (без падения ниже уровня моря).
        let c = circularOrbit(altitude: 80_000)
        let node = ManeuverNode(time: 100, prograde: -200)
        let traj = try Self.after(node, body: .terra, state: c, time: 0)
        let out = ManeuverPlanner.outcome(.changeOrbit, trajectory: traj)
        #expect(!out.isGood)
        #expect(ManeuverPlanner.outcome(nil, trajectory: try Self.after(ManeuverNode(time: 100, prograde: 5),
                                                                       body: .terra, state: c, time: 0)).isGood)
    }

    // MARK: К Луне

    @Test func toLunaFromTerraOrbit() throws {
        let start = Date()
        let node = try #require(ManeuverPlanner.plan(.toLuna, body: .terra, state: Self.terraOrbit, time: 0))
        let elapsed = Date().timeIntervalSince(start)
        #expect(node.time >= 30)
        #expect(abs(node.prograde - TrajectoryPredictor.hohmannLunaDeltaV(radius: Self.terraOrbit.position.length)) < 15)
        let traj = try Self.after(node, body: .terra, state: Self.terraOrbit, time: 0)
        let out = ManeuverPlanner.outcome(.toLuna, trajectory: traj)
        #expect(out.isGood, "\(out.kind)")
        guard case .lunaPeriapsis(let pe) = out.kind else { Issue.record("вид \(out.kind)"); return }
        #expect((25_000...35_000).contains(pe))
        print("План «К Луне»: \(String(format: "%.3f", elapsed)) с, Пе \(Int(pe)) м")
        #expect(ManeuverPlanner.plan(.toLuna, body: .luna, state: circularOrbit(altitude: 30_000, body: Self.luna), time: 0) == nil)
    }

    @Test func toLunaOutcomes() throws {
        // Мал импульс — нет встречи.
        let c = circularOrbit(altitude: 80_000)
        let none = ManeuverPlanner.outcome(.toLuna, trajectory: try Self.after(ManeuverNode(time: 60, prograde: 100),
                                                                              body: .terra, state: c, time: 0))
        #expect(none == ManeuverOutcome(kind: .noEncounter(.luna), isGood: false))
        // Гоман без подбора с фазы 110° — в Луну.
        let r = Bodies.terra.radius + 78_000
        let s = circularOrbit(altitude: 78_000, phase: World.lunaInitialPhase - 110 * Double.pi / 180)
        let hit = ManeuverNode(time: 0, prograde: TrajectoryPredictor.hohmannLunaDeltaV(radius: r))
        let out = ManeuverPlanner.outcome(.toLuna, trajectory: try Self.after(hit, body: .terra, state: s, time: 0))
        #expect(out == ManeuverOutcome(kind: .impact(.luna), isGood: false))
        #expect(ManeuverPlanner.outcome(.toLuna, trajectory: Trajectory(patches: [])).isGood == false)
    }

    // MARK: Домой

    /// Орбиты Луны: круговая 30 км (разные фазы и моменты), эллипс, обратное направление.
    static let lunaOrbits: [(name: String, state: StateVector, time: Double)] = [
        ("круговая 30 км", circularOrbit(altitude: 30_000, body: luna), 0),
        ("круговая 30 км, фаза 90°", circularOrbit(altitude: 30_000, phase: .pi / 2, body: luna), 0),
        ("круговая 30 км, t = 50 000", circularOrbit(altitude: 30_000, phase: 2, body: luna), 50_000),
        ("круговая 100 км, t = 123 456", circularOrbit(altitude: 100_000, phase: 4, body: luna), 123_456),
        ("эллипс 30×300 км", conicState(body: luna, periapsisRadius: luna.radius + 30_000,
                                       apoapsisRadius: luna.radius + 300_000, phase: 1, dt: 900), 7_000),
        ("обратная 40 км", conicState(body: luna, periapsisRadius: luna.radius + 40_000,
                                      apoapsisRadius: luna.radius + 40_000, retrograde: true), 20_000),
        ("наклон 30°", tilted(circularOrbit(altitude: 50_000, phase: 3, body: luna), by: 30), 40_000),
        ("полярная", tilted(circularOrbit(altitude: 50_000, phase: 3, body: luna), by: 90), 40_000),
    ]

    /// Поворот плоскости орбиты вокруг оси X на `degrees`.
    static func tilted(_ s: StateVector, by degrees: Double) -> StateVector {
        let a = degrees * Double.pi / 180
        func rot(_ v: Vec3) -> Vec3 { Vec3(v.x, v.y * cos(a) - v.z * sin(a), v.y * sin(a) + v.z * cos(a)) }
        return StateVector(position: rot(s.position), velocity: rot(s.velocity))
    }

    @Test(arguments: 0..<lunaOrbits.count)
    func returnHomeFromLunaOrbit(index: Int) throws {
        let c = Self.lunaOrbits[index]
        let el = OrbitElements(position: c.state.position, velocity: c.state.velocity, mu: Self.luna.mu)
        let start = Date()
        let result = try #require(ManeuverPlanner.returnHome(body: .luna, state: c.state, time: c.time), "\(c.name)")
        let elapsed = Date().timeIntervalSince(start)
        let node = result.node
        #expect(node.time >= c.time + 30 && node.time <= c.time + 30 + el.period + 1)
        #expect(node.prograde > 0 && node.prograde < 1_000)
        #expect(result.predictions <= 60)
        #expect(elapsed < 0.5, "\(c.name): \(elapsed) с")
        let traj = try Self.after(node, body: .luna, state: c.state, time: c.time)
        let out = ManeuverPlanner.outcome(.returnHome, trajectory: traj)
        #expect(out.isGood, "\(c.name): \(out.kind)")
        guard case .terraPeriapsis(let pe) = out.kind else { Issue.record("вид \(out.kind)"); return }
        #expect(abs(pe - 35_000) < 5_000, "\(c.name): Пе \(pe)")
        // plan отдаёт тот же узел.
        #expect(ManeuverPlanner.plan(.returnHome, body: .luna, state: c.state, time: c.time) == node)
        print("План «Домой» (\(c.name)): Δv \(String(format: "%.1f", node.prograde)) м/с, Пе \(Int(pe)) м, "
              + "прогнозов \(result.predictions), \(String(format: "%.3f", elapsed)) с")
    }

    @Test func returnHomeImpossible() {
        // Не с Луны, не замкнутая, Пе в грунте.
        #expect(ManeuverPlanner.plan(.returnHome, body: .terra, state: Self.terraOrbit, time: 0) == nil)
        #expect(ManeuverPlanner.plan(.returnHome, body: .luna, state: Self.lunaFlyby, time: 0) == nil)
        let low = conicState(body: Self.luna, periapsisRadius: Self.luna.radius + 2_000, apoapsisRadius: Self.luna.radius + 50_000)
        #expect(ManeuverPlanner.plan(.returnHome, body: .luna, state: low, time: 0) == nil)
    }

    @Test func returnHomeOutcomes() throws {
        // Без узла: замкнутая у Луны — возврата нет.
        let circ = circularOrbit(altitude: 30_000, body: Self.luna)
        let stay = ManeuverPlanner.outcome(.returnHome, trajectory: TrajectoryPredictor.predict(body: .luna, state: circ, time: 0))
        #expect(stay == ManeuverOutcome(kind: .noEncounter(.terra), isGood: false))
        // Узел домой с Δv на 5 м/с меньше — Пе у Терры высоко: возврат есть, но не годен.
        let result = try #require(ManeuverPlanner.returnHome(body: .luna, state: circ, time: 0))
        var weak = result.node
        weak.prograde -= 5
        let out = ManeuverPlanner.outcome(.returnHome, trajectory: try Self.after(weak, body: .luna, state: circ, time: 0))
        guard case .terraPeriapsis(let pe) = out.kind else { Issue.record("вид \(out.kind)"); return }
        #expect(pe > 50_000 && !out.isGood)
    }
}

@Suite("Коррекция после неточного перелёта")
struct ManeuverCorrectionTests {
    static let terraOrbit = ManeuverPlannerTests.terraOrbit
    static let lunaOrbit = circularOrbit(altitude: 30_000, body: Bodies.luna)

    /// Узел `node` (с ошибкой прогрейда `error`), выполненный мгновенно: состояние сразу после импульса.
    static func applied(_ node: ManeuverNode, error: Double, body: BodyID, state: StateVector, time: Double) -> StateVector {
        let mu = Bodies.body(body).mu
        let s = Kepler.propagate(position: state.position, velocity: state.velocity, mu: mu, dt: node.time - time)
        var n = node
        n.prograde += error
        return StateVector(position: s.position,
                           velocity: s.velocity + TrajectoryPredictor.deltaVVector(node: n, position: s.position, velocity: s.velocity))
    }

    static func check(_ goal: ManeuverGoal, body: BodyID, state: StateVector, time: Double, label: String) throws {
        let before = ManeuverPlanner.outcome(goal, trajectory: TrajectoryPredictor.predict(
            body: body, state: state, time: time, maxPatches: TrajectoryPredictor.defaultMapPatches))
        #expect(!before.isGood, "\(label): уже годно \(before.kind)")
        let start = Date()
        let result = try #require(ManeuverPlanner.correctionSearch(goal, body: body, state: state, time: time), "\(label)")
        let elapsed = Date().timeIntervalSince(start)
        let node = result.node
        #expect(abs(node.time - (time + 60)) < 1e-9)
        #expect(node.deltaV < 20, "\(label): Δv \(node.deltaV)")
        #expect(result.predictions <= 60)
        #expect(elapsed < 0.5)
        let traj = try ManeuverPlannerTests.after(node, body: body, state: state, time: time)
        let out = ManeuverPlanner.outcome(goal, trajectory: traj)
        #expect(out.isGood, "\(label): \(out.kind)")
        #expect(ManeuverPlanner.correction(goal, body: body, state: state, time: time) == node)
        print("Коррекция (\(label)): было \(before.kind), стало \(out.kind), прогрейд \(String(format: "%.2f", node.prograde)) "
              + "радиал \(String(format: "%.2f", node.radial)) м/с, прогнозов \(result.predictions), \(String(format: "%.3f", elapsed)) с")
    }

    @Test(arguments: [3.0, -3.0])
    func toLunaAfterInexactBurn(error: Double) throws {
        let plan = try #require(ManeuverPlanner.plan(.toLuna, body: .terra, state: Self.terraOrbit, time: 0))
        let s = Self.applied(plan, error: error, body: .terra, state: Self.terraOrbit, time: 0)
        try Self.check(.toLuna, body: .terra, state: s, time: plan.time, label: "к Луне \(error) м/с")
    }

    @Test(arguments: [2.0, -2.0])
    func returnHomeAtLunaAfterInexactBurn(error: Double) throws {
        let plan = try #require(ManeuverPlanner.plan(.returnHome, body: .luna, state: Self.lunaOrbit, time: 0))
        let s = Self.applied(plan, error: error, body: .luna, state: Self.lunaOrbit, time: 0)
        try Self.check(.returnHome, body: .luna, state: s, time: plan.time, label: "домой у Луны \(error) м/с")
    }

    @Test(arguments: [2.0, -2.0])
    func returnHomeAtTerraAfterInexactBurn(error: Double) throws {
        let plan = try #require(ManeuverPlanner.plan(.returnHome, body: .luna, state: Self.lunaOrbit, time: 0))
        let s = Self.applied(plan, error: error, body: .luna, state: Self.lunaOrbit, time: 0)
        let traj = TrajectoryPredictor.predict(body: .luna, state: s, time: plan.time,
                                               maxPatches: TrajectoryPredictor.defaultMapPatches)
        let exit = try #require(traj.returnToTerra)
        let t = exit.time + 3_600
        let at = try #require(traj.state(at: t))
        #expect(at.body == .terra)
        try Self.check(.returnHome, body: .terra, state: at.state, time: t, label: "домой у Терры \(error) м/с")
    }

    @Test func alreadyGoodOrOtherGoal() throws {
        let plan = try #require(ManeuverPlanner.plan(.toLuna, body: .terra, state: Self.terraOrbit, time: 0))
        let s = Self.applied(plan, error: 0, body: .terra, state: Self.terraOrbit, time: 0)
        #expect(ManeuverPlanner.correction(.toLuna, body: .terra, state: s, time: plan.time) == nil)
        let home = try #require(ManeuverPlanner.plan(.returnHome, body: .luna, state: Self.lunaOrbit, time: 0))
        let h = Self.applied(home, error: 0, body: .luna, state: Self.lunaOrbit, time: 0)
        #expect(ManeuverPlanner.correction(.returnHome, body: .luna, state: h, time: home.time) == nil)
        #expect(ManeuverPlanner.correction(.circularize, body: .terra, state: s, time: plan.time) == nil)
        #expect(ManeuverPlanner.correction(.changeOrbit, body: .terra, state: s, time: plan.time) == nil)
        #expect(ManeuverPlanner.correction(.toLuna, body: .luna, state: h, time: home.time) == nil)
    }

    /// После выхода к Терре итог «домой» — Пе текущего участка у Терры.
    @Test func returnHomeOutcomeAtTerra() {
        let s = conicState(body: Bodies.terra, periapsisRadius: Bodies.terra.radius + 35_000, apoapsisRadius: 12_000_000,
                           phase: 0, dt: -20_000)
        let out = ManeuverPlanner.outcome(.returnHome, trajectory: TrajectoryPredictor.predict(body: .terra, state: s, time: 0))
        guard case .terraPeriapsis(let pe) = out.kind else { Issue.record("вид \(out.kind)"); return }
        #expect(abs(pe - 35_000) < 1 && out.isGood)
    }
}
