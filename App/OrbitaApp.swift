import SwiftUI

@main
struct OrbitaApp: App {
    @State private var settings = GameSettings()

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-planet-preview") {
                PlanetComparisonView(flightMode: ProcessInfo.processInfo.arguments.contains("-flight-render"),
                                     closeup: ProcessInfo.processInfo.arguments.contains("-surface-closeup"),
                                     newWorlds: ProcessInfo.processInfo.arguments.contains("-new-worlds"))
            } else {
                RootView()
                    .environment(settings)
            }
        }
    }
}
