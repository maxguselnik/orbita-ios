import OrbitPhysics
import RealityKit
import simd
import UIKit

/// Флаг: древко 1.8 м, тёмно-синее полотнище с оранжевой орбитой, табличка с подписью у основания.
/// Локальные оси: +Y — вертикаль (по радиусу), основание в нуле, полотнище в плоскости XY, табличка смотрит в +Z.
@MainActor
final class FlagVisual {
    let root = Entity()
    let id: Int

    private static let pole = SimpleMaterial(color: UIColor(white: 0.85, alpha: 1), roughness: 0.3, isMetallic: true)
    private static let cloth = SimpleMaterial(color: UIColor(red: 0.07, green: 0.14, blue: 0.33, alpha: 1), roughness: 0.9, isMetallic: false)
    private static let orange = UnlitMaterial(color: UIColor(red: 1.0, green: 0.52, blue: 0.14, alpha: 1))
    private static let plaque = SimpleMaterial(color: UIColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1), roughness: 0.5, isMetallic: true)
    private static let ink = UnlitMaterial(color: UIColor(white: 0.95, alpha: 1))

    /// Эмблема: наклонное эллиптическое кольцо орбиты и точка-планета; отдельно для каждой стороны полотнища.
    private static func emblem(z: Float, facing: Float) -> MeshResource? {
        var b = MeshBuilder()
        let n = 40
        let rx: Float = 0.24, ry: Float = 0.11, w: Float = 0.022, tilt: Float = 0.38
        func pt(_ a: Float, _ s: Float) -> F3 {
            let x = (rx + s) * cos(a), y = (ry + s) * sin(a)
            return F3(x * cos(tilt) - y * sin(tilt), x * sin(tilt) + y * cos(tilt), z)
        }
        let nrm = F3(0, 0, facing)
        for k in 0..<n {
            let a0 = Float(k) / Float(n) * 2 * .pi, a1 = Float(k + 1) / Float(n) * 2 * .pi
            let i0 = b.vertex(pt(a0, -w), nrm), i1 = b.vertex(pt(a1, -w), nrm)
            let i2 = b.vertex(pt(a1, w), nrm), i3 = b.vertex(pt(a0, w), nrm)
            b.quad(i0, i1, i2, i3, facing: nrm)
        }
        let c = b.vertex(F3(0, 0, z), nrm)
        var ring: [UInt32] = []
        for k in 0..<12 {
            let a = Float(k) / 12 * 2 * .pi
            ring.append(b.vertex(F3(cos(a) * 0.05, sin(a) * 0.05, z), nrm))
        }
        for k in 0..<12 { b.tri(c, ring[k], ring[(k + 1) % 12], facing: nrm) }
        return b.makeMesh(name: "flagEmblem")
    }

    init(id: Int, text: String) {
        self.id = id
        let poleE = ModelEntity(mesh: .generateCylinder(height: 1.8, radius: 0.014), materials: [Self.pole])
        poleE.position = F3(0, 0.9, 0)
        root.addChild(poleE)
        let knob = ModelEntity(mesh: .generateSphere(radius: 0.03), materials: [Self.pole])
        knob.position = F3(0, 1.82, 0)
        root.addChild(knob)

        let clothE = ModelEntity(mesh: .generateBox(size: F3(0.92, 0.58, 0.008)), materials: [Self.cloth])
        clothE.position = F3(0.47, 1.49, 0)
        root.addChild(clothE)
        for (z, facing) in [(Float(0.0045), Float(1)), (Float(-0.0045), Float(-1))] {
            if let m = Self.emblem(z: z, facing: facing) {
                let e = ModelEntity(mesh: m, materials: [Self.orange])
                e.position = F3(0.47, 1.49, 0)
                root.addChild(e)
            }
        }
        // Табличка у основания, наклонена к зрителю.
        let plaqueE = ModelEntity(mesh: .generateBox(size: F3(0.36, 0.22, 0.015), cornerRadius: 0.005), materials: [Self.plaque])
        plaqueE.position = F3(0, 0.16, 0.14)
        plaqueE.orientation = simd_quatf(angle: -0.5, axis: F3(1, 0, 0))
        root.addChild(plaqueE)
        let font = UIFont.systemFont(ofSize: 0.032, weight: .semibold)
        let textMesh = MeshResource.generateText(text, extrusionDepth: 0.002, font: font,
                                                 containerFrame: CGRect(x: -0.16, y: -0.09, width: 0.32, height: 0.18),
                                                 alignment: .center, lineBreakMode: .byWordWrapping)
        let textE = ModelEntity(mesh: textMesh, materials: [Self.ink])
        textE.position = F3(0, 0, 0.009)
        plaqueE.addChild(textE)
    }

    /// `rel` — основание относительно камеры, `up` — местная вертикаль (инерциальная система кадра).
    func update(rel: D3, up: D3) {
        // Рыскание по номеру флага, чтобы флаги не стояли строем.
        let yaw = simd_quatf(angle: Float(id) * 0.9 + 0.6, axis: F3(0, 1, 0))
        let tilt = simd_quatf(from: F3(0, 1, 0), to: f3(up))
        root.transform = Transform(scale: .one, rotation: tilt * yaw, translation: f3(rel))
    }
}
