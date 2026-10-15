import OrbitPhysics
import simd
import Testing
import SwiftUI
import UIKit
@testable import Orbita

@MainActor
struct FlightControlAuditTests {
    @Test func mapEyeDuringLesson() {
        let model = FlightHUDModel(makeSimulation: { FlightSim(design: .orbit) }, tutorial: .toLuna)
        model.toggleMap()
        #expect(model.map.isOpen)
        model.toggleMapPanels()
        #expect(model.mapPanelsHidden)
        model.toggleMapPanels()
        #expect(!model.mapPanelsHidden)
        model.exitTutorial()
        model.toggleMapPanels()
        #expect(model.mapPanelsHidden)
        model.toggleMapPanels()
        #expect(!model.mapPanelsHidden)
    }

    @Test func systemNavigationNeverChangesManeuverByBrowsing() {
        let model = FlightHUDModel(makeSimulation: { FlightSim(design: .orbit) })
        model.toggleMap()
        model.setMapFocus(.sol)
        #expect(model.isSystemMap)
        model.setMapFocus(.arda)
        #expect(model.isSystemMap)
        #expect(model.mapLocationText == "Арда")
        #expect(model.maneuverNode == nil)
        model.toggleMapPanels()
        model.setMapFocus(.vessel)
        #expect(!model.isSystemMap)
        #expect(model.map.focus == .vessel)
        #expect(model.mapPanelsHidden)
    }

    @Test func nextLessonStepRevealsItsControls() {
        let model = FlightHUDModel(makeSimulation: { TutorialID.toLuna.makeSimulation() }, tutorial: .toLuna)
        model.tick(now: 1)
        model.tutorialAcknowledge()
        model.tick(now: 1.05)
        model.toggleMap()
        model.tick(now: 1.1)
        #expect(model.tutorial?.display.target == .mapLuna)
        model.toggleMapPanels()
        #expect(model.mapPanelsHidden)
        model.planManeuver(.toLuna)
        model.tick(now: 1.2)
        #expect(model.tutorial?.display.target == .mapSummary)
        #expect(!model.mapPanelsHidden)
    }

    @Test func maneuverMapFitsShortLandscape() async throws {
        let model = FlightHUDModel(makeSimulation: { TutorialID.toLuna.makeSimulation() }, tutorial: .toLuna)
        model.tick(now: 1)
        model.tutorialAcknowledge()
        model.toggleMap()
        model.tick(now: 1.1)
        model.planManeuver(.toLuna)
        model.tick(now: 1.2)
        model.executeManeuver()
        #expect(model.isAutoBurning)
        let size = CGSize(width: 740, height: 371)
        let controller = UIHostingController(rootView: MapLayer(model: model, showLegend: .constant(false)).background(.black))
        let fitted = controller.sizeThatFits(in: size)
        #expect(fitted.width <= size.width && fitted.height <= size.height)
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orbita-map-layout-after.png")
        try #require(image.pngData()).write(to: path)
        print("MAP_LAYOUT_QA \(path.path)")
        window.isHidden = true
    }

    /// Обзор системы без боковых панелей: карточка тела и строка прожига помещаются в 740×371.
    @Test func systemMapFitsShortLandscape() async throws {
        let model = FlightHUDModel(makeSimulation: { TutorialID.toLuna.makeSimulation() }, tutorial: .toLuna)
        model.tick(now: 1)
        model.tutorialAcknowledge()
        model.toggleMap()
        model.tick(now: 1.1)
        model.setMapFocus(.sol)
        model.setMapFocus(.arda)
        #expect(model.isSystemMap)
        try await renderMap(model, name: "orbita-system-map-card.png")
        model.planManeuver(.toLuna)
        model.tick(now: 1.2)
        model.executeManeuver()
        #expect(model.isAutoBurning)
        model.setMapFocus(.sol)
        try await renderMap(model, name: "orbita-system-map-burn.png")
    }

    private func renderMap(_ model: FlightHUDModel, name: String) async throws {
        let size = CGSize(width: 740, height: 371)
        let controller = UIHostingController(rootView: MapLayer(model: model, showLegend: .constant(false)).background(.black))
        let fitted = controller.sizeThatFits(in: size)
        #expect(fitted.width <= size.width && fitted.height <= size.height)
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        await Task.yield()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try #require(image.pngData()).write(to: path)
        print("MAP_LAYOUT_QA \(path.path)")
        window.isHidden = true
    }

    @Test func headingCameraKeepsAzimuthForVerticalMotion() {
        var camera = CameraRig()
        let first = camera.offset(forward: D3(0, 0, 1), up: D3(1, 0, 0), dt: 0).offset
        var last = first
        for i in 0..<120 {
            last = camera.offset(forward: D3(1, i.isMultiple(of: 2) ? 1e-4 : -1e-4, 0),
                                 up: D3(1, 0, 0), dt: 1.0 / 60).offset
        }
        #expect(simd_length(last - first) < 1e-6)
    }

    @Test func retrogradeLosesDampingAtLowSpeed() {
        let sim = FlightSim(design: VesselDesign(name: "SAS audit", parts: [.podK1]), body: .luna,
                            position: Vec3(Bodies.luna.radius + Terrain.surfaceHeight(body: .luna, direction: .unitX) + 1_000, 0, 0), velocity: Vec3(0, 0.1, 0))
        sim.setInput(ControlInput(pitch: 1))
        _ = sim.advance(realDelta: 0.1)
        sim.setInput(.neutral)
        sim.send(.setSAS(.retrograde))
        let before = sim.snapshot.vessels[0].angularVelocity.length
        _ = sim.advance(realDelta: 0.1)
        let after = sim.snapshot.vessels[0].angularVelocity.length
        #expect(before > 0.01)
        #expect(sim.snapshot.telemetry.situation != .landed && sim.snapshot.telemetry.situation != .crashed)
        #expect(sim.snapshot.telemetry.surfaceSpeed < 0.5)
        print("CONTROL_AUDIT retro lowSpeed=\(sim.snapshot.telemetry.surfaceSpeed)m/s angularRateBefore=\(before) after=\(after)rad/s")
        #expect(after < before * 0.8)
    }

    @Test(arguments: [0, 3]) func retrogradeOrbitalTurn(warp: Int) throws {
        let sim = DemoScenario.orbit.makeSimulation()
        sim.send(.setSAS(.retrograde))
        sim.send(.setWarp(index: warp))
        var settledError = 0.0
        var settledRate = 0.0
        for i in 0..<3_600 {
            _ = sim.advance(realDelta: 1.0 / 60)
            let state = sim.snapshot.vessels[0]
            if i >= 1_800 {
                let dot = state.attitude.nose.dot(-state.velocity.normalized)
                settledError = max(settledError, acos(min(1, max(-1, dot))))
                settledRate = max(settledRate, state.angularVelocity.length)
            }
        }
        print("CONTROL_AUDIT retro orbit warp=\(TimeWarp.levels[warp]) settledMaxError=\(settledError * 180 / .pi)deg maxRate=\(settledRate)rad/s")
        #expect(settledError < 0.05)
    }
}
