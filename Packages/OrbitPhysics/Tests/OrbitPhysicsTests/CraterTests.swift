import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Малые кратеры Луны")
struct CraterTests {
    private static func randomDir(_ seed: inout UInt64) -> Vec3 {
        func rnd() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let z = 2 * rnd() - 1, lon = 2 * Double.pi * rnd(), rxy = (1 - z * z).squareRoot()
        return Vec3(rxy * cos(lon), rxy * sin(lon), z)
    }

    @Test func deterministic() {
        var s: UInt64 = 7
        for _ in 0..<200 {
            let d = Self.randomDir(&s)
            #expect(Terrain.height(body: .luna, direction: d) == Terrain.height(body: .luna, direction: d))
            #expect(Terrain.craterShade(body: .luna, direction: d) == Terrain.craterShade(body: .luna, direction: d))
        }
        #expect(Terrain.craterShade(body: .terra, direction: Vec3(1, 0, 0)) == 0)
    }

    @Test func coverageAndRange() {
        var s: UInt64 = 99
        var inside = 0, rim = 0, minShade = 0.0, maxShade = 0.0
        let n = 20_000
        for _ in 0..<n {
            let sh = Terrain.craterShade(body: .luna, direction: Self.randomDir(&s))
            if sh < -0.05 { inside += 1 }
            if sh > 0.05 { rim += 1 }
            minShade = min(minShade, sh); maxShade = max(maxShade, sh)
        }
        let frac = Double(inside + rim) / Double(n)
        print("CRATER-COVERAGE: дно \(Double(inside) / Double(n)), вал \(Double(rim) / Double(n)), всего \(frac)")
        #expect(frac >= 0.2, "доля точек в малых кратерах \(frac)")
        #expect(minShade >= -1 && maxShade <= 1)
        #expect(minShade < -0.9 && maxShade > 0.5, "дно \(minShade), вал \(maxShade)")
    }

    @Test func continuity() {
        // Соседние точки на 1 м отличаются мало (включая кромки кратеров).
        var s: UInt64 = 5
        let R = Bodies.luna.radius
        var maxDiff = 0.0
        for _ in 0..<20_000 {
            let d = Self.randomDir(&s)
            let t = d.cross(Vec3(0.3, 0.5, 0.8)).normalized
            let d2 = (d + t * (1 / R)).normalized
            let dh = abs(Terrain.height(body: .luna, direction: d) - Terrain.height(body: .luna, direction: d2))
            maxDiff = max(maxDiff, dh)
        }
        print("CRATER-CONT: макс. перепад на 1 м \(maxDiff)")
        #expect(maxDiff < 1.5, "макс. перепад на 1 м \(maxDiff)")
    }

    @Test func depthAndRimBounds() {
        var s: UInt64 = 321
        var lo = Double.infinity, hi = -Double.infinity
        for _ in 0..<20_000 {
            let h = Terrain.height(body: .luna, direction: Self.randomDir(&s))
            lo = min(lo, h); hi = max(hi, h)
        }
        print("CRATER-RANGE: высоты \(lo)…\(hi)")
        #expect(lo > -2_500 && hi < 5_500, "высоты \(lo)…\(hi)")
    }

    @Test func heightCallTime() {
        var s: UInt64 = 1
        let dirs = (0..<1_000).map { _ in Self.randomDir(&s) }
        var acc = 0.0
        let t0 = Date()
        for i in 0..<200_000 { acc += Terrain.height(body: .luna, direction: dirs[i % 1_000]) }
        let dt = Date().timeIntervalSince(t0)
        print("CRATER-TIMING: 200000 вызовов height(.luna) за \(dt) с (\(dt / 200_000 * 1e6) мкс/вызов), acc=\(acc)")
        #expect(dt < 20)
    }
}
