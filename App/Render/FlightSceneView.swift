import RealityKit
import SwiftUI

/// 3D-сцена полёта: виртуальная камера; содержимое и камеру ведёт `SceneRenderer`.
struct FlightSceneView: View {
    let renderer: SceneRenderer

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            // Вьюха пересоздаётся (ангар ↔ полёт), а рендер живёт дольше: отцепить корень от прошлого родителя.
            renderer.root.removeFromParent()
            content.add(renderer.root)
        }
        .background(.black)
    }
}
