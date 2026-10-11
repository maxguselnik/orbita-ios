import SwiftUI

struct RootView: View {
    /// Этап 1: HUD на моковом полёте; физика потока A подключится при интеграции.
    @Environment(GameSettings.self) private var settings
    @State private var flight = FlightHUDModel()

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
