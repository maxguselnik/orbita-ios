import Foundation
import Testing
@testable import OrbitPhysics

@Suite("Vec3 и Quat")
struct VectorTests {
    @Test func algebra() {
        let a = Vec3(1, 2, 3)
        let b = Vec3(-4, 5, 0.5)
        #expect(a + b == Vec3(-3, 7, 3.5))
        #expect(a.dot(b) == 7.5)
        #expect(Vec3.unitX.cross(.unitY) == .unitZ)
        #expect(abs(Vec3(3, 4, 0).length - 5) < 1e-12)
        #expect(Vec3.zero.normalized == .zero)
    }

    @Test func rotation() {
        let q = Quat(axis: .unitZ, angle: .pi / 2)
        let r = q.rotate(.unitX)
        #expect((r - .unitY).length < 1e-12)
        let back = q.conjugate.rotate(r)
        #expect((back - .unitX).length < 1e-12)
    }
}

@Suite("Тела")
struct BodyTests {
    @Test func terraDensity() {
        let t = Bodies.terra
        #expect(t.density(altitude: 0) == 1.225)
        #expect(abs(t.density(altitude: 5_600) - 1.225 / M_E) < 1e-12)
        #expect(t.density(altitude: 70_000) == 0)
        #expect(abs(t.surfaceGravity - 9.81) < 0.01)
    }

    @Test func lunaSOIMatchesLaplace() {
        let l = Bodies.luna
        let laplace = l.orbitRadius * pow(l.mu / Bodies.terra.mu, 0.4)
        #expect(abs(laplace - l.soiRadius) / l.soiRadius < 0.01)
        #expect(Bodies.body(.luna) == l)
    }
}
