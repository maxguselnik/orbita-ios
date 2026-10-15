import OrbitPhysics
import SwiftUI

/// Корень приложения: космоцентр ↔ цех / исследования ↔ полёт (`GameFlow`). Рендер полёта — один на всё приложение.
@MainActor
struct RootView: View {
    @Environment(GameSettings.self) private var settings
    @State private var flow = GameFlow()
    @State private var renderer = SceneRenderer()
    @State private var hangarScene = HangarScene()
    @State private var spaceCenterScene = SpaceCenterScene()
    @State private var feedback: FlightFeedback?
    /// Модель текущего полёта; создаётся при каждом старте (`flow.flightID`), вне полёта — nil.
    @State private var flight: FlightHUDModel?

    var body: some View {
        ZStack {
            switch flow.screen {
            case .spaceCenter:
                SpaceCenterView(flow: flow, scene: spaceCenterScene, settings: settings)
            case .hangar:
                HangarView(flow: flow, scene: hangarScene, settings: settings)
            case .research:
                ResearchView(flow: flow)
            case .flight:
                FlightSceneView(renderer: renderer)
                    .ignoresSafeArea()

                if let flight {
                    FlightHUDView(model: flight, frameRate: settings.frameRate,
                                  hintsEnabled: settings.hintsEnabled,
                                  onHangar: exitToHangar,
                                  onSpaceCenter: exitToSpaceCenter,
                                  onFinish: { [flight] _ in flow.finishFlight(flight.telemetry) },
                                  onTutorial: { flow.startTutorial($0) })
                        .id(flow.flightID)
                }

                if flow.scenario == .crewGallery {
                    CrewGallery()
                        .ignoresSafeArea()
                }
            }
        }
        .background(.black)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Первый свайп снизу показывает индикатор «домой», сворачивает только второй (тяга тянется у нижнего края).
        .defersSystemGestures(on: .bottom)
        .onAppear {
            if flow.screen == .flight, flight == nil { startFlight() }
        }
        .onChange(of: flow.flightID) { startFlight() }
    }

    /// Новый полёт: свежая модель HUD, чистая сцена, звук и вибрация включены.
    private func startFlight() {
        let feedback = feedback ?? makeFeedback()
        renderer.reset()
        let model = FlightHUDModel(makeSimulation: { [flow] in flow.makeSimulation() }, scenario: flow.scenario, tutorial: flow.tutorial,
                                   crew: flow.flightCrew)
        model.feedback = feedback
        model.onRestart = { [flow, weak model] _ in if let model { flow.restartFlight(model.telemetry) } }
        model.onTutorialExit = { [flow] in flow.leaveTutorial($0) }
        feedback.recalibrate()
        feedback.setPaused(false)
        flight = model
    }

    private func makeFeedback() -> FlightFeedback {
        let created = FlightFeedback(settings: settings)
        created.renderer = renderer
        feedback = created
        return created
    }

    private func exitToHangar() {
        if let flight { flow.finishFlight(flight.telemetry) }
        feedback?.stop()
        flight = nil
        flow.returnToHangar()
    }

    private func exitToSpaceCenter() {
        if let flight { flow.finishFlight(flight.telemetry) }
        feedback?.stop()
        flight = nil
        flow.returnToHangar()
        flow.open(.spaceCenter)
    }
}
