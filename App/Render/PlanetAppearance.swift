import OrbitPhysics
import UIKit

/// Единые цвета и имена атласов в карте и полёте.
enum PlanetAppearance {
    static func textureName(_ body: BodyID) -> String? {
        switch body {
        case .sol: nil
        case .terra: "TerraSurface"
        case .luna: "LunaSurface"
        case .vella: "VellaSurface"
        case .arda: "ArdaSurface"
        case .taros: "TarosSurface"
        }
    }
    static func color(_ body: BodyID) -> UIColor {
        switch body {
        case .sol: UIColor(red: 1, green: 0.85, blue: 0.5, alpha: 1)
        case .terra: UIColor(red: 0.25, green: 0.42, blue: 0.22, alpha: 1)
        case .luna: UIColor(white: 0.5, alpha: 1)
        case .vella: UIColor(red: 0.77, green: 0.54, blue: 0.25, alpha: 1)
        case .arda: UIColor(red: 0.67, green: 0.29, blue: 0.16, alpha: 1)
        case .taros: UIColor(red: 0.69, green: 0.64, blue: 0.53, alpha: 1)
        }
    }
}
