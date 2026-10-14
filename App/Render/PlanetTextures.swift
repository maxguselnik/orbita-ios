import OrbitPhysics
import RealityKit

/// Готовые атласы загружаются один раз и разделяются между картой и полётным рендером.
/// На игровом потоке нет генерации пикселей; мип-уровни убирают мерцание с дальней орбиты.
@MainActor
enum PlanetTextures {
    static func load(_ body: BodyID) async -> TextureResource? {
        let name = body == .terra ? "TerraSurface" : "LunaSurface"
        return try? await TextureResource(named: name)
    }
}
