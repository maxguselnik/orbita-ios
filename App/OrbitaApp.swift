import SwiftUI

@main
struct OrbitaApp: App {
    @State private var settings = GameSettings()

    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("-navball-preview") {
                    NavballPreviewExport()
                } else {
                    RootView()
                }
            }
            .environment(settings)
        }
    }
}
