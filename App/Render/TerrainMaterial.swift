import Metal
import OrbitPhysics
import RealityKit
import UIKit

/// Общий материал карты и полёта. Атлас хранит географию, Metal добавляет
/// фактуру в метрах поверхности без новых мешей и вычислений на игровом потоке.
@MainActor
enum TerrainMaterial {
    private static let library = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()

    static func make(_ texture: TextureResource?, body: BodyID) -> any Material {
        let fallback = body == .terra
            ? UIColor(red: 0.25, green: 0.42, blue: 0.22, alpha: 1)
            : UIColor(white: 0.5, alpha: 1)
        guard let texture else { return SimpleMaterial(color: fallback, roughness: 1, isMetallic: false) }
        var base = PhysicallyBasedMaterial()
        base.baseColor = .init(tint: .white, texture: .init(texture))
        base.roughness = .init(floatLiteral: body == .terra ? 0.93 : 1)
        base.metallic = .init(floatLiteral: 0)
        // Убирает отражение студийного окружения по краю диска с орбиты.
        base.specular = .init(floatLiteral: 0)
        guard let library else { return base }
        do {
            let shader = CustomMaterial.SurfaceShader(named: "terrainSurface", in: library)
            var material = try CustomMaterial(from: base, surfaceShader: shader)
            // Радиус в метрах, тип тела, геометрия атласа. Остальные размеры выводятся в Metal.
            material.custom.value = SIMD4(Float(Bodies.body(body).radius), body == .luna ? 1 : 0,
                                           Float(PlanetSurface.faceSize), Float(PlanetSurface.gutter))
            FileHandle.standardError.write(Data("TerrainMaterial: detail ready for \(body)\n".utf8))
            return material
        } catch {
            FileHandle.standardError.write(Data("TerrainMaterial: detail unavailable: \(error)\n".utf8))
            return base
        }
    }
}
