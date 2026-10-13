import Foundation
import OrbitPhysics

/// Стартовый сценарий. Аргумент запуска `-screen <имя>` (CI-скриншоты, отладка);
/// без аргумента игра открывается в ангаре (`GameFlow`).
enum DemoScenario: String, CaseIterable, Sendable {
    /// Ангар с проектом «Орбита».
    case hangar
    /// Ангар без деталей: проверка начала сборки с нуля.
    case hangarEmpty
    /// На площадке, «Орбита».
    case flight
    /// Урок «Первый полёт» на площадке (первый шаг).
    case tutorial
    /// Урок «Полёт к Луне» на орбите 80 км (первый шаг).
    case tutorialLuna
    /// Урок «Все кнопки» на площадке (первый шаг).
    case tutorialControls
    /// Подъём на автопилоте, около max Q.
    case ascent
    /// Подъём на автопилоте, около 1 Маха (конденсационный конус, тряска).
    case transonic
    /// Подъём на автопилоте, разделение первой ступени.
    case staging
    /// На орбите 80×74 км.
    case orbit
    /// На орбите 80×74 км с блоком РСУ: РСУ включено, держится команда «вперёд и вправо» — HUD с поступательным
    /// джойстиком и струйки сопел в рендере.
    case rcs
    /// Перелёт к Луне, вход в её сферу влияния.
    case lunaApproach
    /// На поверхности Луны (пресет «Луна»).
    case lunaSurface
    /// Посадочный блок в 1.5 км над Луной (свободное падение, касание через ~40 с) при низком Солнце: видны кратеры у места посадки.
    case lunaDescent
    /// Капсула над площадкой, купол раскрывается в кадре.
    case chute
    /// Капсула на куполе за секунды до касания; затем экран результата.
    case landed
    /// Капсула без парашюта за секунды до удара о грунт.
    case crash
    /// Капсула входит в атмосферу на ~2.3 км/с, плазма.
    case reentry
    /// Карта на орбите 80×74 км, без узла.
    case map
    /// Карта на орбите с узлом гомановского перелёта к Луне (встреча).
    case mapManeuver
    /// Карта при входе в сферу влияния Луны, фокус на Луне.
    case mapLuna

    /// Урок обучения, который открывает сцена.
    var tutorial: TutorialID? {
        switch self {
        case .tutorial: .firstFlight
        case .tutorialLuna: .toLuna
        case .tutorialControls: .controls
        default: nil
        }
    }

    /// Сцена открывается на карте.
    var opensMap: Bool {
        switch self {
        case .map, .mapManeuver, .mapLuna: true
        default: false
        }
    }

    /// Фокус камеры карты для сцены.
    var mapFocus: MapFocus {
        self == .mapLuna ? .luna : .vessel
    }

    /// Сценарий из аргумента `-screen`, nil — обычный запуск.
    static var fromArguments: DemoScenario? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return nil }
        return DemoScenario(rawValue: args[i + 1])
    }

    /// Создаёт полёт: прокручивает автопилот до нужного момента; на подъёме автопилот ведёт и дальше.
    func makeSimulation() -> any FlightSimulation {
        switch self {
        case .hangar, .hangarEmpty, .flight, .tutorial, .tutorialControls:
            return FlightSim(design: .orbit)
        case .tutorialLuna:
            return TutorialID.toLuna.makeSimulation()
        case .ascent:
            return ScenarioFlight(design: .orbit, goal: .orbit, keepAutopilot: true) { sim, _ in sim.time >= 55 }
        case .transonic:
            return ScenarioFlight(design: .orbit, goal: .orbit, keepAutopilot: true) { sim, _ in
                sim.snapshot.telemetry.mach >= 0.95 || sim.time > 120
            }
        case .staging:
            let initial = FlightSim(design: .orbit).stageCount
            return ScenarioFlight(design: .orbit, goal: .orbit, keepAutopilot: true) { sim, _ in
                sim.stageCount < initial - 1
            }
        case .mapManeuver:
            let flight = ScenarioFlight(design: .orbit, goal: .orbit, keepAutopilot: false) { _, ap in ap.isFinished }
            flight.send(.setManeuver(Self.lunaTransferNode(flight.snapshot)))
            return flight
        case .orbit, .map:
            return ScenarioFlight(design: .orbit, goal: .orbit, keepAutopilot: false) { _, ap in ap.isFinished }
        case .rcs:
            return ScenarioFlight(design: Self.rcsDesign, goal: .orbit, keepAutopilot: false,
                                  rcsOn: true, heldTranslation: Vec3(0.6, 1, 0)) { _, ap in ap.isFinished }
        case .lunaApproach, .mapLuna:
            return ScenarioFlight(design: .luna, goal: .lunaEncounter, keepAutopilot: false) { sim, _ in
                sim.activeBody == .luna
            }
        case .lunaSurface:
            return ScenarioFlight(design: .luna, goal: .lunaLanding, keepAutopilot: false) { _, ap in ap.isFinished }
        case .lunaDescent:
            return Self.lunaDescent(height: 1_500, speed: 0)
        case .chute:
            let sim = Self.descent(chute: true, height: 2_500, speed: 120)
            sim.send(.deployChute)
            return sim
        case .landed:
            let sim = Self.descent(chute: true, height: 2_500, speed: 120)
            sim.send(.deployChute)
            Self.roll(sim) { $0.snapshot.telemetry.heightAboveTerrain < 25 }
            return sim
        case .crash:
            let sim = Self.descent(chute: false, height: 1_500, speed: 100)
            Self.roll(sim) { $0.snapshot.telemetry.heightAboveTerrain < 120 }
            return sim
        case .reentry:
            let sim = Self.entry()
            Self.roll(sim) { $0.snapshot.telemetry.heating > 0.35 }
            return sim
        }
    }

    /// «Орбита» с блоком РСУ и баком монотоплива под капсулой.
    private static let rcsDesign = VesselDesign(
        name: "РСУ",
        parts: [.chute, .podK1, .rcsBlock, .m100, .decoupler, .t400, .shtil, .decoupler, .t800, .t800, .vikhr])

    /// Капсула К-1 (с парашютом или без) над площадкой (≈ 1 км к северу), падает со скоростью `speed`.
    private static func descent(chute: Bool, height: Double, speed: Double) -> FlightSim {
        let design = VesselDesign(name: "Спуск", parts: chute ? [.chute, .podK1] : [.podK1])
        let fixed = (World.padDirection + Vec3.unitZ * 0.0015).normalized
        let up = World.fromBodyFixed(fixed, body: .terra, time: 0)
        let ground = Bodies.terra.radius + max(0, Terrain.surfaceHeight(body: .terra, direction: fixed))
        let r = up * (ground + height)
        let east = Vec3.unitZ.cross(up).normalized
        let v = World.surfaceVelocity(body: .terra, position: r) - up * speed
        return FlightSim(design: design, body: .terra, position: r, velocity: v,
                         attitude: Quat(basisX: east, y: up, z: east.cross(up)))
    }

    /// Посадочный блок «Луны» над грунтом Луны, Солнце ≈ 17° над горизонтом (тени в кратерах).
    private static func lunaDescent(height: Double, speed: Double) -> FlightSim {
        let design = VesselDesign(name: "Посадка", parts: [.chute, .podK1, .t800, .legs, .shtil])
        // Направление на Солнце — как `SkyVisual.sunDirection` (инерциальная система, неподвижно).
        let sun = Vec3(0.6, 0.75, 0.3).normalized
        let side = sun.cross(Vec3.unitZ).normalized
        let up = (sun * 0.3 + side * 0.954).normalized
        let fixed = World.toBodyFixed(up, body: .luna, time: 0)
        let ground = Bodies.luna.radius + Terrain.surfaceHeight(body: .luna, direction: fixed)
        let r = up * (ground + height)
        let east = Vec3.unitZ.cross(up).normalized
        let v = World.surfaceVelocity(body: .luna, position: r) - up * speed
        return FlightSim(design: design, body: .luna, position: r, velocity: v,
                         attitude: Quat(basisX: east, y: up, z: east.cross(up)))
    }

    /// Капсула К-1 с парашютом на высоте 48 км над площадкой: 2.3 км/с на восток, снижение под 6°, щитом вперёд.
    private static func entry() -> FlightSim {
        let design = VesselDesign(name: "Вход", parts: [.chute, .podK1])
        let fixed = World.padDirection
        let up = World.fromBodyFixed(fixed, body: .terra, time: 0)
        let r = up * (Bodies.terra.radius + 48_000)
        let east = Vec3.unitZ.cross(up).normalized
        let dir = (east * cos(0.105) - up * sin(0.105)).normalized
        let v = World.surfaceVelocity(body: .terra, position: r) + dir * 2_300
        // Нос (+Y) против скорости — щит капсулы впереди.
        let nose = -dir
        let side = nose.cross(up).normalized
        return FlightSim(design: design, body: .terra, position: r, velocity: v,
                         attitude: Quat(basisX: side, y: nose, z: side.cross(nose)))
    }

    /// Узел перелёта к Луне: ближайшая точка орбиты с гомановской фазой, прогрейд на гомановский импульс.
    static func lunaTransferNode(_ world: WorldSnapshot) -> ManeuverNode {
        guard let v = world.vessels.first(where: { $0.id == world.activeVessel }) else {
            return ManeuverNode(time: world.time + 600)
        }
        let mu = Bodies.terra.mu
        let target = TrajectoryPredictor.hohmannLunaPhase(radius: v.position.length)
        let period = OrbitElements(position: v.position, velocity: v.velocity, mu: mu).period
        // Фаза за оборот корабля меняется на ~2π; ищем первое приближение к нужной в пределах двух оборотов.
        let horizon = period.isFinite ? 2 * period : 20_000
        var best = (dt: 60.0, error: Double.infinity)
        var dt = 60.0
        while dt < horizon {
            let s = Kepler.propagate(position: v.position, velocity: v.velocity, mu: mu, dt: dt)
            let phase = TrajectoryPredictor.lunaPhase(position: s.position, velocity: s.velocity, time: world.time + dt)
            let error = abs(remainder(phase - target, 2 * Double.pi))
            if error < best.error { best = (dt, error) }
            if error < 0.01 { break }
            dt += 5
        }
        let radius = v.position.length
        return ManeuverNode(time: world.time + best.dt, prograde: TrajectoryPredictor.hohmannLunaDeltaV(radius: radius))
    }

    /// Прокрутка физики по 1/60 с до условия (не дольше 10 мин симуляции).
    private static func roll(_ sim: FlightSim, until done: (FlightSim) -> Bool) {
        var t = 0.0
        while !done(sim) && t < 600 {
            _ = sim.advance(realDelta: 1.0 / 60)
            t += 1.0 / 60
        }
    }
}

/// Полёт, прокрученный автопилотом до условия; дальше — по вводу игрока или тем же автопилотом.
final class ScenarioFlight: FlightSimulation, FlightCheckpointing {
    private let sim: FlightSim
    private let autopilot: Autopilot?
    private var pending = 0.0
    /// Поступательная команда, которую сцена держит поверх ввода игрока (нули — не переопределять).
    private let heldTranslation: Vec3

    /// `rcsOn` — включить РСУ после прокрутки; `heldTranslation` — удерживаемая команда РСУ (сцена `rcs`).
    init(design: VesselDesign, goal: Autopilot.Goal, keepAutopilot: Bool,
         rcsOn: Bool = false, heldTranslation: Vec3 = .zero,
         until done: (FlightSim, Autopilot) -> Bool) {
        self.heldTranslation = heldTranslation
        sim = FlightSim(design: design)
        let ap = Autopilot(goal: goal)
        while !done(sim, ap) && !ap.isFinished && sim.time < 600_000 {
            ap.update(sim)
            _ = sim.advance(realDelta: ap.frameDelta)
        }
        if !keepAutopilot {
            sim.send(.setWarp(index: 0))
            sim.setInput(.neutral)
        }
        if rcsOn { sim.send(.setRCS(true)) }
        autopilot = keepAutopilot ? ap : nil
    }

    var snapshot: WorldSnapshot { sim.snapshot }

    /// Откат (обучение) — только когда автопилот уже не ведёт.
    func checkpoint() -> SimCheckpoint { sim.checkpoint() }
    func restore(_ checkpoint: SimCheckpoint) { sim.restore(checkpoint) }

    func setInput(_ input: ControlInput) {
        guard autopilot?.isFinished ?? true else { return }
        var held = input
        if heldTranslation != .zero { held.translation = heldTranslation }
        sim.setInput(held)
    }

    func send(_ command: FlightCommand) {
        sim.send(command)
    }

    func predictTrajectory(maxPatches: Int) -> Trajectory {
        sim.predictTrajectory(maxPatches: maxPatches)
    }

    func predictManeuver(_ node: ManeuverNode, maxPatches: Int) -> ManeuverPrediction? {
        sim.predictManeuver(node, maxPatches: maxPatches)
    }

    func advance(realDelta: Double) -> [SimEvent] {
        guard let ap = autopilot, !ap.isFinished else { return sim.advance(realDelta: realDelta) }
        pending += realDelta
        var events: [SimEvent] = []
        while pending >= ap.frameDelta {
            pending -= ap.frameDelta
            ap.update(sim)
            events += sim.advance(realDelta: ap.frameDelta)
        }
        return events
    }
}
