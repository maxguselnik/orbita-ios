import OrbitPhysics
import RealityKit
import UIKit

/// Готовые атласы загружаются один раз и разделяются между картой и полётным рендером.
/// На игровом потоке нет генерации пикселей; мип-уровни убирают мерцание с дальней орбиты.
@MainActor
enum PlanetTextures {
    private static var cache: [BodyID: TextureResource] = [:]

    static func load(_ body: BodyID) async -> TextureResource? {
        if let cached = cache[body] { return cached }
        let name = body == .terra ? "TerraSurface" : "LunaSurface"
        // Asset Catalog может упаковать серую Луну в grayscale. Приводим оба атласа
        // к одинаковому sRGB RGBA перед RealityKit: загрузка не зависит от оптимизаций каталога.
        guard let source = UIImage(named: name)?.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: source.width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            report("PlanetTextures: cannot decode \(name)")
            return nil
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let rgba = context.makeImage() else { return nil }
        do {
            let texture = try await TextureResource(image: rgba, options: .init(semantic: .color))
            cache[body] = texture
            report("PlanetTextures: loaded \(name), source \(source.bitsPerPixel)bpp, RGBA \(rgba.width)x\(rgba.height)")
            return texture
        } catch {
            report("PlanetTextures: \(name) failed: \(error)")
            return nil
        }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
