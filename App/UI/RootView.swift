import OrbitPhysics
import SwiftUI

struct RootView: View {
    @Environment(GameSettings.self) private var settings
    /// Пока без ангара: сценарий из аргумента запуска (по умолчанию «Орбита» на площадке). MockFlight — для превью.
    @State private var flight = FlightHUDModel(makeSimulation: { DemoScenario.current.makeSimulation() })
    @State private var renderer = SceneRenderer()

    var body: some View {
        ZStack {
            FlightSceneView(renderer: renderer)
                .ignoresSafeArea()

            FlightHUDView(model: flight)
        }
        .background(.black)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if flight.feedback == nil {
                let feedback = FlightFeedback(settings: settings)
                feedback.renderer = renderer
                flight.feedback = feedback
            }
        }
    }
}
