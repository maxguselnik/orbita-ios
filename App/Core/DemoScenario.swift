import Foundation
import OrbitPhysics

/// Стартовый сценарий. Аргумент запуска `-screen <имя>` (CI-скриншоты, отладка);
/// без аргумента игра открывается в ангаре (`GameFlow`).
enum DemoScenario: String, CaseIterable, Sendable {
    /// Ангар с проектом «Орбита».
    case hangar
    /// На площадке, «Орбита».
    case flight
    /// Подъём на автопилоте, около max Q.
    case ascent
    /// Подъём на автопилоте, около 1 Маха (конденсационный конус, тряска).
    case transonic
    /// Подъём на автопилоте, разделение первой ступени.
    case staging
    /// На орбите 80×74 км.
    case orbit
    /// Перелёт к Луне, вход в её сферу влияния.
    case lunaApproach
    /// На поверхности Луны (пресет «Луна»).
    case lunaSurface
    /// Капсула над площадкой, купол раскрывается в кадре.
    case chute
    /// Капсула на куполе за секунды до касания; затем экран результата.
    case landed
    /// Капсула без парашюта за секунды до удара о грунт.
    case crash
    /// Капсула входит в атмосферу на ~2.3 км/с, плазма.
    case reentry

    /// Сценарий из аргумента `-screen`, nil — обычный запуск.
    static var fromArguments: DemoScenario? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return nil }
        return DemoScenario(rawValue: args[i + 1])
    }

    /// Создаёт полёт: прокручивает автопилот до нужного момента; на подъёме автопилот ведёт и дальше.
    func makeSimulation() -> any FlightSimulation {
        switch self {
        case .hangar, .flight:
            return FlightSim(design: .orbit)
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
        case .orbit:
            return ScenarioFlight(design: .orbit, goal: .orbit, keepAutopilot: false) { _, ap in ap.isFinished }
        case .lunaApproach:
            return ScenarioFlight(design: .luna, goal: .lunaEncounter, keepAutopilot: false) { sim, _ in
                sim.activeBody == .luna
            }
        case .lunaSurface:
            return ScenarioFlight(design: .luna, goal: .lunaLanding, keepAutopilot: false) { _, ap in ap.isFinished }
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
final class ScenarioFlight: FlightSimulation {
    private let sim: FlightSim
    private let autopilot: Autopilot?
    private var pending = 0.0

    init(design: VesselDesign, goal: Autopilot.Goal, keepAutopilot: Bool,
         until done: (FlightSim, Autopilot) -> Bool) {
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
        autopilot = keepAutopilot ? ap : nil
    }

    var snapshot: WorldSnapshot { sim.snapshot }

    func setInput(_ input: ControlInput) {
        if autopilot?.isFinished ?? true { sim.setInput(input) }
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
