import OrbitPhysics
import SwiftUI
import Testing
import UIKit
@testable import Orbita

@MainActor
struct CompactFlightHUDTests {
    @Test func overviewReleasesHeldControlsAndPreservesEngine() {
        let model = FlightHUDModel(makeSimulation: { FlightSim(design: .orbit) })
        model.send(.setSAS(.hold))
        model.throttle = 0.65
        model.setAttitude(.pitchUp, pressed: true, now: 1)
        model.setAttitude(.rollRight, pressed: true, now: 1)
        model.rcsRightInput = 1
        model.rcsForwardPressed = true
        model.isPanelOpen = true
        #expect(model.attitudeAxes(now: 2).pitch > 0)
        model.setFlightOverview(true)
        let axes = model.attitudeAxes(now: 2)
        #expect(axes.pitch == 0 && axes.roll == 0 && axes.yaw == 0)
        #expect(model.translationInput == .zero)
        #expect(model.throttle == 0.65)
        #expect(model.sas == .hold)
        #expect(!model.isPanelOpen)
        model.setFlightOverview(false)
        #expect(model.throttle == 0.65)
        model.setFlightOverview(true)
        model.toggleMap()
        #expect(!model.isFlightOverview && model.map.isOpen)
    }

    @Test func closingFlightControlsDoesNotLeaveRotationPressed() {
        let model = FlightHUDModel()
        model.setAttitude(.yawRight, pressed: true, now: 1)
        model.rcsUpInput = -1
        model.rcsBackPressed = true
        model.releaseFlightControls()
        #expect(model.attitudeAxes(now: 2).yaw == 0)
        #expect(model.translationInput == .zero)
    }

    /// Рендер в настоящем UIKit-окне: короткий экран и три состояния панели плюс обзор.
    @Test func compactHUDOnShortLandscape() async throws {
        let model = FlightHUDModel(makeSimulation: { FlightSim(design: .orbit) }, crew: Array(CrewRoster.standard.prefix(4)))
        for size in [CGSize(width: 852, height: 393), CGSize(width: 740, height: 371)] {
            for page in [CompactFlightPage.summary, .crew, .science] {
                model.isPanelOpen = true
                let view = CompactFlightLayer(model: model, initialPage: page)
                try await render(view, size: size, name: "compact-\(Int(size.width))-\(page)")
            }
            model.isPanelOpen = false
            try await render(CompactFlightLayer(model: model), size: size, name: "compact-\(Int(size.width))-flight")
            model.setFlightOverview(true)
            try await render(CompactFlightLayer(model: model), size: size, name: "compact-\(Int(size.width))-overview")
            model.setFlightOverview(false)
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) async throws {
        let controller = UIHostingController(rootView: view.background(Color(red: 0.03, green: 0.06, blue: 0.1)))
        let fitted = controller.sizeThatFits(in: size)
        #expect(fitted.width <= size.width && fitted.height <= size.height)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        await Task.yield()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png")
        try #require(image.pngData()).write(to: path)
        print("COMPACT_HUD_QA \(path.path)")
        window.isHidden = true
    }
}
