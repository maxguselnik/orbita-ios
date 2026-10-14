import OrbitPhysics
import SwiftUI
import UIKit

/// Одноразовый экспорт настоящего SwiftUI-прибора для предпросмотра в CI.
@MainActor
struct NavballPreviewExport: View {
    @State private var model = FlightHUDModel(makeSimulation: { DemoScenario.orbit.makeSimulation() })

    private var instrument: some View {
        NavballCluster(model: model, ascentEnabled: false)
            .frame(width: NavballCluster.width,
                   height: NavballCluster.height + NavballCluster.lift, alignment: .top)
            .clipped()
            .padding(12)
            .background(Color(red: 0.035, green: 0.045, blue: 0.055))
            .preferredColorScheme(.dark)
    }

    var body: some View {
        instrument.task {
            let renderer = ImageRenderer(content: instrument)
            renderer.scale = 3
            guard let data = renderer.uiImage?.pngData(),
                  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            do {
                try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
                try data.write(to: documents.appendingPathComponent("navball.png"), options: .atomic)
            } catch {
                print("Navball preview export failed: \(error)")
            }
        }
    }
}
