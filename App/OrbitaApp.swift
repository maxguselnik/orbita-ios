import SwiftUI

@main
struct OrbitaApp: App {
    @State private var settings = GameSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
        }
    }
}
