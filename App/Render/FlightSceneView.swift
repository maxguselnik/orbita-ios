import RealityKit
import SwiftUI

/// Пустая 3D-сцена: виртуальная камера, свет и шар-заглушка Терры.
struct FlightSceneView: View {
    let renderer: SceneRenderer

    var body: some View {
        RealityView { content in
            content.camera = .virtual

            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 60
            camera.look(at: .zero, from: [0, 0.6, 3], relativeTo: nil)
            content.add(camera)

            let terra = ModelEntity(
                mesh: .generateSphere(radius: 1),
                materials: [SimpleMaterial(color: .systemTeal, roughness: 0.8, isMetallic: false)]
            )
            content.add(terra)

            let sun = DirectionalLight()
            sun.light.intensity = 4000
            sun.look(at: .zero, from: [3, 2, 2], relativeTo: nil)
            content.add(sun)
        }
        .background(.black)
    }
}
