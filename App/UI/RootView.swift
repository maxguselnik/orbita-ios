import OrbitPhysics
import SwiftUI

/// Корень приложения: ангар ↔ полёт (`GameFlow`). Рендер полёта — один на всё приложение.
@MainActor
struct RootView: View {
    @Environment(GameSettings.self) private var settings
    @State private var flow = GameFlow()
    @State private var renderer = SceneRenderer()
    @State private var hangarScene = HangarScene()
    @State private var feedback: FlightFeedback?
    /// Модель текущего полёта; создаётся при каждом старте (`flow.flightID`), вне полёта — nil.
    @State private var flight: FlightHUDModel?

    var body: some View {
        ZStack {
            switch flow.screen {
            case .hangar:
                HangarView(flow: flow, scene: hangarScene)
            case .flight:
                FlightSceneView(renderer: renderer)
                    .ignoresSafeArea()

                if let flight {
                    FlightHUDView(model: flight, frameRate: settings.frameRate,
                                  hintsEnabled: settings.hintsEnabled,
                                  onHangar: exitToHangar,
                                  onTutorial: { flow.startTutorial(.firstFlight) })
                        .id(flow.flightID)
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
        let model = FlightHUDModel(makeSimulation: { [flow] in flow.makeSimulation() }, scenario: flow.scenario, tutorial: flow.tutorial)
        model.feedback = feedback
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
        feedback?.stop()
        flight = nil
        flow.returnToHangar()
    }
}
