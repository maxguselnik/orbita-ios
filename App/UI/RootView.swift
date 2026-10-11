import OrbitPhysics
import SwiftUI

struct RootView: View {
    @Environment(GameSettings.self) private var settings

    var body: some View {
        ZStack(alignment: .top) {
            FlightSceneView()
                .ignoresSafeArea()

            Text("Орбита · этап 0 · \(Bodies.terra.name) · \(settings.frameRate.rawValue) Гц")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .padding(8)
        }
        .background(.black)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}
