import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Мир и рельеф")
struct WorldTests {
    @Test func lunaOrbit() {
        let t = 12_345.0
        let p = World.lunaPosition(at: t), v = World.lunaVelocity(at: t)
        #expect(abs(p.length - 12_000_000) < 1e-3)
        #expect(abs(p.z) < 1e-9)
        #expect(abs(v.length - (Bodies.terra.mu / 12_000_000).squareRoot()) < 1e-6)
        #expect(p.cross(v).z > 0)  // против часовой, как вращение Терры
        // Скорость — производная положения.
        let d = (World.lunaPosition(at: t + 1) - World.lunaPosition(at: t - 1)) / 2
        #expect((d - v).length < 1e-3)
    }

    @Test func terraRotationAndFrames() {
        #expect(abs(World.terraRotationRate * 6 * 3_600 - 2 * .pi) < 1e-12)
        let p = Vec3(1, 2, 3)
        let back = World.fromBodyFixed(World.toBodyFixed(p, body: .terra, time: 777), body: .terra, time: 777)
        #expect((back - p).length < 1e-12)
        // Скорость поверхности на экваторе ≈ 174.5 м/с на восток.
        let v = World.surfaceVelocity(body: .terra, position: Vec3(Bodies.terra.radius, 0, 0))
        #expect(abs(v.y - 174.53) < 0.1)
    }

    @Test func terrainDeterministicPadFlatAndOceans() {
        let pad = World.padDirection
        #expect(Terrain.padHeight > 0)
        #expect(Terrain.height(body: .terra, direction: pad) == Terrain.padHeight)
        // Ровно в радиусе ~1 км от площадки.
        for k in 0..<16 {
            let a = Double(k) / 16 * 2 * .pi
            let d = (pad + Vec3(0, cos(a), sin(a)) * (1_000 / Bodies.terra.radius)).normalized
            #expect(abs(Terrain.height(body: .terra, direction: d) - Terrain.padHeight) < 1)
        }
        #expect(Terrain.biome(body: .terra, direction: pad) == .launchPad)
        // Есть и суша, и океан.
        var ocean = 0.0, total = 0.0
        var biomes = Set<Biome>()
        for i in 0..<40 {
            for j in 0..<80 {
                let lat = (Double(i) + 0.5) / 40 * .pi - .pi / 2
                let lon = Double(j) / 80 * 2 * .pi
                let d = Vec3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
                let w = cos(lat)
                total += w
                if Terrain.height(body: .terra, direction: d) < 0 { ocean += w }
                biomes.insert(Terrain.biome(body: .terra, direction: d))
                biomes.insert(Terrain.biome(body: .luna, direction: d))
            }
        }
        let frac = ocean / total
        #expect(frac > 0.15 && frac < 0.75, "доля океана \(frac)")
        for b in [Biome.ocean, .lowlands, .highlands, .polarIce, .lunarPlains, .lunarCraters, .lunarPoles] {
            #expect(biomes.contains(b), "нет биома \(b)")
        }
        // Детерминизм.
        let d = Vec3(0.3, -0.5, 0.2)
        #expect(Terrain.height(body: .luna, direction: d) == Terrain.height(body: .luna, direction: d))
        #expect(Terrain.surfaceHeight(body: .terra, direction: d) >= 0)
    }

    @Test func soiConversionRoundTrip() {
        let s = StateVector(position: Vec3(11_000_000, 3_000_000, 5_000), velocity: Vec3(-300, 2_000, 1))
        let l = World.convert(s, from: .terra, to: .luna, time: 5_000)
        let back = World.convert(l, from: .luna, to: .terra, time: 5_000)
        #expect((back.position - s.position).length < 1e-6)
        #expect((back.velocity - s.velocity).length < 1e-9)
    }
}
