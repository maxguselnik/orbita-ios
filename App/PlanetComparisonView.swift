import OrbitPhysics
import SwiftUI

/// Диагностический кадр (-planet-preview): настоящие материалы, меши, облака и свет карты.
/// Никакого автопилота или отдельного программного освещения — только игровой SceneRenderer.
@MainActor
struct PlanetComparisonView: View {
    var flightMode = false
    var body: some View {
        HStack(spacing: 0) {
            PlanetComparisonViewport(body: .terra, title: "ТЕРРА", flightMode: flightMode)
            PlanetComparisonViewport(body: .luna, title: "ЛУНА", flightMode: flightMode)
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
    @State private var renderer = SceneRenderer()
    @State private var driver = FrameDriver()

    init(body: BodyID, title: String, flightMode: Bool) {
        bodyID = body
        self.title = title
        self.flightMode = flightMode
    }

    var body: some View {
        GeometryReader { geo in
            FlightSceneView(renderer: renderer)
                .overlay(alignment: .bottom) {
                    Text(title + (flightMode ? " · полёт" : " · карта"))
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
        if flightMode {
            let direction = bodyID == .terra ? Vec3(1, 0.55, 0.3) : Vec3(-0.6, 1, 0.25)
            snapshot.vessels[0].body = bodyID
            snapshot.vessels[0].position = direction.normalized * (Bodies.body(bodyID).radius + 80_000)
            renderer.inspectionBody = bodyID
            driver.frameRate = .hz60
            driver.start { [renderer, snapshot] _ in
                renderer.update(snapshot: snapshot, events: [], frameDelta: 1.0 / 60)
            }
            return
        }
        snapshot.vessels = []
        renderer.isMapMode = true
        renderer.mapFocus = bodyID == .terra ? .terra : .luna
        renderer.viewSize = size
        renderer.updateMap(.empty)
        renderer.update(snapshot: snapshot, events: [], frameDelta: 0)
        // Те же полушария, что были показаны в отдельном предпросмотре.
        let azimuth = bodyID == .terra ? atan2(0.55, 1.0) : atan2(1.0, -0.6)
        let elevation = bodyID == .terra ? atan2(0.3, hypot(1.0, 0.55)) : atan2(0.25, hypot(-0.6, 1.0))
        renderer.apply(CameraInput(orbitDelta: SIMD2(Float(azimuth - MapCamera.defaultAzimuth),
                                                     Float(elevation - MapCamera.defaultElevation)),
                                   zoomFactor: 0.7))
        driver.frameRate = .hz60
        driver.start { [renderer, snapshot] _ in
            renderer.update(snapshot: snapshot, events: [], frameDelta: 1.0 / 60)
        }
    }
}
