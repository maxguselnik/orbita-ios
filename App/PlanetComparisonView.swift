import Foundation
import OrbitPhysics
import SwiftUI

/// Диагностический кадр (-planet-preview): настоящие материалы, меши, облака и свет карты.
/// Никакого автопилота или отдельного программного освещения — только игровой SceneRenderer.
@MainActor
struct PlanetComparisonView: View {
    var flightMode = false
    var closeup = false
    var newWorlds = false
    var body: some View {
        HStack(spacing: 0) {
            if newWorlds {
                PlanetComparisonViewport(body: .vella, title: "ВЕЛЛА", flightMode: flightMode, closeup: closeup)
                PlanetComparisonViewport(body: .arda, title: "АРДА", flightMode: flightMode, closeup: closeup)
                if !closeup {
                    PlanetComparisonViewport(body: .taros, title: "ТАРОС", flightMode: flightMode, closeup: false)
                }
            } else {
                PlanetComparisonViewport(body: .terra, title: "ТЕРРА", flightMode: flightMode, closeup: closeup)
                PlanetComparisonViewport(body: .luna, title: "ЛУНА", flightMode: flightMode, closeup: closeup)
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

@MainActor
private struct PlanetComparisonViewport: View {
    let bodyID: BodyID
    let title: String
    let flightMode: Bool
    let closeup: Bool
    @State private var renderer = SceneRenderer()
    @State private var driver = FrameDriver()

    init(body: BodyID, title: String, flightMode: Bool, closeup: Bool) {
        bodyID = body
        self.title = title
        self.flightMode = flightMode
        self.closeup = closeup
    }

    var body: some View {
        GeometryReader { geo in
            FlightSceneView(renderer: renderer)
                .overlay(alignment: .bottom) {
                    Text(title + (closeup ? " · поверхность, 160 м" : flightMode ? " · полёт" : " · карта"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.bottom, 14)
                }
                .onAppear { start(size: geo.size) }
                .onChange(of: geo.size) { _, size in renderer.viewSize = size }
                .onDisappear { driver.stop() }
        }
    }

    private func start(size: CGSize) {
        // Стабильный снимок без корабля и без шестиминутного автополёта к Луне.
        var snapshot = FlightSim(design: .orbit).snapshot
        renderer.targetFrameRate = 60
        let mode = closeup ? "surface" : flightMode ? "flight" : "map"
        let name = bodyID.rawValue
        let readyFile = URL.documentsDirectory.appendingPathComponent("planet-\(mode)-\(name).ready")
        var written = false
        if flightMode {
            let direction = PlanetInspection.direction(bodyID)
            snapshot.vessels[0].body = bodyID
            snapshot.vessels[0].position = direction.normalized * (Bodies.body(bodyID).radius + 80_000)
            renderer.inspectionBody = bodyID
            renderer.inspectionCloseup = closeup
            driver.frameRate = .hz60
            driver.start { [renderer, snapshot] _ in
                renderer.update(snapshot: snapshot, events: [], frameDelta: 1.0 / 60)
                if !written, renderer.isInspectionReady {
                    written = (try? Data("ready".utf8).write(to: readyFile, options: .atomic)) != nil
                }
            }
            return
        }
        snapshot.vessels = []
        renderer.isMapMode = true
        renderer.mapFocus = .body(bodyID)
        renderer.viewSize = size
        renderer.updateMap(.empty)
        renderer.update(snapshot: snapshot, events: [], frameDelta: 0)
        // Те же полушария, что были показаны в отдельном предпросмотре.
        let direction = PlanetInspection.direction(bodyID)
        let azimuth = atan2(direction.y, direction.x)
        let elevation = atan2(direction.z, hypot(direction.x, direction.y))
        renderer.apply(CameraInput(orbitDelta: SIMD2(Float(azimuth - MapCamera.defaultAzimuth),
                                                     Float(elevation - MapCamera.defaultElevation)),
                                   zoomFactor: 0.7))
        renderer.update(snapshot: snapshot, events: [], frameDelta: 1)
        driver.frameRate = .hz60
        driver.start { [renderer, snapshot] _ in
            renderer.update(snapshot: snapshot, events: [], frameDelta: 1.0 / 60)
            if !written, renderer.isInspectionReady {
                written = (try? Data("ready".utf8).write(to: readyFile, options: .atomic)) != nil
            }
        }
    }
}

/// Один ракурс для сравнения карты и полёта, всегда над освещённой стороной новых миров.
enum PlanetInspection {
    static func direction(_ id: BodyID) -> Vec3 {
        if id == .terra { return Vec3(1, 0.55, 0.3) }
        if id == .luna { return Vec3(-0.6, 1, 0.25) }
        let sun = World.position(of: .sol, relativeTo: id, at: 0).normalized
        return sun + Vec3.unitZ.cross(sun) * 0.5 + Vec3.unitZ * 0.25
    }
}
