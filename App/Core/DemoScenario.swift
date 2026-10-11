import Foundation
import OrbitPhysics

/// Стартовый сценарий полёта. Аргумент запуска `-screen <имя>` (CI-скриншоты, отладка);
/// без аргумента — пресет «Орбита» на площадке.
enum DemoScenario: String, CaseIterable, Sendable {
    /// На площадке, «Орбита».
    case flight
    /// Подъём на автопилоте, около max Q.
    case ascent
    /// Подъём на автопилоте, разделение первой ступени.
    case staging
    /// На орбите 80×74 км.
    case orbit
    /// Перелёт к Луне, вход в её сферу влияния.
    case lunaApproach
    /// На поверхности Луны (пресет «Луна»).
    case lunaSurface

    static var current: DemoScenario {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return .flight }
        return DemoScenario(rawValue: args[i + 1]) ?? .flight
    }

    /// Создаёт полёт: прокручивает автопилот до нужного момента; на подъёме автопилот ведёт и дальше.
    func makeSimulation() -> any FlightSimulation {
        switch self {
        case .flight:
            return FlightSim(design: .orbit)
        case .ascent:
            return ScenarioFlight(design: .orbit, goal: .orbit, keepAutopilot: true) { sim, _ in sim.time >= 55 }
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
        if autopilot == nil { sim.setInput(input) }
    }

    func send(_ command: FlightCommand) {
        sim.send(command)
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
