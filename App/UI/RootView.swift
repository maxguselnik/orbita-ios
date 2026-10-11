import OrbitPhysics
import SwiftUI

struct RootView: View {
    @Environment(GameSettings.self) private var settings
    /// Пока без ангара: полёт пресета «Орбита» на настоящей физике. MockFlight — для превью.
    @State private var flight = FlightHUDModel(makeSimulation: { FlightSim(design: .orbit) })

    var body: some View {
        ZStack {
            FlightSceneView()
                .ignoresSafeArea()

            FlightHUDView(model: flight)
        }
        .background(.black)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if flight.feedback == nil {
                flight.feedback = FlightFeedback(settings: settings)
            }
        }
    }
}
